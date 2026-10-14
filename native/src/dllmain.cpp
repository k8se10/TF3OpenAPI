// TF3OpenAPI - native tier.
//
// Loaded by the game as a proxy winhttp.dll placed next to TransportFever3.exe (the exe imports
// WINHTTP.dll directly, and winhttp is not a KnownDLL, so the copy in the game folder wins the search
// order). Every winhttp export is forwarded to the real system DLL (winhttp_forward.h).
//
// Modules: cockpit-camera depth fix, terrain occlusion culling, and three diagnostics (bad_alloc probe,
// allocation profiler, sampling profiler). Each has its own switch in tf3api.ini.

#include "winhttp_forward.h"

#include "alloc_profiler.h"
#include "camera_fix.h"
#include "lighting_fix.h"
#include "config.h"
#include "crash_probe.h"
#include "log.h"
#include "lua_bridge.h"
#include "lua_worker.h"
#include "mod_converter.h"
#include "occlusion.h"
#include "overlay.h"
#include "placement.h"
#include "plan_view.h"
#include "profiler.h"
#include "boards.h"
#include "road_labels.h"
#include "shadow_tuning.h"
#include "vkstats.h"

#include <windows.h>

#include <filesystem>
#include <iterator>
#include <string>

#include "MinHook.h"

namespace {

bool g_minHookReady = false;

DWORD WINAPI InitThread(LPVOID) {
    TF3_LOG("tf3api native loaded");
    tf3api::crash_probe::Install();
    MH_STATUS mh = MH_Initialize();
    g_minHookReady = (mh == MH_OK || mh == MH_ERROR_ALREADY_INITIALIZED);
    if (g_minHookReady) {
        tf3api::alloc_profiler::Install();
        tf3api::occlusion::Install();
        tf3api::vkstats::Install();
        tf3api::overlay::Install();
        tf3api::road_labels::Install();
        tf3api::boards::Install();
        tf3api::placement::Install();
        tf3api::plan_view::Install();
        tf3api::shadow_tuning::Install();
        tf3api::lua_bridge::Install();
        tf3api::lua_worker::Install();   // after the bridge: the worker's state gets the tf3api table through its hook
    } else {
        TF3_LOG("MinHook init failed (%d) - allocation profiler and occlusion culling unavailable",
                static_cast<int>(mh));
    }
    tf3api::camera_fix::Install();
    tf3api::lighting_fix::Install();
    tf3api::profiler::Install();
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    switch (reason) {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(module);
        tf3api::log::Init();
        // Old mods in legacy_mods are converted here, before the game's own start-up code lists its mods, so
        // that they are in the mod list in this launch. Files only: no threads, no library loads.
        if (tf3api::config::GetBool("Converter", "Enabled", false)) {
            wchar_t exe[MAX_PATH * 4] = {};
            DWORD length = GetModuleFileNameW(nullptr, exe, static_cast<DWORD>(std::size(exe)));
            if (length > 0 && length < std::size(exe)) {
                tf3api::mod_converter::Run(std::filesystem::path(exe).parent_path(),
                                           [](const std::string& text) { TF3_LOG("%s", text.c_str()); },
                                           tf3api::config::GetBool("Converter", "Stations", false),
                                           tf3api::config::GetBool("Converter", "StationDebug", false),
                                           tf3api::config::GetBool("Converter", "Remasters", true),
                                           tf3api::config::GetBool("Converter", "GlassParts", false),
                                           tf3api::config::GetBool("Converter", "PackTextures", false));
            }
        }
        // The main module is fully mapped by the time this proxy loads, so patching from a worker
        // thread (off the loader lock) is safe.
        if (HANDLE thread = CreateThread(nullptr, 0, InitThread, nullptr, 0, nullptr)) CloseHandle(thread);
        break;
    case DLL_PROCESS_DETACH:
        tf3api::profiler::Uninstall();
        tf3api::plan_view::Uninstall();
        tf3api::placement::Uninstall();
        tf3api::boards::Uninstall();
        tf3api::road_labels::Uninstall();
        tf3api::overlay::Uninstall();
        tf3api::vkstats::Uninstall();
        tf3api::shadow_tuning::Uninstall();
        tf3api::lua_worker::Uninstall();
        tf3api::lua_bridge::Uninstall();
        tf3api::occlusion::Uninstall();
        tf3api::camera_fix::Uninstall();
        tf3api::lighting_fix::Uninstall();
        tf3api::crash_probe::Uninstall();
        tf3api::alloc_profiler::Uninstall();
        if (g_minHookReady) MH_Uninitialize();
        tf3api::log::Shutdown();
        break;
    }
    return TRUE;
}
