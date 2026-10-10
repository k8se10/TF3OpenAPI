#include "profiler.h"

#include "config.h"
#include "log.h"

#include <windows.h>

#include <intrin.h>
#include <psapi.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace tf3opt::profiler {
namespace {

constexpr int kMaxFrames = 48;
constexpr int kMaxModules = 384;
constexpr int kTopFunctions = 30;
constexpr int kTopThreads = 12;

struct Module {
    uintptr_t base;
    uintptr_t end;
    const RUNTIME_FUNCTION* funcs;
    DWORD funcCount;
    char name[64];
    bool isSystem;  // lives under the Windows directory
};

struct RawFrame {
    uint32_t module;
    uint32_t rva;  // of the instruction (return addresses are taken minus one so they stay inside the caller)
};

using Counts = std::unordered_map<uint64_t, uint64_t>;

struct ThreadRec {
    DWORD tid = 0;
    HANDLE handle = nullptr;
    uint64_t samples = 0;
    uint64_t waitSamples = 0;  // sampled inside a system call having used (almost) no CPU since the last sample
    uint64_t cycles = 0;       // CPU cycles the thread used during the capture
    ULONG64 lastCycles = 0;    // thread cycle counter at the previous sample
    uint64_t lastTsc = 0;      // wall-clock TSC at the previous sample
    // Every sample is weighted by the CPU cycles the thread used since its previous sample, so time spent
    // in the kernel on a function's behalf counts as work, and a blocked thread counts as nothing.
    Counts self;       // cycles by the first non-system frame
    Counts inclusive;  // cycles by every distinct function on the stack
    Counts waitingIn;  // idle in-kernel samples by the first non-system frame
};

struct Settings {
    int key = VK_F8;
    int seconds = 10;
    int rateHz = 250;
    int autoCaptureAfter = 0;  // seconds after startup; 0 = hotkey only
};

Settings g_settings;
Module g_modules[kMaxModules];
int g_moduleCount = 0;
HANDLE g_hotkeyThread = nullptr;
DWORD g_hotkeyThreadId = 0;

// ---- Module / function tables (read once, before anything is suspended) ------------------------------

void LoadModules() {
    g_moduleCount = 0;
    static HMODULE handles[kMaxModules];
    DWORD needed = 0;
    if (!EnumProcessModules(GetCurrentProcess(), handles, sizeof(handles), &needed)) return;
    const int count = static_cast<int>(std::min<size_t>(needed / sizeof(HMODULE), kMaxModules));

    char windowsDir[MAX_PATH] = {};
    const UINT windowsLen = GetWindowsDirectoryA(windowsDir, MAX_PATH);

    for (int i = 0; i < count; ++i) {
        MODULEINFO info = {};
        if (!GetModuleInformation(GetCurrentProcess(), handles[i], &info, sizeof(info))) continue;
        Module m = {};
        m.base = reinterpret_cast<uintptr_t>(info.lpBaseOfDll);
        m.end = m.base + info.SizeOfImage;

        const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(m.base);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE) continue;
        const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(m.base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) continue;
        const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
        if (dir.VirtualAddress != 0 && dir.Size >= sizeof(RUNTIME_FUNCTION)) {
            m.funcs = reinterpret_cast<const RUNTIME_FUNCTION*>(m.base + dir.VirtualAddress);
            m.funcCount = dir.Size / sizeof(RUNTIME_FUNCTION);
        }

        char path[MAX_PATH] = {};
        GetModuleFileNameA(handles[i], path, MAX_PATH);
        const char* file = std::strrchr(path, '\\');
        strncpy_s(m.name, file ? file + 1 : path, _TRUNCATE);
        m.isSystem = windowsLen > 0 && _strnicmp(path, windowsDir, windowsLen) == 0;
        g_modules[g_moduleCount++] = m;
    }
    std::sort(g_modules, g_modules + g_moduleCount, [](const Module& a, const Module& b) { return a.base < b.base; });
}

