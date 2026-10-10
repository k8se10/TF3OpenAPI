#include "profiler.h"

#include "config.h"
#include "log.h"
#include "occlusion.h"
#include "sigscan.h"
#include "vkstats.h"

#include <windows.h>

#include <intrin.h>
#include <psapi.h>
#include <tlhelp32.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace tf3api::profiler {
namespace {

constexpr int kMaxFrames = 48;
constexpr int kMaxModules = 384;
constexpr int kTopFunctions = 30;
constexpr int kTopThreads = 12;
constexpr int kMaxLuaFrames = 16;
constexpr int kLuaFuncSlots = 4096;  // power of two
constexpr int kLuaSourceChars = 112;
constexpr int kMaxWaitStubs = 16;

struct Module {
    uintptr_t base;
    uintptr_t end;
    const RUNTIME_FUNCTION* funcs;
    DWORD funcCount;
    char name[64];
    bool isSystem;  // Windows or the C/C++ runtime: time in it is charged to the engine code that called it
};

struct RawFrame {
    uint32_t module;
    uint32_t rva;  // of the instruction (return addresses are taken minus one so they stay inside the caller)
};

// The Lua functions active on a sampled thread, innermost first (indices into g_luaFuncs).
struct LuaSample {
    int count = 0;
    uint32_t fn[kMaxLuaFrames];
    int line = 0;  // line being executed in fn[0]
};

struct LuaFunc {
    uint64_t hash;  // 0 = empty slot
    int lineDefined;
    char source[kLuaSourceChars];
};

using Counts = std::unordered_map<uint64_t, uint64_t>;

struct ThreadRec {
    DWORD tid = 0;
    HANDLE handle = nullptr;
    uint64_t samples = 0;
    uint64_t waitSamples = 0;    // samples that found the thread blocked
    uint64_t cycles = 0;         // CPU cycles the thread used during the capture
    uint64_t betweenCycles = 0;  // cycles used between two samples by a thread found blocked: not attributable
    ULONG64 lastCycles = 0;      // thread cycle counter at the previous sample
    uint64_t lastTsc = 0;        // wall-clock TSC at the previous sample
    bool lastBlocked = false;    // previous sample found the thread blocked...
    uint64_t lastWaitKey = 0;    // ...in a wait made by this function
    // Every sample of a running thread is weighted by the CPU cycles the thread used since its previous
    // sample, so time spent in the kernel on a function's behalf counts as work.
    Counts self;       // cycles by the first non-system frame
    Counts inclusive;  // cycles by every distinct function on the stack
    Counts waitingIn;  // blocked samples by the first non-system frame
    Counts luaSelf;    // cycles by innermost Lua function (includes the engine API calls it makes)
    Counts luaIncl;    // cycles by every distinct Lua function on the Lua call stack
    Counts luaLines;   // cycles by (innermost Lua function, line)
};

struct Settings {
    int key = VK_F8;
    int seconds = 10;
    int rateHz = 500;
    int autoCaptureAfter = 0;  // seconds after startup; 0 = hotkey only
    bool continuous = false;   // capture back to back for the whole session
    int keep = 30;             // continuous mode: number of reports kept in the tf3api_profiles folder
};

Settings g_settings;
Module g_modules[kMaxModules];
int g_moduleCount = 0;
HANDLE g_hotkeyThread = nullptr;
DWORD g_hotkeyThreadId = 0;
std::atomic<bool> g_stop{false};
std::vector<std::wstring> g_history;  // continuous mode: report files written this session, oldest first

uintptr_t g_waitStubs[kMaxWaitStubs];
int g_waitStubCount = 0;

// Lua 5.2.2 is linked into the game exe. luaV_execute (the interpreter loop) keeps its lua_State in rbp
// for its whole body; from there the Lua call stack is plain memory. Offsets confirmed against the exe's
// own lua_getinfo (build 40408) - see re_notes/scripting/lua_vm.md.
// Signature: luaV_execute prologue up to the first spills.
constexpr const char* kSigLuaExecute =
    "40 53 55 56 57 41 54 41 55 41 56 41 57 48 83 EC 78 4C 8B 69 20 48 8B E9 C5 F8 29 74 24 60 C5 FB 10 35 ?? ?? ?? ?? C5 "
    "F8 29 7C 24 50";
uintptr_t g_luaExecute = 0;  // address, 0 = not found (Lua attribution off)
int g_luaModule = -1;        // per capture
uint32_t g_luaExecuteRva = 0;
LuaFunc g_luaFuncs[kLuaFuncSlots];

namespace lua {
constexpr size_t kStateType = 0x08;      // lua_State.tt (LUA_TTHREAD = 8)
constexpr size_t kStateCi = 0x20;        // lua_State.ci
constexpr size_t kCiFunc = 0x00;         // CallInfo.func (StkId -> TValue holding the closure)
constexpr size_t kCiPrevious = 0x10;     // CallInfo.previous
constexpr size_t kCiCallStatus = 0x22;   // CallInfo.callstatus, bit 0 = CIST_LUA
constexpr size_t kCiSavedPc = 0x38;      // CallInfo.u.l.savedpc
constexpr size_t kClosureType = 0x08;    // 6 = Lua closure, 0x26 = C closure
constexpr size_t kClosureProto = 0x18;   // LClosure.p
constexpr size_t kProtoCode = 0x18;      // Proto.code
constexpr size_t kProtoLineInfo = 0x28;  // Proto.lineinfo
constexpr size_t kProtoSource = 0x48;    // Proto.source (TString*)
constexpr size_t kProtoSizeLineInfo = 0x5C;
constexpr size_t kProtoLineDefined = 0x68;
constexpr size_t kStringLen = 0x10;   // TString.len
constexpr size_t kStringData = 0x18;  // characters follow the header
} // namespace lua

template <typename T>
T Peek(uintptr_t address) {
    return *reinterpret_cast<const T*>(address);
}

// ---- Module / function tables (read once, before anything is suspended) ------------------------------

bool IsRuntimeLibrary(const char* name) {
    static const char* const kPrefixes[] = {"msvcp", "vcruntime", "ucrtbase", "concrt", "api-ms-", "vcomp"};
    for (const char* prefix : kPrefixes) {
        if (_strnicmp(name, prefix, std::strlen(prefix)) == 0) return true;
    }
    return false;
}

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
        m.isSystem = (windowsLen > 0 && _strnicmp(path, windowsDir, windowsLen) == 0) || IsRuntimeLibrary(m.name);
        // This DLL's own Vulkan wrappers sit between the game and the driver: charge them to the game code.
        const uintptr_t self = reinterpret_cast<uintptr_t>(&IsRuntimeLibrary);
        if (self >= m.base && self < m.end) m.isSystem = true;
        g_modules[g_moduleCount++] = m;
    }
    std::sort(g_modules, g_modules + g_moduleCount, [](const Module& a, const Module& b) { return a.base < b.base; });
}

