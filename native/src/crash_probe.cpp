#include "crash_probe.h"

#include "config.h"
#include "log.h"

#include <windows.h>

#include <psapi.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace tf3opt::crash_probe {
namespace {

constexpr DWORD kMsvcCppException = 0xE06D7363;  // 'msc' | 0xE0000000
constexpr LONG kMaxReports = 3;
constexpr USHORT kMaxFrames = 48;

PVOID g_handler = nullptr;
volatile LONG g_reports = 0;

// MSVC x64 C++ throw: ExceptionInformation[2] = ThrowInfo (image-relative fields), [3] = image base.
// ThrowInfo { attributes, pmfnUnwind, pForwardCompat, pCatchableTypeArray }
// CatchableTypeArray { nCatchableTypes, arrayOfCatchableTypes[] }
// CatchableType { properties, pType, ... } -> TypeDescriptor { pVFTable, spare, name[] }
bool IsBadAlloc(const EXCEPTION_RECORD* rec) {
    if (rec->NumberParameters < 4) return false;
    auto imageBase = static_cast<uintptr_t>(rec->ExceptionInformation[3]);
    auto throwInfo = reinterpret_cast<const uint32_t*>(rec->ExceptionInformation[2]);
    if (imageBase == 0 || throwInfo == nullptr) return false;
    __try {
        auto typeArray = reinterpret_cast<const uint32_t*>(imageBase + throwInfo[3]);
        uint32_t count = typeArray[0];
        if (count > 16) return false;
        for (uint32_t i = 0; i < count; ++i) {
            auto catchable = reinterpret_cast<const uint32_t*>(imageBase + typeArray[1 + i]);
            auto name = reinterpret_cast<const char*>(imageBase + catchable[1] + 16);
            if (std::strstr(name, "bad_alloc") != nullptr) return true;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    return false;
}

// Writes "module+offset" for an address into a caller buffer (no heap - runs during out-of-memory).
void DescribeAddress(void* address, char* buffer, size_t size) {
    HMODULE module = nullptr;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           static_cast<LPCSTR>(address), &module) &&
        module != nullptr) {
        char path[MAX_PATH] = {};
        GetModuleFileNameA(module, path, MAX_PATH);
        const char* file = std::strrchr(path, '\\');
        file = file ? file + 1 : path;
        auto offset = reinterpret_cast<uintptr_t>(address) - reinterpret_cast<uintptr_t>(module);
        // Offsets in the game exe are also given as a build-40408 virtual address (image base 0x140000000).
        if (module == GetModuleHandleW(nullptr)) {
            snprintf(buffer, size, "%s+0x%llx (0x%llx)", file, static_cast<unsigned long long>(offset),
                     static_cast<unsigned long long>(0x140000000ull + offset));
        } else {
            snprintf(buffer, size, "%s+0x%llx", file, static_cast<unsigned long long>(offset));
        }
        return;
    }
    snprintf(buffer, size, "0x%p", address);
}

LONG CALLBACK OnException(EXCEPTION_POINTERS* info) {
    const EXCEPTION_RECORD* rec = info->ExceptionRecord;
    if (rec->ExceptionCode != kMsvcCppException) return EXCEPTION_CONTINUE_SEARCH;
    if (g_reports >= kMaxReports || !IsBadAlloc(rec)) return EXCEPTION_CONTINUE_SEARCH;
    LONG report = InterlockedIncrement(&g_reports);
    if (report > kMaxReports) return EXCEPTION_CONTINUE_SEARCH;

    PROCESS_MEMORY_COUNTERS_EX mem = {};
    GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&mem), sizeof(mem));
    MEMORYSTATUSEX sys = {};
    sys.dwLength = sizeof(sys);
    GlobalMemoryStatusEx(&sys);
    TF3_LOG("bad_alloc #%ld on thread %lu: private %llu MB, commit avail %llu MB of %llu MB", report,
            GetCurrentThreadId(), static_cast<unsigned long long>(mem.PrivateUsage >> 20),
            static_cast<unsigned long long>(sys.ullAvailPageFile >> 20),
            static_cast<unsigned long long>(sys.ullTotalPageFile >> 20));

    void* frames[kMaxFrames] = {};
    USHORT n = RtlCaptureStackBackTrace(0, kMaxFrames, frames, nullptr);
    char where[MAX_PATH + 64];
    for (USHORT i = 0; i < n; ++i) {
        DescribeAddress(frames[i], where, sizeof(where));
        TF3_LOG("   #%02u %s", i, where);
    }
    return EXCEPTION_CONTINUE_SEARCH;  // never handle it - the game's own handling runs as before
}

} // namespace

void Install() {
    if (!config::GetBool("Debug", "BadAllocProbe", true)) return;
    g_handler = AddVectoredExceptionHandler(1, OnException);
    TF3_LOG("crash_probe: %s", g_handler ? "bad_alloc stack logging active" : "failed to install");
}

void Uninstall() {
    if (g_handler) RemoveVectoredExceptionHandler(g_handler);
    g_handler = nullptr;
}

} // namespace tf3opt::crash_probe