int FindModule(uintptr_t address) {
    int lo = 0, hi = g_moduleCount - 1;
    while (lo <= hi) {
        const int mid = (lo + hi) / 2;
        if (address < g_modules[mid].base) {
            hi = mid - 1;
        } else if (address >= g_modules[mid].end) {
            lo = mid + 1;
        } else {
            return mid;
        }
    }
    return -1;
}

const RUNTIME_FUNCTION* LookupFunction(const Module& m, uint32_t rva) {
    if (m.funcs == nullptr) return nullptr;
    DWORD lo = 0, hi = m.funcCount;
    while (lo < hi) {
        const DWORD mid = lo + (hi - lo) / 2;
        const RUNTIME_FUNCTION& f = m.funcs[mid];
        if (rva < f.BeginAddress) {
            hi = mid;
        } else if (rva >= f.EndAddress) {
            lo = mid + 1;
        } else {
            return &f;
        }
    }
    return nullptr;
}

// A function split into several unwind chunks has chained entries; follow them to the primary chunk so
// all of its samples are reported under one address.
uint32_t PrimaryBegin(const Module& m, const RUNTIME_FUNCTION* fn) {
    struct UnwindInfoHeader {
        uint8_t versionAndFlags;
        uint8_t prologSize;
        uint8_t codeCount;
        uint8_t frameRegister;
    };
    for (int depth = 0; depth < 8 && fn != nullptr; ++depth) {
        const auto* info = reinterpret_cast<const UnwindInfoHeader*>(m.base + fn->UnwindData);
        if (((info->versionAndFlags >> 3) & UNW_FLAG_CHAININFO) == 0) break;
        const size_t codes = (static_cast<size_t>(info->codeCount) + 1) & ~static_cast<size_t>(1);
        fn = reinterpret_cast<const RUNTIME_FUNCTION*>(reinterpret_cast<const uint8_t*>(info) + 4 + codes * 2);
    }
    return fn ? fn->BeginAddress : 0;
}

uint64_t KeyFor(const RawFrame& frame) {
    const Module& m = g_modules[frame.module];
    const RUNTIME_FUNCTION* fn = LookupFunction(m, frame.rva);
    const uint32_t rva = fn ? PrimaryBegin(m, fn) : frame.rva;
    return (static_cast<uint64_t>(frame.module) << 32) | rva;
}

// ---- Sampling ----------------------------------------------------------------------------------------

