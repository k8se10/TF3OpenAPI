#include "alloc_profiler.h"

#include "config.h"
#include "log.h"

#include <windows.h>

#include <psapi.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#include "MinHook.h"

namespace tf3api::alloc_profiler {
namespace {

using NtAllocateVirtualMemoryFn = LONG(NTAPI*)(HANDLE, PVOID*, ULONG_PTR, PSIZE_T, ULONG, ULONG);

constexpr int kFrames = 24;
constexpr int kTableSize = 8192;  // power of two
constexpr int kTopToReport = 12;
constexpr unsigned long long kReportStepBytes = 2ull << 30;  // report every +2 GB of private bytes
constexpr DWORD kPollMs = 5000;

struct Entry {
    uint64_t hash;
    uint64_t bytes;
    uint32_t count;
    uint32_t frameCount;
    void* frames[kFrames];
};

Entry g_table[kTableSize];  // static storage: no heap use from inside the hook
Entry g_snapshot[kTableSize];
SRWLOCK g_lock = SRWLOCK_INIT;
volatile LONG g_dropped = 0;
// Per-thread re-entry guard. NOT thread_local: ntdll commits memory for new threads before their
// implicit TLS block exists, so a thread_local access from the hook crashes (seen live 2026-10-10).
// A TLS slot index < 64 lives directly in the TEB, so TlsGetValue/TlsSetValue never allocate.
DWORD g_tlsGuard = TLS_OUT_OF_INDEXES;

NtAllocateVirtualMemoryFn g_original = nullptr;
void* g_target = nullptr;
HANDLE g_monitor = nullptr;
HANDLE g_stop = nullptr;

uint64_t HashFrames(void* const* frames, int n) {
    uint64_t h = 1469598103934665603ull;  // FNV-1a over the frame addresses
    for (int i = 0; i < n; ++i) {
        h ^= reinterpret_cast<uint64_t>(frames[i]);
        h *= 1099511628211ull;
    }
    return h ? h : 1;
}

void Record(SIZE_T bytes) {
    void* frames[kFrames] = {};
    int n = RtlCaptureStackBackTrace(2, kFrames, frames, nullptr);  // skip Record + the hook
    uint64_t hash = HashFrames(frames, n);

    AcquireSRWLockExclusive(&g_lock);
    for (int probe = 0; probe < kTableSize; ++probe) {
        Entry& e = g_table[(hash + static_cast<uint64_t>(probe)) & (kTableSize - 1)];
        if (e.hash == hash) {
            e.bytes += bytes;
            ++e.count;
            ReleaseSRWLockExclusive(&g_lock);
            return;
        }
        if (e.hash == 0) {
            e.hash = hash;
            e.bytes = bytes;
            e.count = 1;
            e.frameCount = static_cast<uint32_t>(n);
            std::memcpy(e.frames, frames, sizeof(void*) * static_cast<size_t>(n));
            ReleaseSRWLockExclusive(&g_lock);
            return;
        }
    }
    ReleaseSRWLockExclusive(&g_lock);
    InterlockedIncrement(&g_dropped);
}

LONG NTAPI HookNtAllocateVirtualMemory(HANDLE process, PVOID* base, ULONG_PTR zeroBits, PSIZE_T size, ULONG type,
                                       ULONG protect) {
    LONG status = g_original(process, base, zeroBits, size, type, protect);
    // Only commits in this process (the pseudo-handle -1 is how the process refers to itself).
    if (status >= 0 && (type & MEM_COMMIT) && size != nullptr && process == GetCurrentProcess()) {
        DWORD lastError = GetLastError();  // TlsGetValue resets it; the caller may rely on it
        if (TlsGetValue(g_tlsGuard) == nullptr) {
            TlsSetValue(g_tlsGuard, reinterpret_cast<void*>(1));
            Record(*size);
            TlsSetValue(g_tlsGuard, nullptr);
        }
        SetLastError(lastError);
    }
    return status;
}

void Describe(void* address, char* out, size_t size) {
    HMODULE module = nullptr;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           static_cast<LPCSTR>(address), &module) &&
        module != nullptr) {
        char path[MAX_PATH] = {};
        GetModuleFileNameA(module, path, MAX_PATH);
        const char* file = std::strrchr(path, '\\');
        file = file ? file + 1 : path;
        auto offset = reinterpret_cast<uintptr_t>(address) - reinterpret_cast<uintptr_t>(module);
        if (module == GetModuleHandleW(nullptr)) {
            snprintf(out, size, "%s+0x%llx (0x%llx)", file, static_cast<unsigned long long>(offset),
                     static_cast<unsigned long long>(0x140000000ull + offset));
        } else {
            snprintf(out, size, "%s+0x%llx", file, static_cast<unsigned long long>(offset));
        }
        return;
    }
    snprintf(out, size, "0x%p", address);
}

