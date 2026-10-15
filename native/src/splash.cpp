#include "splash.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

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
// The splash's step (0x1406c06b0): step(closure, ?, int64* microseconds since the last call). The closure holds a
// pointer to the number of the current entry (+0x88) and one to the microseconds spent on it so far (+0x98).
using StepFn = void (*)(void* closure, void* a2, int64_t* dt);

AddFn g_originalAdd = nullptr;
CtorFn g_originalCtor = nullptr;
StepFn g_originalStep = nullptr;
SetImageFn g_setImage = nullptr;
void* g_targetAdd = nullptr;
void* g_targetCtor = nullptr;
void* g_targetStep = nullptr;
thread_local bool t_ours = false;
std::atomic<bool> g_added{false};
std::atomic<bool> g_painted{false};
bool g_swap = false;

const uint8_t* g_data = nullptr;
uint8_t g_swapped[sizeof(kLogo)];

// The game only shows or hides a splash picture, so the fade and the zoom are done here, on every step of the
// splash: the logo sits on a square canvas (512 across at 100 %, 640 at 125 %); the zoom is the part of the canvas
// the picture shows (its texture coordinates, floats at +0x4d0 of the image view: u0, v0, u1, v1), the fade is the
// strength of the pixels, written again each step.
constexpr int kCanvas = 640;
constexpr size_t kBytes = static_cast<size_t>(kCanvas) * kCanvas * 4;
constexpr int kRing = 3;               // the game may still be reading the last pixels we gave it
std::vector<uint8_t> g_canvas;         // the logo at full strength on the canvas
std::vector<uint8_t> g_ring[kRing];
const uint8_t* g_pointer = nullptr;    // what SetImage is given a pointer to
int g_ringAt = 0;
float g_zoomSeconds = 1.0f, g_zoomPercent = 25.0f, g_fadeSeconds = 0.7f, g_holdSeconds = 1.0f;
void* g_view = nullptr;                // the image view of our entry
int g_ourIndex = -1;                   // the number of our entry in the list
int g_addCount = 0;
bool g_done = false;

void MakeCanvas() {
    g_canvas.assign(kBytes, 0);
    const int margin = (kCanvas - kSize) / 2;
    for (int y = 0; y < kSize; ++y) {
        std::memcpy(g_canvas.data() + (static_cast<size_t>(y + margin) * kCanvas + margin) * 4, g_data + static_cast<size_t>(y) * kSize * 4,
                    static_cast<size_t>(kSize) * 4);
    }
    for (auto& r : g_ring) r.assign(kBytes, 0);
}

float Smooth(float x) { return x <= 0.0f ? 0.0f : x >= 1.0f ? 1.0f : x * x * (3.0f - 2.0f * x); }

// strength (0..1) and zoom (1..top) at `t` seconds into our entry
void Pose(float t, float* strength, float* zoom) {
    const float top = 1.0f + g_zoomPercent / 100.0f;
    const float total = g_zoomSeconds + g_holdSeconds + g_fadeSeconds;
    const float outStart = total - g_fadeSeconds;
    if (t < g_zoomSeconds) {
        *zoom = 1.0f + (top - 1.0f) * Smooth(t / g_zoomSeconds);
    } else if (t < outStart) {
        *zoom = top;
    } else {
        *zoom = top - (top - 1.0f) * Smooth((t - outStart) / g_fadeSeconds);
    }
    float s = 1.0f;
    if (t < g_fadeSeconds) s = Smooth(t / g_fadeSeconds);
    if (t > outStart) s = 1.0f - Smooth((t - outStart) / g_fadeSeconds);
    *strength = s;
}

// writes the picture of the moment into the image view
void Update(float t) {
    if (g_view == nullptr || g_setImage == nullptr) return;
    float strength, zoom;
    Pose(t, &strength, &zoom);
    std::vector<uint8_t>& out = g_ring[g_ringAt];
    g_ringAt = (g_ringAt + 1) % kRing;
    const unsigned scale = static_cast<unsigned>(strength * 256.0f + 0.5f);
    const uint8_t* in = g_canvas.data();
    uint8_t* o = out.data();
    for (size_t i = 0; i < kBytes; i += 4) {
        const unsigned a = in[i + 3];
        if (a == 0) {
            o[i] = o[i + 1] = o[i + 2] = o[i + 3] = 0;
            continue;
        }
        o[i] = static_cast<uint8_t>((in[i] * scale) >> 8);
        o[i + 1] = static_cast<uint8_t>((in[i + 1] * scale) >> 8);
        o[i + 2] = static_cast<uint8_t>((in[i + 2] * scale) >> 8);
        o[i + 3] = static_cast<uint8_t>((a * scale) >> 8);
    }
    g_pointer = o;
    // the picture shows a window of the canvas: at zoom 1 all of it (the logo is 80 % of it), at 1.25 the middle 80 %
    const float half = 0.5f / zoom;
    float* uv = reinterpret_cast<float*>(static_cast<uint8_t*>(g_view) + 0x4d0);
    uv[0] = 0.5f - half;
    uv[1] = 0.5f - half;
    uv[2] = 0.5f + half;
    uv[3] = 0.5f + half;
    g_setImage(g_view, 4, kCanvas, kCanvas, &g_pointer, 1);
}