// Walks the stack of a SUSPENDED thread. Must not allocate or call anything that takes a lock.
int WalkStack(CONTEXT* ctx, RawFrame* out, bool* inKernel) {
    int n = 0;
    *inKernel = false;
    __try {
        while (n < kMaxFrames) {
            const uintptr_t ip = static_cast<uintptr_t>(ctx->Rip);
            if (ip < 0x10000) break;
            const uintptr_t lookup = (n == 0) ? ip : ip - 1;
            const int moduleIndex = FindModule(lookup);
            if (moduleIndex < 0) break;
            const Module& m = g_modules[moduleIndex];
            if (n == 0) {
                // A thread blocked in (or returning from) a system call sits right after a SYSCALL instruction.
                const auto* code = reinterpret_cast<const uint8_t*>(ip);
                *inKernel = (ip - 2 >= m.base) && code[-2] == 0x0F && code[-1] == 0x05;
            }
            const uint32_t rva = static_cast<uint32_t>(lookup - m.base);
            out[n].module = static_cast<uint32_t>(moduleIndex);
            out[n].rva = rva;
            ++n;

            const RUNTIME_FUNCTION* fn = LookupFunction(m, rva);
            if (fn != nullptr) {
                PVOID handlerData = nullptr;
                DWORD64 establisher = 0;
                RtlVirtualUnwind(UNW_FLAG_NHANDLER, m.base, ctx->Rip, const_cast<PRUNTIME_FUNCTION>(fn), ctx, &handlerData,
                                 &establisher, nullptr);
            } else {
                // Leaf function: the return address is at the top of the stack.
                ctx->Rip = *reinterpret_cast<const DWORD64*>(ctx->Rsp);
                ctx->Rsp += 8;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    return n;
}

// Runs after the thread has been resumed (allocates).
void Tally(ThreadRec& rec, const RawFrame* frames, int n, bool inKernel, uint64_t usedCycles, uint64_t wallCycles) {
    ++rec.samples;
    rec.cycles += usedCycles;
    uint64_t keys[kMaxFrames];
    int firstEngine = -1;
    for (int i = 0; i < n; ++i) {
        keys[i] = KeyFor(frames[i]);
        if (firstEngine < 0 && !g_modules[frames[i].module].isSystem) firstEngine = i;
    }
    const uint64_t attributed = keys[firstEngine >= 0 ? firstEngine : 0];
    if (inKernel && usedCycles * 10 < wallCycles) {
        ++rec.waitSamples;
        ++rec.waitingIn[attributed];
    }
    if (usedCycles == 0) return;
    rec.self[attributed] += usedCycles;
    for (int i = 0; i < n; ++i) {
        bool seen = false;
        for (int j = 0; j < i; ++j) {
            if (keys[j] == keys[i]) {
                seen = true;
                break;
            }
        }
        if (!seen) rec.inclusive[keys[i]] += usedCycles;
    }
}

void RefreshThreads(std::vector<ThreadRec>& threads) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return;
    THREADENTRY32 entry = {};
    entry.dwSize = sizeof(entry);
    const DWORD pid = GetCurrentProcessId(), self = GetCurrentThreadId();
    if (Thread32First(snapshot, &entry)) {
        do {
            if (entry.th32OwnerProcessID != pid || entry.th32ThreadID == self) continue;
            bool known = false;
            for (const ThreadRec& t : threads) {
                if (t.tid == entry.th32ThreadID) {
                    known = true;
                    break;
                }
            }
            if (known) continue;
            HANDLE handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE,
                                       entry.th32ThreadID);
            if (handle == nullptr) continue;
            ThreadRec rec;
            rec.tid = entry.th32ThreadID;
            rec.handle = handle;
            QueryThreadCycleTime(handle, &rec.lastCycles);
            rec.lastTsc = __rdtsc();
            threads.push_back(std::move(rec));
        } while (Thread32Next(snapshot, &entry));
    }
    CloseHandle(snapshot);
}

// ---- Report ------------------------------------------------------------------------------------------

std::string ThreadName(HANDLE thread) {
    PWSTR wide = nullptr;
    std::string name;
    if (SUCCEEDED(GetThreadDescription(thread, &wide)) && wide != nullptr) {
        char narrow[128] = {};
        WideCharToMultiByte(CP_UTF8, 0, wide, -1, narrow, sizeof(narrow) - 1, nullptr, nullptr);
        name = narrow;
        LocalFree(wide);
    }
    return name.empty() ? "(unnamed)" : name;
}

// Nearest exported name at or below rva (report time only). The game exe exports nothing; this names
// functions in system and third-party DLLs. Offsets of more than 64 KB are treated as "no name".
bool NearestExport(const Module& m, uint32_t rva, const char** name, uint32_t* offset) {
    bool found = false;
    __try {
        const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(m.base);
        const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(m.base + dos->e_lfanew);
        const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
        if (dir.VirtualAddress == 0 || dir.Size < sizeof(IMAGE_EXPORT_DIRECTORY)) return false;
        const auto* exports = reinterpret_cast<const IMAGE_EXPORT_DIRECTORY*>(m.base + dir.VirtualAddress);
        const auto* names = reinterpret_cast<const DWORD*>(m.base + exports->AddressOfNames);
        const auto* ordinals = reinterpret_cast<const WORD*>(m.base + exports->AddressOfNameOrdinals);
        const auto* functions = reinterpret_cast<const DWORD*>(m.base + exports->AddressOfFunctions);
        uint32_t best = 0;
        for (DWORD i = 0; i < exports->NumberOfNames; ++i) {
            if (ordinals[i] >= exports->NumberOfFunctions) continue;
            const uint32_t target = functions[ordinals[i]];
            // Forwarders point back into the export directory, not at code.
            if (target >= dir.VirtualAddress && target < dir.VirtualAddress + dir.Size) continue;
            if (target <= rva && (!found || target > best)) {
                best = target;
                *name = reinterpret_cast<const char*>(m.base + names[i]);
                found = true;
            }
        }
        if (found && rva - best > 0x10000) found = false;
        if (found) *offset = rva - best;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        found = false;
    }
    return found;
}

void FormatKey(uint64_t key, char* out, size_t size) {
    const Module& m = g_modules[key >> 32];
    const uint32_t rva = static_cast<uint32_t>(key);
    const char* name = nullptr;
    uint32_t offset = 0;
    if (NearestExport(m, rva, &name, &offset)) {
        snprintf(out, size, "%s+0x%x  %.60s+0x%x", m.name, rva, name, offset);
    } else {
        snprintf(out, size, "%s+0x%x", m.name, rva);
    }
}

void WriteTop(FILE* f, const char* title, const Counts& counts, uint64_t total, double msPerUnit) {
    fprintf(f, "  %s\n", title);
    if (total == 0 || counts.empty()) {
        fprintf(f, "      (none)\n");
        return;
    }
    std::vector<std::pair<uint64_t, uint64_t>> sorted(counts.begin(), counts.end());
    std::sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
    char where[128];
    for (size_t i = 0; i < sorted.size() && i < kTopFunctions; ++i) {
        FormatKey(sorted[i].first, where, sizeof(where));
        const double share = 100.0 * static_cast<double>(sorted[i].second) / static_cast<double>(total);
        if (msPerUnit > 0.0) {
            fprintf(f, "    %6.2f%%  %8.1f ms  %s\n", share, static_cast<double>(sorted[i].second) * msPerUnit, where);
        } else {
            fprintf(f, "    %6.2f%%  %8llu     %s\n", share, static_cast<unsigned long long>(sorted[i].second), where);
        }
    }
}

std::wstring ReportPath() {
    wchar_t exePath[MAX_PATH] = {};
    const DWORD len = GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring path(exePath, len);
    const size_t slash = path.find_last_of(L"\\/");
    if (slash != std::wstring::npos) path.resize(slash + 1);
    return path + L"tf3opt_profile.txt";
}

void WriteReport(std::vector<ThreadRec>& threads, double seconds, uint64_t sweeps, double cyclesPerMs) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, ReportPath().c_str(), L"w") != 0 || f == nullptr) {
        TF3_LOG("profiler: could not write tf3opt_profile.txt");
        return;
    }
    std::sort(threads.begin(), threads.end(), [](const ThreadRec& a, const ThreadRec& b) { return a.cycles > b.cycles; });

    const double msPerCycle = 1.0 / cyclesPerMs;
    const double captureMs = seconds * 1000.0;
    uint64_t processCycles = 0;
    for (const ThreadRec& t : threads) processCycles += t.cycles;
    const double processMs = static_cast<double>(processCycles) * msPerCycle;

    SYSTEM_INFO sys = {};
    GetSystemInfo(&sys);
    SYSTEMTIME now;
    GetLocalTime(&now);
    fprintf(f, "TF3 Optimizations - sampling profile  %04u-%02u-%02u %02u:%02u:%02u\n", now.wYear, now.wMonth, now.wDay,
            now.wHour, now.wMinute, now.wSecond);
    fprintf(f, "capture: %.1f s, %llu sweeps (%.0f per second), %zu threads\n", seconds,
            static_cast<unsigned long long>(sweeps), static_cast<double>(sweeps) / seconds, threads.size());
    fprintf(f, "process CPU: %.0f ms = %.2f cores busy on average = %.1f%% of the machine's %lu logical cores\n", processMs,
            processMs / captureMs, 100.0 * processMs / (captureMs * sys.dwNumberOfProcessors), sys.dwNumberOfProcessors);
    fprintf(f, "CPU time is measured per thread in cycles (kernel time included) and split between functions by\n"
               "sample; a function is the engine/game code that was running or had called into the system.\n\n");

    fprintf(f, "THREADS by CPU time (%%core = share of one core; %%proc = share of the process's CPU time;\n"
               "                     waiting = samples blocked in a system call)\n");
    fprintf(f, "     tid   %%core   %%proc    cpu ms  waiting  name\n");
    for (const ThreadRec& t : threads) {
        const double cpuMs = static_cast<double>(t.cycles) * msPerCycle;
        if (cpuMs < 1.0) continue;
        fprintf(f, "  %6lu  %5.1f%%  %5.1f%%  %8.0f  %6.1f%%  %s\n", t.tid, 100.0 * cpuMs / captureMs,
                processMs > 0.0 ? 100.0 * cpuMs / processMs : 0.0, cpuMs,
                t.samples ? 100.0 * static_cast<double>(t.waitSamples) / static_cast<double>(t.samples) : 0.0,
                ThreadName(t.handle).c_str());
    }

    Counts all;
    for (const ThreadRec& t : threads) {
        for (const auto& kv : t.self) all[kv.first] += kv.second;
    }
    fprintf(f, "\nALL THREADS - where the process's CPU time goes\n");
    WriteTop(f, "SELF - % of process CPU time", all, processCycles, msPerCycle);

    int shown = 0;
    for (const ThreadRec& t : threads) {
        if (shown >= kTopThreads || t.cycles == 0) break;
        const double cpuMs = static_cast<double>(t.cycles) * msPerCycle;
        fprintf(f, "\n== thread %lu \"%s\"  %.0f ms CPU (%.1f%% of a core, %.1f%% of process), %llu samples, %llu waiting\n",
                t.tid, ThreadName(t.handle).c_str(), cpuMs, 100.0 * cpuMs / captureMs,
                processMs > 0.0 ? 100.0 * cpuMs / processMs : 0.0, static_cast<unsigned long long>(t.samples),
                static_cast<unsigned long long>(t.waitSamples));
        WriteTop(f, "SELF - % of this thread's CPU time", t.self, t.cycles, msPerCycle);
        WriteTop(f, "INCLUSIVE - % of this thread's CPU time with the function anywhere on the stack", t.inclusive, t.cycles,
                 msPerCycle);
        WriteTop(f, "WAITING IN - % of this thread's waiting samples, by the engine function that made the call",
                 t.waitingIn, t.waitSamples, 0.0);
        ++shown;
    }
    fclose(f);
}