void ReportTop(unsigned long long privateBytes) {
    AcquireSRWLockShared(&g_lock);
    std::memcpy(g_snapshot, g_table, sizeof(g_snapshot));
    ReleaseSRWLockShared(&g_lock);

    TF3_LOG("alloc_profiler: private %llu MB - top call stacks by committed bytes (dropped stacks: %ld)",
            privateBytes >> 20, g_dropped);
    static bool used[kTableSize];
    std::memset(used, 0, sizeof(used));
    char where[MAX_PATH + 64];
    for (int rank = 0; rank < kTopToReport; ++rank) {
        int best = -1;
        for (int i = 0; i < kTableSize; ++i) {
            if (g_snapshot[i].hash == 0 || used[i]) continue;
            if (best < 0 || g_snapshot[i].bytes > g_snapshot[best].bytes) best = i;
        }
        if (best < 0) break;
        used[best] = true;
        const Entry& e = g_snapshot[best];
        TF3_LOG("  [%d] %llu MB in %u commits", rank + 1, static_cast<unsigned long long>(e.bytes >> 20), e.count);
        for (uint32_t f = 0; f < e.frameCount; ++f) {
            Describe(e.frames[f], where, sizeof(where));
            TF3_LOG("        #%02u %s", f, where);
        }
    }
}

unsigned long long PrivateBytes() {
    PROCESS_MEMORY_COUNTERS_EX mem = {};
    GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&mem), sizeof(mem));
    return mem.PrivateUsage;
}

DWORD WINAPI MonitorThread(LPVOID) {
    const unsigned long long baseline = PrivateBytes();
    unsigned long long nextReport = baseline + kReportStepBytes;
    TF3_LOG("alloc_profiler: monitoring, baseline private %llu MB", baseline >> 20);
    int ticks = 0;
    while (WaitForSingleObject(g_stop, kPollMs) == WAIT_TIMEOUT) {
        unsigned long long now = PrivateBytes();
        if (++ticks % 6 == 0) TF3_LOG("alloc_profiler: private %llu MB", now >> 20);
        if (now >= nextReport) {
            ReportTop(now);
            while (nextReport <= now) nextReport += kReportStepBytes;
        }
    }
    return 0;
}

} // namespace

void Install() {
    if (!config::GetBool("Debug", "AllocProfiler", false)) return;

    g_tlsGuard = TlsAlloc();
    if (g_tlsGuard == TLS_OUT_OF_INDEXES || g_tlsGuard >= TLS_MINIMUM_AVAILABLE) {
        // Slots >= 64 are allocated on demand, which would itself call into the hook.
        TF3_LOG("alloc_profiler: no low TLS slot available (%lu) - not installed", g_tlsGuard);
        if (g_tlsGuard != TLS_OUT_OF_INDEXES) TlsFree(g_tlsGuard);
        g_tlsGuard = TLS_OUT_OF_INDEXES;
        return;
    }

    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    g_target = ntdll ? reinterpret_cast<void*>(GetProcAddress(ntdll, "NtAllocateVirtualMemory")) : nullptr;
    if (g_target == nullptr) {
        TF3_LOG("alloc_profiler: NtAllocateVirtualMemory not found");
        return;
    }
    MH_STATUS status = MH_CreateHook(g_target, reinterpret_cast<void*>(&HookNtAllocateVirtualMemory),
                                     reinterpret_cast<void**>(&g_original));
    if (status == MH_OK) status = MH_EnableHook(g_target);
    if (status != MH_OK) {
        TF3_LOG("alloc_profiler: hook failed (%d)", static_cast<int>(status));
        g_target = nullptr;
        return;
    }
    g_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_monitor = CreateThread(nullptr, 0, MonitorThread, nullptr, 0, nullptr);
    TF3_LOG("alloc_profiler: active");
}

void Uninstall() {
    if (g_stop) SetEvent(g_stop);
    if (g_monitor) {
        WaitForSingleObject(g_monitor, 2000);
        CloseHandle(g_monitor);
        g_monitor = nullptr;
    }
    if (g_target) {
        MH_DisableHook(g_target);
        MH_RemoveHook(g_target);
        g_target = nullptr;
    }
    if (g_stop) {
        CloseHandle(g_stop);
        g_stop = nullptr;
    }
    if (g_tlsGuard != TLS_OUT_OF_INDEXES) {
        TlsFree(g_tlsGuard);
        g_tlsGuard = TLS_OUT_OF_INDEXES;
    }
}

} // namespace tf3api::alloc_profiler