void* HookCtor(void* self, void* a2, int a3, uint8_t a4, int a5, void* a6, int a7) {
    void* result = g_originalCtor(self, a2, a3, a4, a5, a6, a7);
    if (t_ours && result != nullptr && g_setImage != nullptr) {
        t_ours = false;   // only the first image view made inside our call
        __try {
            g_view = result;
            Update(0.0f);
            g_painted.store(true);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            g_view = nullptr;
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
        g_ourIndex = g_addCount;
        const int64_t total = static_cast<int64_t>((g_zoomSeconds + g_holdSeconds + g_fadeSeconds) * 1000000.0f);
        t_ours = true;
        g_originalAdd(list, &stand, total);
        t_ours = false;
        ++g_addCount;
        static std::string blank;   // a short blank entry: the ending entry (one microsecond) would close the splash at once
        g_originalAdd(list, &blank, 150000);
        ++g_addCount;
        TF3_LOG("splash: our logo added after the Paradox logo as entry %d, %.1f s (%s)", g_ourIndex, total / 1000000.0, g_painted.load() ? "painted" : "NOT painted");
    }
    ++g_addCount;
    g_originalAdd(list, path, micros);
}

void HookStep(void* closure, void* a2, int64_t* dt) {
    if (g_view != nullptr && !g_done) {
        __try {
            const int index = **reinterpret_cast<int**>(static_cast<uint8_t*>(closure) + 0x88);
            const int64_t spent = **reinterpret_cast<int64_t**>(static_cast<uint8_t*>(closure) + 0x98);
            if (index == g_ourIndex) {
                Update(static_cast<float>(spent + (dt != nullptr ? *dt : 0)) / 1000000.0f);
            } else if (index > g_ourIndex) {
                g_done = true;
                g_view = nullptr;   // the splash has moved on; the view is not touched again
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            g_done = true;
            g_view = nullptr;
            TF3_LOG("splash: the animation of the logo stopped (the splash's layout is not what was expected)");
        }
    }
    g_originalStep(closure, a2, dt);
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
    g_holdSeconds = config::GetFloat("Splash", "Seconds", 1.0f);   // how long it stays after the zoom, before it fades
    g_zoomSeconds = config::GetFloat("Splash", "ZoomSeconds", 1.0f);
    g_zoomPercent = config::GetFloat("Splash", "ZoomPercent", 25.0f);
    g_fadeSeconds = config::GetFloat("Splash", "FadeSeconds", 0.7f);
    if (g_holdSeconds < 0.1f) g_holdSeconds = 0.1f;
    if (g_zoomSeconds < 0.2f) g_zoomSeconds = 0.2f;
    if (g_zoomPercent < 0.0f) g_zoomPercent = 0.0f;
    if (g_zoomPercent > 25.0f) g_zoomPercent = 25.0f;   // the canvas holds 125 %
    if (g_fadeSeconds < 0.2f) g_fadeSeconds = 0.2f;
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
    MakeCanvas();
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
    const bool step = add && Hook("splash step",
        "40 53 48 83 EC 20 48 8D 59 08 48 8B 8B A8 00 00 00 48 2B 8B A0 00 00 00 48 8B 83 80 00 00 00 48 C1 F9 04 39 08 0F 8D B1 00 00 00",
        reinterpret_cast<void*>(&HookStep), reinterpret_cast<void**>(&g_originalStep), &g_targetStep);
    if (!step) {
        Uninstall();
        return;
    }
    TF3_LOG("splash: ready - the logo is shown after the Paradox logo");
}

void Uninstall() {
    if (g_targetAdd != nullptr) MH_DisableHook(g_targetAdd);
    if (g_targetCtor != nullptr) MH_DisableHook(g_targetCtor);
    if (g_targetStep != nullptr) MH_DisableHook(g_targetStep);
    g_targetAdd = nullptr;
    g_targetCtor = nullptr;
    g_targetStep = nullptr;
}

} // namespace tf3api::splash