// ---- Capture -----------------------------------------------------------------------------------------

void Capture() {
    LoadModules();
    if (g_moduleCount == 0) {
        TF3_LOG("profiler: could not read the module list");
        return;
    }
    std::vector<ThreadRec> threads;
    threads.reserve(256);
    RefreshThreads(threads);

    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    const LONGLONG intervalHns = 10000000ll / g_settings.rateHz;  // 100 ns units

    LARGE_INTEGER freq, start, now;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    const uint64_t tscStart = __rdtsc();
    const double duration = static_cast<double>(g_settings.seconds);
    TF3_LOG("profiler: capturing %d s at %d Hz (%zu threads)...", g_settings.seconds, g_settings.rateHz, threads.size());

    uint64_t sweeps = 0;
    RawFrame frames[kMaxFrames];
    for (;;) {
        QueryPerformanceCounter(&now);
        if (static_cast<double>(now.QuadPart - start.QuadPart) / static_cast<double>(freq.QuadPart) >= duration) break;

        for (ThreadRec& t : threads) {
            if (SuspendThread(t.handle) == static_cast<DWORD>(-1)) continue;
            // ---- thread suspended: no allocation, no locks ----
            CONTEXT ctx;
            ctx.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
            bool inKernel = false;
            int n = 0;
            if (GetThreadContext(t.handle, &ctx)) n = WalkStack(&ctx, frames, &inKernel);
            ULONG64 cycles = t.lastCycles;
            QueryThreadCycleTime(t.handle, &cycles);
            const uint64_t tsc = __rdtsc();
            ResumeThread(t.handle);
            // ---- resumed ----
            const uint64_t used = cycles > t.lastCycles ? cycles - t.lastCycles : 0;
            const uint64_t wall = tsc - t.lastTsc;
            t.lastCycles = cycles;
            t.lastTsc = tsc;
            if (n > 0) Tally(t, frames, n, inKernel, used, wall);
        }
        ++sweeps;
        if (sweeps % 256 == 0) RefreshThreads(threads);

        if (timer != nullptr) {
            LARGE_INTEGER due;
            due.QuadPart = -intervalHns;
            SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
            WaitForSingleObject(timer, 100);
        } else {
            Sleep(1);
        }
    }
    QueryPerformanceCounter(&now);
    const double seconds = static_cast<double>(now.QuadPart - start.QuadPart) / static_cast<double>(freq.QuadPart);
    const double cyclesPerMs = static_cast<double>(__rdtsc() - tscStart) / (seconds * 1000.0);
    if (timer != nullptr) CloseHandle(timer);

    WriteReport(threads, seconds, sweeps, cyclesPerMs);
    for (ThreadRec& t : threads) CloseHandle(t.handle);
    TF3_LOG("profiler: done - %llu sweeps in %.1f s, report written to tf3opt_profile.txt",
            static_cast<unsigned long long>(sweeps), seconds);
}

