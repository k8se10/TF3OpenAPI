#include "shadow_tuning.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <cstdint>

#include "MinHook.h"

namespace tf3opt::shadow_tuning {
namespace {

// ShadowMap sizing / render-target (re)creation, build 40408 at +0xe0840. `this` layout used here:
//   +0x0C int   maximum edge length, applied only when > 0 (the field this module sets)
//   +0x20 int   viewport width      +0x24 int viewport height
//   +0x28 float shadow-quality scale factor
//   +0xA0 int   current shadow map width   +0xA4 int current height
constexpr const char* kSigResize =
    "48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55 41 54 41 55 41 56 41 57 48 8D AC 24 B0 FE FF FF 48 81 EC 50 02 00 00 "
    "48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 48 01 00 00 4C 8B E1 45 33 FF 44 8B 59 24 45 8D 47 40 8B 41 20 8D 04 40 99 2B "
    "C2 D1 F8";

constexpr size_t kOffMaxSize = 0x0C;
constexpr size_t kOffViewW = 0x20, kOffViewH = 0x24, kOffScale = 0x28;
constexpr size_t kOffCurW = 0xA0, kOffCurH = 0xA4;

// The return value (if any) is passed through untouched.
using ResizeFn = uintptr_t (*)(void* self);
ResizeFn g_original = nullptr;
void* g_target = nullptr;

int g_maxResolution = 0;
int g_toggleKey = 0;
std::atomic<bool> g_enabled{true};
bool g_keyWasDown = false;

// What the game itself last had in the maximum-size field, and what this module last wrote there, so the
// vanilla value can be put back when the limit is switched off.
int g_engineMax = 0;
int g_lastWritten = -1;
// Last size logged per shadow map object (the main view and e.g. a vehicle-window preview each have one),
// so two live objects of different sizes do not log on every frame.
struct Logged {
    void* self;
    int w, h;
};
Logged g_logged[8] = {};
int g_loggedNext = 0;

template <typename T>
T& Field(void* self, size_t offset) {
    return *reinterpret_cast<T*>(static_cast<uint8_t*>(self) + offset);
}

bool GameFocused() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

void PollToggleKey() {
    if (g_toggleKey <= 0) return;
    const bool down = (GetAsyncKeyState(g_toggleKey) & 0x8000) != 0;
    if (down && !g_keyWasDown && GameFocused()) {
        const bool now = !g_enabled.load(std::memory_order_relaxed);
        g_enabled.store(now, std::memory_order_relaxed);
        TF3_LOG("shadows: resolution limit %s", now ? "ON" : "OFF (vanilla size)");
    }
    g_keyWasDown = down;
}

// Applies the limit to one shadow map object. Separate from the hook so the pointer accesses can be
// guarded: a wrong `this` must never take the game down.
void Apply(void* self) {
    __try {
        int& maxSize = Field<int>(self, kOffMaxSize);
        if (maxSize != g_lastWritten) g_engineMax = maxSize;  // the game (or nobody) wrote it: remember
        int wanted = g_engineMax;
        if (g_enabled.load(std::memory_order_relaxed)) {
            wanted = (g_engineMax > 0 && g_engineMax < g_maxResolution) ? g_engineMax : g_maxResolution;
        }
        maxSize = wanted;
        g_lastWritten = wanted;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
}

void LogResult(void* self) {
    __try {
        const int w = Field<int>(self, kOffCurW), h = Field<int>(self, kOffCurH);
        Logged* entry = nullptr;
        for (Logged& l : g_logged) {
            if (l.self == self) entry = &l;
        }
        if (entry == nullptr) {
            entry = &g_logged[g_loggedNext];
            g_loggedNext = (g_loggedNext + 1) % 8;
            *entry = {self, -1, -1};
        }
        if (w == entry->w && h == entry->h) return;  // only when this object's size actually changes
        entry->w = w;
        entry->h = h;
        TF3_LOG("shadows: shadow maps are now %dx%d (viewport %dx%d, quality factor %.2f, limit %s)", w, h,
                Field<int>(self, kOffViewW), Field<int>(self, kOffViewH), static_cast<double>(Field<float>(self, kOffScale)),
                g_enabled.load(std::memory_order_relaxed) ? "on" : "off");
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
}

uintptr_t HookResize(void* self) {
    if (self != nullptr) {
        PollToggleKey();
        Apply(self);
    }
    const uintptr_t result = g_original(self);
    if (self != nullptr) LogResult(self);
    return result;
}

} // namespace

void Install() {
    g_maxResolution = config::GetInt("Shadows", "MaxResolution", 0);
    g_toggleKey = config::GetInt("Shadows", "ToggleKey", 0);
    if (g_maxResolution <= 0) {
        TF3_LOG("shadows: no resolution limit set ([Shadows] MaxResolution=0) - vanilla shadow maps");
        return;
    }
    if (g_maxResolution < 128 || g_maxResolution > 4096) {
        TF3_LOG("shadows: MaxResolution=%d is outside 128..4096 - ignored, vanilla shadow maps", g_maxResolution);
        return;
    }
    const uintptr_t address = sigscan::FindUnique("ShadowMap sizing", kSigResize);
    if (address == 0) return;  // FindUnique logged it
    g_target = reinterpret_cast<void*>(address);
    MH_STATUS status =
        MH_CreateHook(g_target, reinterpret_cast<void*>(&HookResize), reinterpret_cast<void**>(&g_original));
    if (status == MH_OK) status = MH_EnableHook(g_target);
    if (status != MH_OK) {
        TF3_LOG("shadows: hook install failed (%d) - vanilla shadow maps", static_cast<int>(status));
        g_target = nullptr;
        return;
    }
    TF3_LOG("shadows: shadow map resolution limited to %d (toggle key %d)", g_maxResolution, g_toggleKey);
}

void Uninstall() {
    if (g_target == nullptr) return;
    MH_DisableHook(g_target);
    g_target = nullptr;
}

} // namespace tf3opt::shadow_tuning
