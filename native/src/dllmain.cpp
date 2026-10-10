// TF3 Optimizations - native tier.
//
// Loaded by the game as a proxy winhttp.dll placed next to TransportFever3.exe (the exe imports
// WINHTTP.dll directly, and winhttp is not a KnownDLL, so the copy in the game folder wins the search
// order). Every winhttp export is forwarded to the real system DLL (winhttp_forward.h).
//
// Modules: cockpit-camera depth fix, terrain occlusion culling, and three diagnostics (bad_alloc probe,
// allocation profiler, sampling profiler). Each has its own switch in tf3opt.ini.

#include "winhttp_forward.h"

#include "alloc_profiler.h"
#include "camera_fix.h"
#include "crash_probe.h"
#include "log.h"
#include "occlusion.h"
#include "profiler.h"
#include "shadow_tuning.h"
#include "vkstats.h"

#include <windows.h>

#include "MinHook.h"

namespace {

bool g_minHookReady = false;

DWORD WINAPI InitThread(LPVOID) {
    TF3_LOG("tf3opt native loaded");
    tf3opt::crash_probe::Install();
    MH_STATUS mh = MH_Initialize();
    g_minHookReady = (mh == MH_OK || mh == MH_ERROR_ALREADY_INITIALIZED);
    if (g_minHookReady) {
        tf3opt::alloc_profiler::Install();
        tf3opt::occlusion::Install();
        tf3opt::vkstats::Install();
        tf3opt::shadow_tuning::Install();
    } else {
        TF3_LOG("MinHook init failed (%d) - allocation profiler and occlusion culling unavailable",
                static_cast<int>(mh));
    }
    tf3opt::camera_fix::Install();
    tf3opt::profiler::Install();
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    switch (reason) {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(module);
        tf3opt::log::Init();
        // The main module is fully mapped by the time this proxy loads, so patching from a worker
        // thread (off the loader lock) is safe.
        if (HANDLE thread = CreateThread(nullptr, 0, InitThread, nullptr, 0, nullptr)) CloseHandle(thread);
        break;
    case DLL_PROCESS_DETACH:
        tf3opt::profiler::Uninstall();
        tf3opt::vkstats::Uninstall();
        tf3opt::shadow_tuning::Uninstall();
        tf3opt::occlusion::Uninstall();
        tf3opt::camera_fix::Uninstall();
        tf3opt::crash_probe::Uninstall();
        tf3opt::alloc_profiler::Uninstall();
        if (g_minHookReady) MH_Uninitialize();
        tf3opt::log::Shutdown();
        break;
    }
    return TRUE;
}