bool GameWindowFocused() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

DWORD WINAPI HotkeyThread(LPVOID) {
    SetThreadDescription(GetCurrentThread(), L"tf3opt profiler");
    if (!RegisterHotKey(nullptr, 1, MOD_NOREPEAT, static_cast<UINT>(g_settings.key))) {
        TF3_LOG("profiler: could not register hotkey %d (error %lu) - profiler unavailable", g_settings.key, GetLastError());
        return 0;
    }
    TF3_LOG("profiler: ready - press key %d in-game to capture %d s", g_settings.key, g_settings.seconds);
    UINT_PTR autoTimer = 0;
    if (g_settings.autoCaptureAfter > 0) {
        autoTimer = SetTimer(nullptr, 0, static_cast<UINT>(g_settings.autoCaptureAfter) * 1000u, nullptr);
    }
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (msg.message == WM_HOTKEY && GameWindowFocused()) {
            Capture();
        } else if (msg.message == WM_TIMER && autoTimer != 0 && msg.wParam == autoTimer) {
            KillTimer(nullptr, autoTimer);
            autoTimer = 0;
            Capture();
        }
    }
    UnregisterHotKey(nullptr, 1);
    return 0;
}

} // namespace

void Install() {
    if (!config::GetBool("Profiler", "Enabled", true)) return;
    g_settings.key = config::GetInt("Profiler", "Key", VK_F8);
    g_settings.seconds = config::GetInt("Profiler", "Seconds", 10);
    g_settings.rateHz = config::GetInt("Profiler", "RateHz", 250);
    g_settings.autoCaptureAfter = config::GetInt("Profiler", "AutoCaptureAfter", 0);
    if (g_settings.key <= 0) return;
    if (g_settings.autoCaptureAfter < 0 || g_settings.autoCaptureAfter > 3600) g_settings.autoCaptureAfter = 0;
    if (g_settings.seconds < 1 || g_settings.seconds > 120) g_settings.seconds = 10;
    if (g_settings.rateHz < 10 || g_settings.rateHz > 2000) g_settings.rateHz = 250;
    g_hotkeyThread = CreateThread(nullptr, 0, HotkeyThread, nullptr, 0, &g_hotkeyThreadId);
}

void Uninstall() {
    if (g_hotkeyThread == nullptr) return;
    PostThreadMessageW(g_hotkeyThreadId, WM_QUIT, 0, 0);
    WaitForSingleObject(g_hotkeyThread, 500);
    CloseHandle(g_hotkeyThread);
    g_hotkeyThread = nullptr;
}

} // namespace tf3opt::profiler