// System-call stubs that only ever block. A thread sampled inside one is waiting, whatever CPU it used
// since the previous sample.
void LoadWaitStubs() {
    g_waitStubCount = 0;
    static const struct {
        const char* module;
        const char* name;
    } kStubs[] = {
        {"ntdll.dll", "NtWaitForAlertByThreadId"},      {"ntdll.dll", "NtWaitForSingleObject"},
        {"ntdll.dll", "NtWaitForMultipleObjects"},      {"ntdll.dll", "NtDelayExecution"},
        {"ntdll.dll", "NtRemoveIoCompletion"},          {"ntdll.dll", "NtRemoveIoCompletionEx"},
        {"ntdll.dll", "NtWaitForWorkViaWorkerFactory"}, {"ntdll.dll", "NtWaitForKeyedEvent"},
        {"ntdll.dll", "NtSignalAndWaitForSingleObject"}, {"win32u.dll", "NtUserMsgWaitForMultipleObjectsEx"},
        {"win32u.dll", "NtUserGetMessage"},             {"win32u.dll", "NtUserWaitMessage"},
    };
    for (const auto& stub : kStubs) {
        const HMODULE module = GetModuleHandleA(stub.module);
        if (module == nullptr) continue;
        const FARPROC address = GetProcAddress(module, stub.name);
        if (address != nullptr && g_waitStubCount < kMaxWaitStubs) {
            g_waitStubs[g_waitStubCount++] = reinterpret_cast<uintptr_t>(address);
        }
    }
}

bool InWaitStub(uintptr_t ip) {
    for (int i = 0; i < g_waitStubCount; ++i) {
        if (ip >= g_waitStubs[i] && ip < g_waitStubs[i] + 0x20) return true;
    }
    return false;
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

// ---- Lua call stack (read from a suspended thread: fixed tables only, no allocation) -----------------

// Finds or adds (source, lineDefined) in the fixed table. Caller guards against bad pointers.
uint32_t InternLuaFunc(uintptr_t sourceString, int lineDefined) {
    char text[kLuaSourceChars];
    size_t len = 0;
    if (sourceString != 0) {
        const size_t fullLen = Peek<size_t>(sourceString + lua::kStringLen);
        const char* chars = reinterpret_cast<const char*>(sourceString + lua::kStringData);
        if (fullLen < 0x10000) {
            // Keep the tail: paths are long and the file name is at the end.
            const size_t skip = fullLen > kLuaSourceChars - 1 ? fullLen - (kLuaSourceChars - 1) : 0;
            len = fullLen - skip;
            for (size_t i = 0; i < len; ++i) {
                const char c = chars[skip + i];
                text[i] = (c >= 32 && c < 127) ? c : '?';
            }
        }
    }
    if (len == 0) {
        text[0] = '?';
        len = 1;
    }
    text[len] = '\0';

    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < len; ++i) hash = (hash ^ static_cast<uint8_t>(text[i])) * 1099511628211ull;
    hash = (hash ^ static_cast<uint32_t>(lineDefined)) * 1099511628211ull;
    if (hash == 0) hash = 1;

    uint32_t slot = static_cast<uint32_t>(hash) & (kLuaFuncSlots - 1);
    for (int probe = 0; probe < kLuaFuncSlots; ++probe) {
        LuaFunc& f = g_luaFuncs[slot];
        if (f.hash == hash) return slot;
        if (f.hash == 0) {
            f.hash = hash;
            f.lineDefined = lineDefined;
            std::memcpy(f.source, text, len + 1);
            return slot;
        }
        slot = (slot + 1) & (kLuaFuncSlots - 1);
    }
    return 0;  // table full: misattributed to whatever lives in slot 0 (4096 distinct functions is far off)
}

