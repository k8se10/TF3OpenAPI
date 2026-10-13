#include "placement.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "MinHook.h"

namespace tf3api::placement {
namespace {

// The mouse handler of UI::ConstructionBuilder (build 40420: 0x14051bb50):
//     handler(this, sender, event)
//         event + 0x08  kind: 0 a button went down, 1 a button came up, 5 the mouse moved
//         event + 0x18  which button, on a press (0 = left)
//         event + 0x1c  how far the mouse moved sideways, on a move (points)
//     press, left          -> MousePressed: builds, or with Shift held starts the game's own drag-to-turn
//     release              -> ends that drag
//     move                 -> the object follows the mouse; while dragging, rotation += dx * pi / 1000 and
//                             the "rotation changed" callback is called
// Found by its opening; the jumps' distances are left open.
const char kPattern[] =
    "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 48 8B FA 41 8B 48 08 85 C9 0F 84 ?? ?? ?? ?? 83 E9 01 0F 84 ?? ?? ?? ?? 83 F9 04 0F 85";

// Places in the tool (build 40420). Each is checked to appear in the handler's own code before the hook is
// installed, so that a build that moved them leaves the feature off instead of writing somewhere else.
constexpr uint32_t kRotation = 0xb90;       // float, radians
constexpr uint32_t kDragging = 0xb9d;       // byte: the game's own drag-to-turn is on
constexpr uint32_t kRotationChanged = 0xca8;   // callback object: (*object->vtable[2])(object, &rotation)
constexpr uint32_t kState = 0xbc0;          // int: 4 = what is under the mouse can be built
constexpr uint32_t kRedraw = 0xc68;         // object the game pokes after a turn: redraw(*(object + 0x10))
// Calls inside the handler, found by their place in it (each checked to be a call before use):
constexpr size_t kCallSetState = 0x38;      // SetState(tool, 1): "work the preview out again"
constexpr size_t kCallRedraw = 0x9e;

constexpr float kStep = 0.17453293f;        // 10 degrees, the step of the game's rotation setting
constexpr int kPointsPerStep = 16;          // mouse movement for one step
constexpr int kClickSlack = 4;              // a right press that moved less than this is a click

using Handler = uint64_t (*)(void* self, void* sender, void* event);
using SetStateFn = void (*)(void* self, int state);
using RedrawFn = void (*)(void* object);
Handler g_original = nullptr;
SetStateFn g_setState = nullptr;   // the game's own; null: not found (the turn then relies on the callback alone)
RedrawFn g_redraw = nullptr;
int g_toldEvents = 0, g_toldTurns = 0;   // a few log lines per session, to see what arrives
void* g_target = nullptr;
bool g_installed = false;

std::atomic<bool> g_gameOption{false};
// The handler runs on the game's interface thread only; these are its own.
void* g_pinned = nullptr;     // the tool whose object is pinned
bool g_rightDown = false;
int g_rightMoved = 0;         // points moved while the right button is down
int g_carry = 0;              // movement not yet turned into a step

bool Active() { return g_gameOption.load(std::memory_order_relaxed); }

void Turn(void* self, int steps) {
    auto* base = static_cast<uint8_t*>(self);
    float rotation;
    std::memcpy(&rotation, base + kRotation, sizeof(rotation));
    if (!std::isfinite(rotation)) return;
    // on the grid of 10 degrees, whatever it was before
    rotation = std::round(rotation / kStep) * kStep + static_cast<float>(steps) * kStep;
    // as the game's own drag-to-turn does it: mark the preview to be worked out again, write the angle, tell
    // the bottom bar, poke the redraw
    if (g_setState != nullptr) g_setState(self, 1);
    std::memcpy(base + kRotation, &rotation, sizeof(rotation));
    void* callback = nullptr;
    std::memcpy(&callback, base + kRotationChanged, sizeof(callback));
    if (callback != nullptr) {
        using Call = void (*)(void* object, float* value);
        void** vtable = *static_cast<void***>(callback);
        reinterpret_cast<Call>(vtable[2])(callback, &rotation);
    }
    void* redraw = nullptr;
    std::memcpy(&redraw, base + kRedraw, sizeof(redraw));
    if (redraw != nullptr && g_redraw != nullptr) {
        void* target = nullptr;
        std::memcpy(&target, static_cast<uint8_t*>(redraw) + 0x10, sizeof(target));
        g_redraw(target);
    }
    if (g_toldTurns < 4) {
        ++g_toldTurns;
        TF3_LOG("placement: turned by %d step(s) to %.1f degrees (callback %s, set-state %s)", steps, rotation * 57.29578f,
                callback != nullptr ? "called" : "none", g_setState != nullptr ? "called" : "not found");
    }
}

uint64_t Hook(void* self, void* sender, void* event) {
    if (!Active() || self == nullptr || event == nullptr) {
        g_pinned = nullptr;
        return g_original(self, sender, event);
    }
    const auto* e = static_cast<const uint8_t*>(event);
    int kind, button, dx;
    std::memcpy(&kind, e + 0x08, sizeof(kind));
    std::memcpy(&button, e + 0x18, sizeof(button));
    std::memcpy(&dx, e + 0x1c, sizeof(dx));
    if (g_pinned != nullptr && g_pinned != self) {   // another tool: what was pinned is gone
        g_pinned = nullptr;
        g_rightDown = false;
    }
    static bool told = false;
    if (g_pinned == self && g_toldEvents < 16 && (kind != 5 || g_toldEvents < 4)) {
        ++g_toldEvents;
        TF3_LOG("placement: while pinned - event kind %d, button %d, dx %d, right button %s", kind, button, dx,
                (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0 ? "down" : "up");
    }

    if (kind == 0) {
        if (button == 0) {
            if (g_pinned == self) {
                // the second click: build, with the tool's own click
                g_pinned = nullptr;
                g_rightDown = false;
                return g_original(self, sender, event);
            }
            int state;
            std::memcpy(&state, static_cast<uint8_t*>(self) + kState, sizeof(state));
            if (state != 4) return g_original(self, sender, event);   // nothing buildable there: the game says why
            g_pinned = self;
            g_rightDown = false;
            if (!told) {
                told = true;
                TF3_LOG("placement: an object was pinned by the first click (a second click builds it, right-drag turns it, a right click lets go)");
            }
            return 1;
        }
        if (g_pinned == self) {   // another button while pinned: the start of a turn, or of a click that lets go
            g_rightDown = true;
            g_rightMoved = 0;
            g_carry = 0;
            return 1;
        }
        return g_original(self, sender, event);
    }
    if (kind == 1) {
        if (g_pinned == self && g_rightDown) {
            g_rightDown = false;
            if (g_rightMoved < kClickSlack) g_pinned = nullptr;   // a right click: let go of it
            return 1;
        }
        return g_original(self, sender, event);
    }
    if (kind == 5 && g_pinned == self) {
        // The right button's own press may never come here (the game hands it to its "back" action), so its
        // state is also read directly while the mouse moves.
        const bool held = (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
        if (held && !g_rightDown) {
            g_rightDown = true;
            g_rightMoved = 0;
            g_carry = 0;
        } else if (!held && g_rightDown) {
            g_rightDown = false;
            if (g_rightMoved < kClickSlack) {   // a right click: let go of it
                g_pinned = nullptr;
                return g_original(self, sender, event);
            }
        }
        if (g_rightDown) {
            g_rightMoved += dx < 0 ? -dx : dx;
            g_carry += dx;
            const int steps = g_carry / kPointsPerStep;
            if (steps != 0) {
                g_carry -= steps * kPointsPerStep;
                Turn(self, steps);
            }
        }
        return 1;   // pinned: it does not follow the mouse
    }
    return g_original(self, sender, event);
}

// whether the four bytes of a place in the tool appear in the handler's code
bool HandlerUses(uintptr_t handler, uint32_t place) {
    const auto* code = reinterpret_cast<const uint8_t*>(handler);
    for (size_t i = 0; i + 4 <= 0x130; ++i) {
        if (std::memcmp(code + i, &place, 4) == 0) return true;
    }
    return false;
}

} // namespace

void SetGameOption(bool on) {
    const bool was = g_gameOption.exchange(on, std::memory_order_relaxed);
    if (was != on && g_installed) {
        TF3_LOG("placement: the game's drag-and-confirm option is %s - objects are %s", on ? "on" : "off",
                on ? "placed in two steps" : "built at the click, as the game ships");
    }
}

int State() {
    if (!g_installed || !Active()) return 0;
    return g_pinned != nullptr ? 2 : 1;
}

void Install() {
    if (!config::GetBool("Placement", "ConfirmObjects", false)) {
        TF3_LOG("placement: off ([Placement] ConfirmObjects=0, the default until it has been seen working)");
        return;
    }
    const uintptr_t handler = sigscan::FindUnique("object placement tool: mouse handler", kPattern);
    if (handler == 0) {
        TF3_LOG("placement: the object tool's mouse handler was not found on this build - objects are built at the click, as the game ships");
        return;
    }
    if (!HandlerUses(handler, kRotation) || !HandlerUses(handler, kDragging) || !HandlerUses(handler, kRotationChanged)) {
        TF3_LOG("placement: the object tool is laid out differently on this build - left alone");
        return;
    }
    // the game's own helpers, from the calls in the handler
    const auto* code = reinterpret_cast<const uint8_t*>(handler);
    const auto callTarget = [&](size_t at) -> uintptr_t {
        if (code[at] != 0xE8) return 0;
        int32_t distance;
        std::memcpy(&distance, code + at + 1, sizeof(distance));
        return handler + at + 5 + static_cast<intptr_t>(distance);
    };
    g_setState = reinterpret_cast<SetStateFn>(callTarget(kCallSetState));
    g_redraw = HandlerUses(handler, kRedraw) ? reinterpret_cast<RedrawFn>(callTarget(kCallRedraw)) : nullptr;
    g_target = reinterpret_cast<void*>(handler);
    MH_STATUS status = MH_CreateHook(g_target, reinterpret_cast<void*>(&Hook), reinterpret_cast<void**>(&g_original));
    if (status == MH_OK) status = MH_EnableHook(g_target);
    if (status != MH_OK) {
        TF3_LOG("placement: the hook could not be installed (%s)", MH_StatusToString(status));
        g_target = nullptr;
        return;
    }
    g_installed = true;
    TF3_LOG("placement: ready at +0x%llx (set-state %s, redraw %s); waiting for a script to say whether the game's drag-and-confirm option is on",
            static_cast<unsigned long long>(handler - reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr))),
            g_setState != nullptr ? "found" : "not found", g_redraw != nullptr ? "found" : "not found");
}

void Uninstall() {
    if (!g_installed) return;
    MH_DisableHook(g_target);
    g_installed = false;
}

} // namespace tf3api::placement
