#include "splash.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <string>

#include "MinHook.h"

namespace tf3api::splash {
namespace {

constexpr int kSize = 512;
const uint8_t kLogo[] = {
#include "splash_logo.inc"
};
static_assert(sizeof(kLogo) == kSize * kSize * 4, "the logo is 512 x 512 RGBA");

// AddPicture(list, std::string* path, int64 microseconds): 0x1406bff50
using AddFn = void (*)(void* list, std::string* path, int64_t micros);
// ImageView constructor (this, resource, ...): 0x1427664a0; returns this
using CtorFn = void* (*)(void* self, void* a2, int a3, uint8_t a4, int a5, void* a6, int a7);
// ImageView::SetImage(view, channels, width, height, const uint8_t* const* data, redraw): 0x142767a40
using SetImageFn = void (*)(void* view, int channels, int width, int height, const uint8_t* const* data, char redraw);

AddFn g_originalAdd = nullptr;
CtorFn g_originalCtor = nullptr;
SetImageFn g_setImage = nullptr;
void* g_targetAdd = nullptr;
void* g_targetCtor = nullptr;
thread_local bool t_ours = false;
std::atomic<bool> g_added{false};
std::atomic<bool> g_painted{false};
int64_t g_micros = 2000000;
int64_t g_fadeMicros = 700000;
bool g_swap = false;

const uint8_t* g_data = nullptr;
uint8_t g_swapped[sizeof(kLogo)];

void* HookCtor(void* self, void* a2, int a3, uint8_t a4, int a5, void* a6, int a7) {
    void* result = g_originalCtor(self, a2, a3, a4, a5, a6, a7);
    if (t_ours && result != nullptr && g_setImage != nullptr) {
        t_ours = false;   // only the first image view made inside our call
        __try {
            g_setImage(result, 4, kSize, kSize, &g_data, 1);
            g_painted.store(true);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            TF3_LOG("splash: the logo could not be put into the picture");
        }
    }
    return result;
}

void HookAdd(void* list, std::string* path, int64_t micros) {
    // the ending entry has an empty path and a time of one microsecond
    if (!g_added.load() && path != nullptr && path->empty() && micros == 1) {
        g_added.store(true);
        static std::string stand("gui/application/paradox_interactive_logo.tga");   // any picture the game has: its pixels are replaced
        t_ours = true;
        g_originalAdd(list, &stand, g_micros);
        t_ours = false;
        // a blank entry after it: the game fades a picture out when the next entry takes over, and the ending entry
        // (one microsecond) would close the splash at once, cutting the fade
        static std::string blank;
        g_originalAdd(list, &blank, g_fadeMicros);
        TF3_LOG("splash: our logo added after the Paradox logo (%s)", g_painted.load() ? "painted" : "NOT painted");
    }
    g_originalAdd(list, path, micros);
}

bool Hook(const char* name, const char* pattern, void* detour, void** original, void** target) {
    *target = reinterpret_cast<void*>(sigscan::FindUnique(name, pattern));
    if (*target == nullptr) {
        TF3_LOG("splash: %s was not found - no logo on the splash screen", name);
        return false;
    }
    MH_STATUS status = MH_CreateHook(*target, detour, original);
    if (status == MH_OK) status = MH_EnableHook(*target);
    if (status != MH_OK) {
        TF3_LOG("splash: the hook for %s could not be installed (%s)", name, MH_StatusToString(status));
        *target = nullptr;
        return false;
    }
    return true;
}

} // namespace

void Install() {
    if (!config::GetBool("Splash", "Enabled", true)) return;
    g_swap = config::GetBool("Splash", "SwapRB", false);
    g_micros = static_cast<int64_t>(config::GetFloat("Splash", "Seconds", 2.0f) * 1000000.0f);
    if (g_micros < 500000) g_micros = 500000;
    g_fadeMicros = static_cast<int64_t>(config::GetFloat("Splash", "FadeSeconds", 0.7f) * 1000000.0f);
    if (g_fadeMicros < 2) g_fadeMicros = 2;
    g_data = kLogo;
    if (g_swap) {
        for (size_t i = 0; i < sizeof(kLogo); i += 4) {
            g_swapped[i] = kLogo[i + 2];
            g_swapped[i + 1] = kLogo[i + 1];
            g_swapped[i + 2] = kLogo[i];
            g_swapped[i + 3] = kLogo[i + 3];
        }
        g_data = g_swapped;
    }
    const uintptr_t setImage = sigscan::FindUnique("image view SetImage",
        "40 55 53 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 18 FF FF FF 48 81 EC E8 01 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 D0 00 00 00 45 8B E9 45 8B E0 44 8B FA");
    if (setImage == 0) {
        TF3_LOG("splash: SetImage was not found - no logo on the splash screen");
        return;
    }
    g_setImage = reinterpret_cast<SetImageFn>(setImage);
    const bool ctor = Hook("image view constructor",
        "48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 48 89 48 08 41 56 48 83 EC 50 41 0F B6 D9 41 8B F8 48 8B F2 4C 8B F1 C5 F9 EF C0 C5 F8 11 40 D0 48 C7 40 E0",
        reinterpret_cast<void*>(&HookCtor), reinterpret_cast<void**>(&g_originalCtor), &g_targetCtor);
    const bool add = ctor && Hook("splash picture list",
        "48 89 5C 24 18 55 56 57 41 56 41 57 48 8D 6C 24 E0 48 81 EC 20 01 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 10 4D 8B F0 48 8B F2 4C 8B F9 33 DB B9 28 03 00 00",
        reinterpret_cast<void*>(&HookAdd), reinterpret_cast<void**>(&g_originalAdd), &g_targetAdd);
    if (!add) {
        Uninstall();
        return;
    }
    TF3_LOG("splash: ready - the logo is shown after the Paradox logo for %.1f s", g_micros / 1000000.0);
}

void Uninstall() {
    if (g_targetAdd != nullptr) MH_DisableHook(g_targetAdd);
    if (g_targetCtor != nullptr) MH_DisableHook(g_targetCtor);
    g_targetAdd = nullptr;
    g_targetCtor = nullptr;
}

} // namespace tf3api::splash