// luaState is whatever rbp held in the luaV_execute frame; everything is validated or faults into the handler.
void ReadLuaStack(uintptr_t luaState, LuaSample* out) {
    out->count = 0;
    out->line = 0;
    __try {
        if (luaState < 0x10000 || (luaState & 7) != 0) return;
        if (Peek<uint8_t>(luaState + lua::kStateType) != 8) return;
        uintptr_t ci = Peek<uintptr_t>(luaState + lua::kStateCi);
        for (int depth = 0; depth < 96 && ci != 0 && out->count < kMaxLuaFrames; ++depth) {
            if ((Peek<uint8_t>(ci + lua::kCiCallStatus) & 1) != 0) {
                const uintptr_t func = Peek<uintptr_t>(ci + lua::kCiFunc);
                const uintptr_t closure = Peek<uintptr_t>(func);
                if (closure == 0 || Peek<uint8_t>(closure + lua::kClosureType) != 6) break;
                const uintptr_t proto = Peek<uintptr_t>(closure + lua::kClosureProto);
                if (out->count == 0) {
                    const uintptr_t lineInfo = Peek<uintptr_t>(proto + lua::kProtoLineInfo);
                    const uintptr_t code = Peek<uintptr_t>(proto + lua::kProtoCode);
                    const intptr_t pc =
                        (static_cast<intptr_t>(Peek<uintptr_t>(ci + lua::kCiSavedPc)) - static_cast<intptr_t>(code)) / 4 - 1;
                    if (lineInfo != 0 && pc >= 0 && pc < Peek<int>(proto + lua::kProtoSizeLineInfo)) {
                        out->line = Peek<int>(lineInfo + static_cast<uintptr_t>(pc) * 4);
                    }
                }
                out->fn[out->count++] =
                    InternLuaFunc(Peek<uintptr_t>(proto + lua::kProtoSource), Peek<int>(proto + lua::kProtoLineDefined));
            }
            ci = Peek<uintptr_t>(ci + lua::kCiPrevious);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        out->count = 0;
    }
}

// ---- Sampling ----------------------------------------------------------------------------------------

// Walks the stack of a SUSPENDED thread. Must not allocate or call anything that takes a lock.
// *luaState receives rbp of the innermost luaV_execute frame (0 if the thread is not running Lua).
int WalkStack(CONTEXT* ctx, RawFrame* out, bool* inKernel, bool* inWaitStub, uintptr_t* luaState) {
    int n = 0;
    *inKernel = false;
    *inWaitStub = false;
    *luaState = 0;
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
                *inWaitStub = *inKernel && InWaitStub(ip);
            }
            const uint32_t rva = static_cast<uint32_t>(lookup - m.base);
            out[n].module = static_cast<uint32_t>(moduleIndex);
            out[n].rva = rva;
            ++n;

            const RUNTIME_FUNCTION* fn = LookupFunction(m, rva);
            if (fn != nullptr) {
                if (*luaState == 0 && moduleIndex == g_luaModule && PrimaryBegin(m, fn) == g_luaExecuteRva) {
                    *luaState = static_cast<uintptr_t>(ctx->Rbp);
                }
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
void Tally(ThreadRec& rec, const RawFrame* frames, int n, bool blocked, uint64_t usedCycles, const LuaSample& luaSample) {
    ++rec.samples;
    rec.cycles += usedCycles;
    uint64_t keys[kMaxFrames];
    int firstEngine = -1;
    for (int i = 0; i < n; ++i) {
        keys[i] = KeyFor(frames[i]);
        if (firstEngine < 0 && !g_modules[frames[i].module].isSystem) firstEngine = i;
    }
    const uint64_t attributed = keys[firstEngine >= 0 ? firstEngine : 0];
    rec.lastBlocked = blocked;
    if (blocked) {
        // Whatever the thread ran since its previous sample is over; charging it to the wait would be wrong.
        ++rec.waitSamples;
        ++rec.waitingIn[attributed];
        rec.lastWaitKey = attributed;
        rec.betweenCycles += usedCycles;
        return;
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
    if (luaSample.count > 0) {
        rec.luaSelf[luaSample.fn[0]] += usedCycles;
        rec.luaLines[(static_cast<uint64_t>(luaSample.fn[0]) << 32) | static_cast<uint32_t>(luaSample.line)] += usedCycles;
        for (int i = 0; i < luaSample.count; ++i) {
            bool seen = false;
            for (int j = 0; j < i; ++j) {
                if (luaSample.fn[j] == luaSample.fn[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) rec.luaIncl[luaSample.fn[i]] += usedCycles;
        }
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

// ---- GPU load (NVIDIA only, optional) -----------------------------------------------------------------
// nvml.dll ships with the NVIDIA driver. Used read-only for the utilisation figure the driver itself
// reports; absent on other vendors, in which case the report says so.
struct GpuLoad {
    bool available = false;
    char name[96] = "";
    void* device = nullptr;
    int (*getUtilization)(void*, unsigned int*) = nullptr;  // fills {gpu %, memory-controller %}
    uint64_t samples = 0, sum = 0;
    unsigned int peak = 0, low = 100;
};
GpuLoad g_gpu;

void InitGpuLoad() {
    static bool tried = false;
    if (tried) return;
    tried = true;
    const HMODULE nvml = LoadLibraryExW(L"nvml.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (nvml == nullptr) return;
    const auto init = reinterpret_cast<int (*)()>(GetProcAddress(nvml, "nvmlInit_v2"));
    const auto byIndex = reinterpret_cast<int (*)(unsigned int, void**)>(GetProcAddress(nvml, "nvmlDeviceGetHandleByIndex_v2"));
    const auto getName = reinterpret_cast<int (*)(void*, char*, unsigned int)>(GetProcAddress(nvml, "nvmlDeviceGetName"));
    g_gpu.getUtilization =
        reinterpret_cast<int (*)(void*, unsigned int*)>(GetProcAddress(nvml, "nvmlDeviceGetUtilizationRates"));
    if (init == nullptr || byIndex == nullptr || g_gpu.getUtilization == nullptr) return;
    if (init() != 0 || byIndex(0, &g_gpu.device) != 0 || g_gpu.device == nullptr) return;
    if (getName != nullptr) getName(g_gpu.device, g_gpu.name, sizeof(g_gpu.name));
    g_gpu.available = true;
}

void SampleGpuLoad() {
    if (!g_gpu.available) return;
    unsigned int rates[2] = {0, 0};
    if (g_gpu.getUtilization(g_gpu.device, rates) != 0) return;
    ++g_gpu.samples;
    g_gpu.sum += rates[0];
    g_gpu.peak = std::max(g_gpu.peak, rates[0]);
    g_gpu.low = std::min(g_gpu.low, rates[0]);
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

using Formatter = void (*)(uint64_t key, char* out, size_t size);

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

// "file.lua:120" - the function defined at that line (line 0 = the file's main chunk).
void FormatLuaFunc(uint64_t key, char* out, size_t size) {
    const LuaFunc& f = g_luaFuncs[key & (kLuaFuncSlots - 1)];
    snprintf(out, size, "%s:%d", f.source, f.lineDefined);
}

void FormatLuaLine(uint64_t key, char* out, size_t size) {
    const LuaFunc& f = g_luaFuncs[(key >> 32) & (kLuaFuncSlots - 1)];
    snprintf(out, size, "%s  line %d  (function at line %d)", f.source, static_cast<int>(key & 0xFFFFFFFF), f.lineDefined);
}

void WriteTop(FILE* f, const char* title, const Counts& counts, uint64_t total, double msPerUnit, Formatter format,
              size_t limit = kTopFunctions) {
    fprintf(f, "  %s\n", title);
    if (total == 0 || counts.empty()) {
        fprintf(f, "      (none)\n");
        return;
    }
    std::vector<std::pair<uint64_t, uint64_t>> sorted(counts.begin(), counts.end());
    std::sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
    char where[256];
    for (size_t i = 0; i < sorted.size() && i < limit; ++i) {
        format(sorted[i].first, where, sizeof(where));
        const double share = 100.0 * static_cast<double>(sorted[i].second) / static_cast<double>(total);
        if (msPerUnit > 0.0) {
            fprintf(f, "    %6.2f%%  %8.1f ms  %s\n", share, static_cast<double>(sorted[i].second) * msPerUnit, where);
        } else {
            fprintf(f, "    %6.2f%%  %8llu     %s\n", share, static_cast<unsigned long long>(sorted[i].second), where);
        }
    }
}

std::wstring ExeDir() {
    wchar_t exePath[MAX_PATH] = {};
    const DWORD len = GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring path(exePath, len);
    const size_t slash = path.find_last_of(L"\\/");
    if (slash != std::wstring::npos) path.resize(slash + 1);
    return path;
}

std::wstring ReportPath() { return ExeDir() + L"tf3api_profile.txt"; }

// Continuous mode: keeps a copy of each report in the tf3api_profiles folder (newest `keep` of this session).
void ArchiveReport() {
    const std::wstring dir = ExeDir() + L"tf3api_profiles";
    CreateDirectoryW(dir.c_str(), nullptr);
    SYSTEMTIME now;
    GetLocalTime(&now);
    wchar_t name[64];
    swprintf(name, 64, L"\\profile_%02u%02u%02u.txt", now.wHour, now.wMinute, now.wSecond);
    const std::wstring path = dir + name;
    if (!CopyFileW(ReportPath().c_str(), path.c_str(), FALSE)) return;
    g_history.push_back(path);
    while (g_history.size() > static_cast<size_t>(g_settings.keep)) {
        DeleteFileW(g_history.front().c_str());
        g_history.erase(g_history.begin());
    }
}

// Frame times and the game's Vulkan calls over the capture (vkstats.h).
void WriteVulkan(FILE* f, const vkstats::Totals& a, const vkstats::Totals& b, const vkstats::PassSizes& passStart) {
    if (g_gpu.available && g_gpu.samples > 0) {
        fprintf(f, "GPU LOAD (%s, whole card as the driver reports it): average %.0f%%, lowest %u%%, highest %u%% over %llu "
                   "readings\n",
                g_gpu.name, static_cast<double>(g_gpu.sum) / static_cast<double>(g_gpu.samples), g_gpu.low, g_gpu.peak,
                static_cast<unsigned long long>(g_gpu.samples));
    } else {
        fprintf(f, "GPU LOAD: not available (no NVIDIA management library)\n");
    }
    if (vkstats::DeviceName()[0] != '\0') fprintf(f, "GAME RENDERS ON: %s\n", vkstats::DeviceName());
    const occlusion::CameraWindow camera = occlusion::TakeCameraWindow();
    if (camera.frames > 0) {
        fprintf(f, "CAMERA: %.0f m above the ground on average (%.0f to %.0f m), moved %.0f m, field of view %.0f degrees%s\n",
                camera.heightAvg, camera.heightMin, camera.heightMax, camera.travelled, camera.fovDegrees,
                camera.heightMax < 12.0f ? "  [street level / in-vehicle view]" : "");
    }
    if (!vkstats::Active()) {
        fprintf(f, "VULKAN: no statistics (lookup hooks not installed, or the game has not created its renderer yet)\n\n");
        return;
    }
    const uint64_t frameCount = b.frames - a.frames;
    if (frameCount == 0) {
        fprintf(f, "VULKAN: no frame was presented during this capture (created: %llu pipelines, %llu shader modules, "
                   "%llu buffers)\n\n",
                static_cast<unsigned long long>(b.pipelinesCreated - a.pipelinesCreated),
                static_cast<unsigned long long>(b.shaderModulesCreated - a.shaderModulesCreated),
                static_cast<unsigned long long>(b.buffersCreated - a.buffersCreated));
        return;
    }
    std::vector<float> times;
    vkstats::FrameTimesMs(a.frames, b.frames, &times);
    std::sort(times.begin(), times.end());
    if (!times.empty()) {
        double sum = 0.0;
        for (float t : times) sum += t;
        const size_t n = times.size();
        const size_t worstCount = std::max<size_t>(1, n / 100);
        double worstSum = 0.0;
        for (size_t i = n - worstCount; i < n; ++i) worstSum += times[i];
        const double avg = sum / static_cast<double>(n);
        fprintf(f, "FRAMES (present to present): %zu frames, average %.1f ms (%.1f fps), median %.1f ms, worst 1%% average "
                   "%.1f ms, longest %.1f ms\n",
                n, avg, 1000.0 / avg, times[n / 2], worstSum / static_cast<double>(worstCount), times[n - 1]);
    }
    const double frames = static_cast<double>(frameCount);
    const auto ms = [&](uint64_t later, uint64_t earlier) { return vkstats::TicksToMs(later - earlier) / frames; };
    const auto per = [&](uint64_t later, uint64_t earlier) { return static_cast<double>(later - earlier) / frames; };
    const double acquire = ms(b.ticksAcquire, a.ticksAcquire), submit = ms(b.ticksSubmit, a.ticksSubmit);
    const double present = ms(b.ticksPresent, a.ticksPresent), fences = ms(b.ticksWaitFences, a.ticksWaitFences);
    const double idle = ms(b.ticksWaitIdle, a.ticksWaitIdle);
    fprintf(f, "VULKAN, average per frame - time the game spends inside these calls:\n");
    const uint64_t timeout = vkstats::LastAcquireTimeout();
    if (timeout == ~0ull) {
        fprintf(f, "    acquire next image %7.2f ms  (the game asks to wait without limit)\n", acquire);
    } else {
        fprintf(f, "    acquire next image %7.2f ms  (the game passes a %.1f ms timeout)\n", acquire,
                static_cast<double>(timeout) / 1e6);
    }
    fprintf(f, "    queue submit       %7.2f ms  (%.1f calls)\n", submit, per(b.submits, a.submits));
    fprintf(f, "    present            %7.2f ms\n", present);
    fprintf(f, "    wait for fences    %7.2f ms  (%.1f calls)\n", fences, per(b.fenceWaits, a.fenceWaits));
    fprintf(f, "    wait idle          %7.2f ms\n", idle);
    fprintf(f, "    total              %7.2f ms\n", acquire + submit + present + fences + idle);
    fprintf(f, "  work submitted per frame:\n");
    fprintf(f, "    draw calls         %9.0f  (%.0f instances, about %.0f triangles)\n", per(b.draws, a.draws),
            per(b.instances, a.instances), per(b.indices, a.indices) / 3.0);
    fprintf(f, "    indirect commands  %9.0f  (up to %.0f draws)\n", per(b.indirectCalls, a.indirectCalls),
            per(b.indirectDraws, a.indirectDraws));
    fprintf(f, "    pipeline binds     %9.0f\n", per(b.pipelineBinds, a.pipelineBinds));
    fprintf(f, "    descriptor set binds %7.0f, descriptor writes %.0f, vertex buffer binds %.0f, render passes %.1f\n",
            per(b.descriptorSetBinds, a.descriptorSetBinds), per(b.descriptorSetUpdates, a.descriptorSetUpdates),
            per(b.vertexBufferBinds, a.vertexBufferBinds), per(b.renderPasses, a.renderPasses));
    // Render passes by size: what the frame is made of, and how many pixels of render target it covers.
    const vkstats::PassSizes passEnd = vkstats::SnapshotPassSizes();
    struct Row {
        uint32_t width, height;
        double perFrame, draws, triangles;
    };
    std::vector<Row> rows;
    double megapixels = 0.0;
    for (int i = 0; i < vkstats::kMaxPassSizes; ++i) {
        const uint64_t count = passEnd.count[i] - passStart.count[i];
        if (count == 0) continue;
        rows.push_back({passEnd.width[i], passEnd.height[i], static_cast<double>(count) / frames,
                        static_cast<double>(passEnd.draws[i] - passStart.draws[i]) / frames,
                        static_cast<double>(passEnd.indices[i] - passStart.indices[i]) / frames / 3.0});
        megapixels += static_cast<double>(count) / frames * passEnd.width[i] * passEnd.height[i] / 1e6;
    }
    std::sort(rows.begin(), rows.end(), [](const Row& x, const Row& y) {
        return x.perFrame * x.width * x.height > y.perFrame * y.width * y.height;
    });
    fprintf(f, "  render passes per frame by target size (%.0f megapixels of render area per frame in total):\n", megapixels);
    for (size_t i = 0; i < rows.size() && i < 14; ++i) {
        fprintf(f, "    %6.1f x  %5u x %-5u  = %7.1f megapixels   %6.0f draws  %9.0f triangles\n", rows[i].perFrame,
                rows[i].width, rows[i].height, rows[i].perFrame * rows[i].width * rows[i].height / 1e6, rows[i].draws,
                rows[i].triangles);
    }
    if (passEnd.other != passStart.other) {
        fprintf(f, "    %6.1f x  other sizes\n", static_cast<double>(passEnd.other - passStart.other) / frames);
    }
    fprintf(f, "  texture and resource traffic per frame:\n");
    fprintf(f, "    textures created %.2f, destroyed %.2f, uploads %.2f (%.2f mip levels/layers), image views %.2f, samplers %.2f\n",
            per(b.imagesCreated, a.imagesCreated), per(b.imagesDestroyed, a.imagesDestroyed),
            per(b.imageUploads, a.imageUploads), per(b.imageUploadRegions, a.imageUploadRegions),
            per(b.imageViewsCreated, a.imageViewsCreated), per(b.samplersCreated, a.samplersCreated));
    fprintf(f, "    buffers created %.1f, destroyed %.1f, descriptor set allocations %.1f\n",
            per(b.buffersCreated, a.buffersCreated), per(b.buffersDestroyed, a.buffersDestroyed),
            per(b.descriptorSetAllocations, a.descriptorSetAllocations));
    fprintf(f, "  created during the whole capture: %llu pipelines (%.0f ms inside the call), %llu shader modules, %llu buffers, "
               "%llu memory allocations\n\n",
            static_cast<unsigned long long>(b.pipelinesCreated - a.pipelinesCreated),
            vkstats::TicksToMs(b.ticksCreatePipelines - a.ticksCreatePipelines),
            static_cast<unsigned long long>(b.shaderModulesCreated - a.shaderModulesCreated),
            static_cast<unsigned long long>(b.buffersCreated - a.buffersCreated),
            static_cast<unsigned long long>(b.memoryAllocations - a.memoryAllocations));
}

void WriteReport(std::vector<ThreadRec>& threads, double seconds, uint64_t sweeps, double cyclesPerMs,
                 const vkstats::Totals& vkStart, const vkstats::Totals& vkEnd, const vkstats::PassSizes& passStart) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, ReportPath().c_str(), L"w") != 0 || f == nullptr) {
        TF3_LOG("profiler: could not write tf3api_profile.txt");
        return;
    }
    std::sort(threads.begin(), threads.end(), [](const ThreadRec& a, const ThreadRec& b) { return a.cycles > b.cycles; });

    const double msPerCycle = 1.0 / cyclesPerMs;
    const double captureMs = seconds * 1000.0;
    uint64_t processCycles = 0, betweenCycles = 0;
    for (const ThreadRec& t : threads) {
        processCycles += t.cycles;
        betweenCycles += t.betweenCycles;
    }
    const double processMs = static_cast<double>(processCycles) * msPerCycle;

    SYSTEM_INFO sys = {};
    GetSystemInfo(&sys);
    SYSTEMTIME now;
    GetLocalTime(&now);
    fprintf(f, "TF3OpenAPI - sampling profile  %04u-%02u-%02u %02u:%02u:%02u\n", now.wYear, now.wMonth, now.wDay,
            now.wHour, now.wMinute, now.wSecond);
    fprintf(f, "capture: %.1f s, %llu sweeps (%.0f per second), %zu threads\n", seconds,
            static_cast<unsigned long long>(sweeps), static_cast<double>(sweeps) / seconds, threads.size());
    fprintf(f, "process CPU: %.0f ms = %.2f cores busy on average = %.1f%% of the machine's %lu logical cores\n", processMs,
            processMs / captureMs, 100.0 * processMs / (captureMs * sys.dwNumberOfProcessors), sys.dwNumberOfProcessors);
    fprintf(f, "CPU time is measured per thread in cycles (kernel time included) and split between functions by\n"
               "sample; a function is the engine/game code that was running or had called into the system.\n"
               "\"between samples\" = CPU a thread used in a burst that started and ended between two samples\n"
               "(it was blocked again when sampled), so it cannot be given to a function: %.1f%% of process CPU.\n"
               "Lua: %s\n\n",
            processCycles ? 100.0 * static_cast<double>(betweenCycles) / static_cast<double>(processCycles) : 0.0,
            g_luaModule >= 0 ? "script functions are listed as file:line-of-definition (line 0 = the file's main chunk)"
                             : "interpreter not located in this build - no script attribution");
    WriteVulkan(f, vkStart, vkEnd, passStart);

    fprintf(f, "THREADS by CPU time (%%core = share of one core; %%proc = share of the process's CPU time;\n"
               "                     blocked = share of samples that found the thread waiting)\n");
    fprintf(f, "     tid   %%core   %%proc    cpu ms  blocked  name\n");
    for (const ThreadRec& t : threads) {
        const double cpuMs = static_cast<double>(t.cycles) * msPerCycle;
        if (cpuMs < 1.0) continue;
        fprintf(f, "  %6lu  %5.1f%%  %5.1f%%  %8.0f  %6.1f%%  %s\n", t.tid, 100.0 * cpuMs / captureMs,
                processMs > 0.0 ? 100.0 * cpuMs / processMs : 0.0, cpuMs,
                t.samples ? 100.0 * static_cast<double>(t.waitSamples) / static_cast<double>(t.samples) : 0.0,
                ThreadName(t.handle).c_str());
    }

    Counts all, allLua;
    for (const ThreadRec& t : threads) {
        for (const auto& kv : t.self) all[kv.first] += kv.second;
        for (const auto& kv : t.luaSelf) allLua[kv.first] += kv.second;
    }
    fprintf(f, "\nALL THREADS - where the process's CPU time goes\n");
    WriteTop(f, "SELF - % of process CPU time", all, processCycles, msPerCycle, FormatKey);
    WriteTop(f, "LUA SCRIPTS, SELF - % of process CPU time (script function incl. the engine calls it makes)", allLua,
             processCycles, msPerCycle, FormatLuaFunc);

    int shown = 0;
    for (const ThreadRec& t : threads) {
        if (shown >= kTopThreads || t.cycles == 0) break;
        const double cpuMs = static_cast<double>(t.cycles) * msPerCycle;
        fprintf(f, "\n== thread %lu \"%s\"  %.0f ms CPU (%.1f%% of a core, %.1f%% of process), %llu samples, %llu blocked, "
                   "%.1f%% of its CPU between samples\n",
                t.tid, ThreadName(t.handle).c_str(), cpuMs, 100.0 * cpuMs / captureMs,
                processMs > 0.0 ? 100.0 * cpuMs / processMs : 0.0, static_cast<unsigned long long>(t.samples),
                static_cast<unsigned long long>(t.waitSamples),
                100.0 * static_cast<double>(t.betweenCycles) / static_cast<double>(t.cycles));
        WriteTop(f, "SELF - % of this thread's CPU time", t.self, t.cycles, msPerCycle, FormatKey);
        WriteTop(f, "INCLUSIVE - % of this thread's CPU time with the function anywhere on the stack", t.inclusive, t.cycles,
                 msPerCycle, FormatKey);
        if (!t.luaSelf.empty()) {
            WriteTop(f, "LUA SELF - % of this thread's CPU time in the script function (incl. the engine calls it makes)",
                     t.luaSelf, t.cycles, msPerCycle, FormatLuaFunc, 25);
            WriteTop(f, "LUA INCLUSIVE - % of this thread's CPU time with the script function on the Lua call stack",
                     t.luaIncl, t.cycles, msPerCycle, FormatLuaFunc, 40);
            WriteTop(f, "LUA HOT LINES - % of this thread's CPU time by the line being executed", t.luaLines, t.cycles,
                     msPerCycle, FormatLuaLine, 25);
        }
        WriteTop(f, "BLOCKED IN - % of this thread's blocked samples, by the engine function that made the call",
                 t.waitingIn, t.waitSamples, 0.0, FormatKey);
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
    LoadWaitStubs();
    std::memset(g_luaFuncs, 0, sizeof(g_luaFuncs));
    g_luaModule = g_luaExecute != 0 ? FindModule(g_luaExecute) : -1;
    if (g_luaModule >= 0) g_luaExecuteRva = static_cast<uint32_t>(g_luaExecute - g_modules[g_luaModule].base);

    std::vector<ThreadRec> threads;
    threads.reserve(256);
    RefreshThreads(threads);

    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    const LONGLONG intervalHns = 10000000ll / g_settings.rateHz;  // 100 ns units

    LARGE_INTEGER freq, start, now;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    const uint64_t tscStart = __rdtsc();
    const vkstats::Totals vkStart = vkstats::Snapshot();
    const vkstats::PassSizes passStart = vkstats::SnapshotPassSizes();
    occlusion::TakeCameraWindow();  // start a fresh camera window for this capture
    InitGpuLoad();
    g_gpu.samples = g_gpu.sum = 0;
    g_gpu.peak = 0;
    g_gpu.low = 100;
    uint64_t nextGpuSample = 0;
    const double duration = static_cast<double>(g_settings.seconds);
    if (!g_settings.continuous) {
        TF3_LOG("profiler: capturing %d s at %d Hz (%zu threads, Lua attribution %s)...", g_settings.seconds,
                g_settings.rateHz, threads.size(), g_luaModule >= 0 ? "on" : "off");
    }

    uint64_t sweeps = 0;
    RawFrame frames[kMaxFrames];
    LuaSample luaSample;
    for (;;) {
        QueryPerformanceCounter(&now);
        if (static_cast<double>(now.QuadPart - start.QuadPart) / static_cast<double>(freq.QuadPart) >= duration) break;
        if (g_stop.load(std::memory_order_relaxed)) break;

        for (ThreadRec& t : threads) {
            // A thread that was blocked at its last sample and has used no CPU since is still in that same
            // wait: count it without suspending it. This keeps the sweep cheap (most threads are idle).
            ULONG64 cycles = t.lastCycles;
            QueryThreadCycleTime(t.handle, &cycles);
            if (t.lastBlocked && cycles == t.lastCycles) {
                ++t.samples;
                ++t.waitSamples;
                ++t.waitingIn[t.lastWaitKey];
                t.lastTsc = __rdtsc();
                continue;
            }
            if (SuspendThread(t.handle) == static_cast<DWORD>(-1)) continue;
            // ---- thread suspended: no allocation, no locks ----
            CONTEXT ctx;
            ctx.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
            bool inKernel = false, inWaitStub = false;
            uintptr_t luaState = 0;
            int n = 0;
            if (GetThreadContext(t.handle, &ctx)) n = WalkStack(&ctx, frames, &inKernel, &inWaitStub, &luaState);
            luaSample.count = 0;
            if (luaState != 0) ReadLuaStack(luaState, &luaSample);
            QueryThreadCycleTime(t.handle, &cycles);
            const uint64_t tsc = __rdtsc();
            ResumeThread(t.handle);
            // ---- resumed ----
            const uint64_t used = cycles > t.lastCycles ? cycles - t.lastCycles : 0;
            const uint64_t wall = tsc - t.lastTsc;
            t.lastCycles = cycles;
            t.lastTsc = tsc;
            // In a system call that is not a known wait: blocked if it has used next to no CPU (e.g. a driver wait).
            const bool blocked = inWaitStub || (inKernel && used * 10 < wall);
            if (n > 0) Tally(t, frames, n, blocked, used, luaSample);
        }
        ++sweeps;
        if (sweeps % 512 == 0) RefreshThreads(threads);
        if (static_cast<uint64_t>(now.QuadPart) >= nextGpuSample) {
            SampleGpuLoad();
            nextGpuSample = static_cast<uint64_t>(now.QuadPart) + static_cast<uint64_t>(freq.QuadPart) / 4;
        }

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

    if (g_stop.load(std::memory_order_relaxed)) {
        for (ThreadRec& t : threads) CloseHandle(t.handle);
        return;
    }
    WriteReport(threads, seconds, sweeps, cyclesPerMs, vkStart, vkstats::Snapshot(), passStart);
    for (ThreadRec& t : threads) CloseHandle(t.handle);
    if (g_settings.continuous) {
        ArchiveReport();
    } else {
        TF3_LOG("profiler: done - %llu sweeps in %.1f s, report written to tf3api_profile.txt",
                static_cast<unsigned long long>(sweeps), seconds);
    }
}

// Builds a fake Lua call stack with the layout above and checks ReadLuaStack decodes it: catches a
// slip in this file's offsets or logic (the offsets themselves come from the game's own code).
bool LuaSelfTest() {
    alignas(8) static uint8_t state[0x80], ci[3][0x40], closure[3][0x20], proto[2][0x70], value[3][16];
    alignas(8) static uint8_t source[2][0x40];
    alignas(4) static uint32_t code[8];
    alignas(4) static int lineInfo[8] = {10, 11, 12, 13, 14, 15, 16, 17};
    const auto put = [](uint8_t* at, size_t offset, uintptr_t v) { std::memcpy(at + offset, &v, sizeof(v)); };
    const char* names[2] = {"@mods/test/inner.lua", "@mods/test/outer.lua"};
    for (int i = 0; i < 2; ++i) {
        put(source[i], lua::kStringLen, std::strlen(names[i]));
        std::memcpy(source[i] + lua::kStringData, names[i], std::strlen(names[i]) + 1);
        put(proto[i], lua::kProtoSource, reinterpret_cast<uintptr_t>(source[i]));
        put(proto[i], lua::kProtoCode, reinterpret_cast<uintptr_t>(code));
        put(proto[i], lua::kProtoLineInfo, reinterpret_cast<uintptr_t>(lineInfo));
        const int sizeLineInfo = 8, lineDefined = 100 + i;
        std::memcpy(proto[i] + lua::kProtoSizeLineInfo, &sizeLineInfo, 4);
        std::memcpy(proto[i] + lua::kProtoLineDefined, &lineDefined, 4);
    }
    // ci[0] = inner Lua function (pc after instruction 3), ci[1] = a C function, ci[2] = outer Lua function.
    for (int i = 0; i < 3; ++i) {
        closure[i][lua::kClosureType] = (i == 1) ? 0x26 : 6;
        put(closure[i], lua::kClosureProto, reinterpret_cast<uintptr_t>(proto[i == 0 ? 0 : 1]));
        put(value[i], 0, reinterpret_cast<uintptr_t>(closure[i]));
        put(ci[i], lua::kCiFunc, reinterpret_cast<uintptr_t>(value[i]));
        put(ci[i], lua::kCiPrevious, i < 2 ? reinterpret_cast<uintptr_t>(ci[i + 1]) : 0);
        ci[i][lua::kCiCallStatus] = (i == 1) ? 0 : 1;
        put(ci[i], lua::kCiSavedPc, reinterpret_cast<uintptr_t>(&code[4]));
    }
    state[lua::kStateType] = 8;
    put(state, lua::kStateCi, reinterpret_cast<uintptr_t>(ci[0]));

    std::memset(g_luaFuncs, 0, sizeof(g_luaFuncs));
    LuaSample sample;
    ReadLuaStack(reinterpret_cast<uintptr_t>(state), &sample);
    bool ok = sample.count == 2 && sample.line == 13;
    if (ok) {
        const LuaFunc& inner = g_luaFuncs[sample.fn[0]];
        const LuaFunc& outer = g_luaFuncs[sample.fn[1]];
        ok = std::strcmp(inner.source, names[0]) == 0 && inner.lineDefined == 100 &&
             std::strcmp(outer.source, names[1]) == 0 && outer.lineDefined == 101;
    }
    LuaSample bad;
    ReadLuaStack(0x1234567, &bad);                       // unaligned garbage
    ReadLuaStack(reinterpret_cast<uintptr_t>(code), &bad);  // readable, but not a lua_State
    ok = ok && bad.count == 0;
    std::memset(g_luaFuncs, 0, sizeof(g_luaFuncs));
    return ok;
}

bool GameWindowFocused() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

DWORD WINAPI HotkeyThread(LPVOID) {
    SetThreadDescription(GetCurrentThread(), L"tf3api profiler");
    if (!LuaSelfTest()) {
        TF3_LOG("profiler: Lua stack reader self-test FAILED - script attribution disabled");
        g_luaExecute = 0;
    }
    if (g_settings.continuous) {
        TF3_LOG("profiler: running continuously - a %d s report every %d s at %d Hz; tf3api_profile.txt is the latest, "
                "the tf3api_profiles folder keeps the last %d (Lua script attribution %s)",
                g_settings.seconds, g_settings.seconds, g_settings.rateHz, g_settings.keep,
                g_luaExecute != 0 ? "available" : "unavailable");
        while (!g_stop.load(std::memory_order_relaxed)) Capture();
        return 0;
    }
    if (!RegisterHotKey(nullptr, 1, MOD_NOREPEAT, static_cast<UINT>(g_settings.key))) {
        TF3_LOG("profiler: could not register hotkey %d (error %lu) - profiler unavailable", g_settings.key, GetLastError());
        return 0;
    }
    TF3_LOG("profiler: ready - press key %d in-game to capture %d s (Lua script attribution %s)", g_settings.key,
            g_settings.seconds, g_luaExecute != 0 ? "available" : "unavailable");
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
    g_settings.rateHz = config::GetInt("Profiler", "RateHz", 500);
    g_settings.autoCaptureAfter = config::GetInt("Profiler", "AutoCaptureAfter", 0);
    g_settings.continuous = config::GetBool("Profiler", "Continuous", false);
    g_settings.keep = config::GetInt("Profiler", "Keep", 30);
    if (g_settings.keep < 1 || g_settings.keep > 1000) g_settings.keep = 30;
    if (g_settings.key <= 0 && !g_settings.continuous) return;
    if (g_settings.autoCaptureAfter < 0 || g_settings.autoCaptureAfter > 3600) g_settings.autoCaptureAfter = 0;
    if (g_settings.seconds < 1 || g_settings.seconds > 120) g_settings.seconds = 10;
    if (g_settings.rateHz < 10 || g_settings.rateHz > 2000) g_settings.rateHz = 500;
    g_luaExecute = sigscan::FindUnique("luaV_execute (Lua interpreter loop)", kSigLuaExecute);
    g_hotkeyThread = CreateThread(nullptr, 0, HotkeyThread, nullptr, 0, &g_hotkeyThreadId);
}

void Uninstall() {
    if (g_hotkeyThread == nullptr) return;
    g_stop.store(true);
    PostThreadMessageW(g_hotkeyThreadId, WM_QUIT, 0, 0);
    WaitForSingleObject(g_hotkeyThread, 500);
    CloseHandle(g_hotkeyThread);
    g_hotkeyThread = nullptr;
}

} // namespace tf3api::profiler
