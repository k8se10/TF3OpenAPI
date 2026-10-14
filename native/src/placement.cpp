#include "placement.h"

#include "lua_bridge.h"

#include "road_labels.h"

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
//         event + 0x08  kind: 0 the left button went down, 1 a button came up, 2 a click, 5 the mouse moved
//                       with no button held, 4 the mouse moved with a button held (a drag), 8 another button
//                       went down (seen with button 2 for the right one)
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
constexpr uint32_t kBuilding = 0xcd0;       // byte: set by the click handler when it starts building
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
int g_toldEvents = 0, g_toldTurns = 0, g_toldNotBuilt = 0;   // a few log lines per session, to see what arrives
void* g_target = nullptr;
bool g_installed = false;

std::atomic<bool> g_gameOption{false};
// The handler runs on the game's interface thread only; these are its own.
std::atomic<void*> g_pinned{nullptr};   // the tool whose object is pinned
bool g_rightDown = false;
int g_rightMoved = 0;         // points moved while the right button is down
int g_carry = 0;              // movement not yet turned into a step

bool Active() { return g_gameOption.load(std::memory_order_relaxed); }

// ---- When the pinned tool goes away ---------------------------------------------------------------------------
// The tool is a UI::BasicAction. When the player closes it (Esc, another tool, a save loaded) the game calls its
// Deactivate and later destroys it; neither goes through the mouse handler, so before this the pinned pointer
// outlived the tool: the right button stayed taken from the game (it did nothing in play afterwards) and a right
// drag turned freed memory (a crash after loading a save, 2026-10-14). Both are hooked, found from the live
// tool's own table of functions at the first pin (build 40420: slot 0 = its deleting destructor 0x140516170,
// slot 6 = UI::BasicAction::Deactivate 0x1404b1a70, which every action shares - the hooks compare the object).
void* g_pinnedTable = nullptr;          // the pinned tool's table of functions, checked before every turn
std::atomic<bool> g_filterRightDown{false};
std::atomic<bool> g_middleDown{false};

void LetGo(const char* why) {
    if (g_pinned.exchange(nullptr, std::memory_order_relaxed) == nullptr) return;
    g_rightDown = false;
    static int told = 0;
    if (told < 6) {
        ++told;
        TF3_LOG("placement: the pinned object was let go (%s)", why);
    }
}

// whether the pinned tool is still the one that was pinned (the same table of functions in its first bytes)
bool PinnedLooksAlive(void* tool) {
    if (tool == nullptr || g_pinnedTable == nullptr) return false;
    void* table = nullptr;
    std::memcpy(&table, tool, sizeof(table));
    return table == g_pinnedTable;
}

using DeactivateFn = void (*)(void* self, void* arg);
using DestroyFn = void* (*)(void* self, uint64_t flags);
DeactivateFn g_deactivate = nullptr;
DestroyFn g_destroy = nullptr;
bool g_lifeHooked = false;

void HookDeactivate(void* self, void* arg) {
    if (self != nullptr && self == g_pinned.load(std::memory_order_relaxed)) LetGo("the tool was closed");
    g_deactivate(self, arg);
}

void* HookDestroy(void* self, uint64_t flags) {
    if (self != nullptr && self == g_pinned.load(std::memory_order_relaxed)) LetGo("the tool was destroyed");
    return g_destroy(self, flags);
}

bool InExe(const void* code) {
    const auto base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    const auto at = reinterpret_cast<uintptr_t>(code);
    return at > base && at < base + nt->OptionalHeader.SizeOfImage;
}

// Hooks the tool's Deactivate and destructor, once, from its table. False: not possible, and then nothing is
// pinned (a pin that cannot be undone safely is worse than none).
bool EnsureLifeHooks(void* self) {
    if (g_lifeHooked) return true;
    void** table = nullptr;
    std::memcpy(&table, self, sizeof(table));
    static bool tried = false;
    if (tried) return false;
    tried = true;
    if (table == nullptr || !InExe(table) || !InExe(table[0]) || !InExe(table[6])) {
        TF3_LOG("placement: the tool's table of functions is not where expected - objects are not pinned");
        return false;
    }
    // Deactivate clears the action's renderer link (its fourth pointer) and must call slot 0x80 of the table:
    // check its code for "mov qword ptr [rcx/rbx/rdi + 0x18], 0" in some form - the 0x18 displacement at least
    const auto* code = static_cast<const uint8_t*>(table[6]);
    bool clears = false;
    for (int i = 0; i + 8 < 0x180; ++i) {
        if ((code[i] == 0x48 || code[i] == 0x4C || code[i] == 0x49) && (code[i + 1] == 0xC7 || code[i + 1] == 0x89 || code[i + 1] == 0x21) && code[i + 3] == 0x18) {
            clears = true;
            break;
        }
    }
    if (!clears) {
        TF3_LOG("placement: the tool's Deactivate does not look as expected on this build - objects are not pinned");
        return false;
    }
    MH_STATUS a = MH_CreateHook(table[6], reinterpret_cast<void*>(&HookDeactivate), reinterpret_cast<void**>(&g_deactivate));
    if (a == MH_OK) a = MH_EnableHook(table[6]);
    MH_STATUS b = MH_CreateHook(table[0], reinterpret_cast<void*>(&HookDestroy), reinterpret_cast<void**>(&g_destroy));
    if (b == MH_OK) b = MH_EnableHook(table[0]);
    if (a != MH_OK || b != MH_OK) {
        TF3_LOG("placement: the tool's close / destroy could not be hooked (%s, %s) - objects are not pinned", MH_StatusToString(a), MH_StatusToString(b));
        return false;
    }
    g_lifeHooked = true;
    g_pinnedTable = table;
    const auto base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    TF3_LOG("placement: the tool's close (+0x%llx) and destroy (+0x%llx) are watched - a pinned object is let go when the tool goes",
            static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(table[6]) - base),
            static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(table[0]) - base));
    return true;
}

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

void EnsureFilter();   // below
bool g_useFilter = false;   // [Placement] InputFilter: a second way, should the tool's own events not be enough
// Whether the input filter is in place and handles the right button while an object is pinned. Then the tool's
// own events must leave the right button alone: the filter keeps its movement from the game, so here a right
// drag would look like a right click and let go of the object.
std::atomic<bool> g_filterActive{false};

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
    // The right button while an object is pinned. Its press comes here as kind 8 and the movement while it is
    // held as kind 4 (a drag); the game's tool does nothing with either, so the view was dragged instead.
    // Both are taken here: the object turns, and the event is answered as dealt with.
    if (g_pinned == self && g_filterActive.load(std::memory_order_relaxed)) {
        // the filter on the game's input has the right button: its presses, drags and the click that lets go
        if (kind == 8 || kind == 4) return 1;
    } else if (g_pinned == self) {
        const bool held = (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
        if (held && !g_rightDown) {
            g_rightDown = true;
            g_rightMoved = 0;
            g_carry = 0;
        } else if (!held && g_rightDown) {
            g_rightDown = false;
            if (g_rightMoved < kClickSlack) {   // a right click without movement: let go of the object
                g_pinned = nullptr;
                return 1;
            }
        }
        if (kind == 8) return 1;
        if (kind == 4) {
            if (g_rightDown) {
                g_rightMoved += dx < 0 ? -dx : dx;
                g_carry += dx;
                const int steps = g_carry / kPointsPerStep;
                if (steps != 0) {
                    g_carry -= steps * kPointsPerStep;
                    Turn(self, steps);
                }
            }
            return 1;   // pinned: no drag moves it or the view
        }
    }
    if (g_pinned == self && g_toldEvents < 16 && (kind != 5 || g_toldEvents < 4)) {
        ++g_toldEvents;
        TF3_LOG("placement: while pinned - event kind %d, button %d, dx %d, right button %s", kind, button, dx,
                (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0 ? "down" : "up");
    }

    if (kind == 0) {
        if (button == 0) {
            if (g_pinned == self) {
                // the second click: build, with the tool's own click. The tool builds only when what it shows
                // is ready; just after a turn it may still be working it out, and the click then does nothing.
                // So the object stays pinned unless the tool really started building (its "building" flag).
                const uint64_t result = g_original(self, sender, event);
                const bool built = static_cast<const uint8_t*>(self)[kBuilding] != 0;
                if (built) {
                    g_pinned = nullptr;
                    g_rightDown = false;
                } else if (g_toldNotBuilt < 3) {
                    ++g_toldNotBuilt;
                    TF3_LOG("placement: the second click did not build (the preview was not ready) - the object stays pinned");
                }
                return result;
            }
            int state;
            std::memcpy(&state, static_cast<uint8_t*>(self) + kState, sizeof(state));
            if (state != 4) return g_original(self, sender, event);   // nothing buildable there: the game says why
            if (!EnsureLifeHooks(self)) return g_original(self, sender, event);   // cannot be undone safely: build at once
            std::memcpy(&g_pinnedTable, self, sizeof(g_pinnedTable));
            g_pinned = self;
            g_rightDown = false;
            if (g_useFilter) EnsureFilter();
            if (!told) {
                told = true;
                TF3_LOG("placement: an object was pinned by the first click (a second click builds it, right-drag turns it, a right click lets go)");
            }
            return 1;
        }
        if (g_pinned == self) {   // another button while pinned: the start of a turn, or of a click that lets go
            if (g_filterActive.load(std::memory_order_relaxed)) return 1;   // the filter deals with it
            g_rightDown = true;
            g_rightMoved = 0;
            g_carry = 0;
            return 1;
        }
        return g_original(self, sender, event);
    }
    if (kind == 1) {
        if (g_pinned == self && g_filterActive.load(std::memory_order_relaxed)) return 1;
        if (g_pinned == self && g_rightDown) {
            g_rightDown = false;
            if (g_rightMoved < kClickSlack) g_pinned = nullptr;   // a right click: let go of it
            return 1;
        }
        return g_original(self, sender, event);
    }
    if (kind == 5 && g_pinned == self) {
        if (g_filterActive.load(std::memory_order_relaxed)) return 1;   // pinned: still; the filter turns it
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

// ---- The right mouse button while an object is pinned --------------------------------------------------------
// The game gives the right button to its camera (drag) and to "back": with an object pinned, a right drag
// moved the view instead of turning the object. So while an object is pinned the right button's presses and
// the mouse's movement while it is held are taken out of the game's input before the game sees them, and
// turned into steps here. This uses the event filter of SDL, the library the game reads its input through
// (a public interface of SDL2.dll): ours is put in front of whatever filter the game has, and passes
// everything else on untouched.
using SdlFilter = int (*)(void* userdata, void* event);
using SdlGetFilter = int (*)(SdlFilter* filter, void** userdata);
using SdlSetFilter = void (*)(SdlFilter filter, void* userdata);
SdlGetFilter g_sdlGet = nullptr;
SdlSetFilter g_sdlSet = nullptr;
SdlFilter g_gameFilter = nullptr;
void* g_gameFilterData = nullptr;
bool g_filterIn = false;
int g_filterMoved = 0, g_filterCarry = 0;

constexpr uint32_t kSdlMouseMotion = 0x400, kSdlMouseDown = 0x401, kSdlMouseUp = 0x402;
constexpr uint8_t kSdlRightButton = 3;

std::atomic<bool> g_spotPress{false};   // a left press on one of our clickable spots was kept from the game

int FilterRight(void* userdata, void* event);   // below: the right button

// ---- Height with the middle mouse button while an object is pinned -----------------------------------------
// Holding the middle button and moving the mouse up or down steps the object's height, as the right button
// turns it. The middle button is kept from the game while an object is pinned (it would turn the view). Each
// step of kHeightStep points is left on the queue "tf3api_placement.height" as "1" (up) or "-1" (down); the
// placement mod's interface script hands it to the construction tool's own raise / lower handler, so the
// object and its height setting move as with the game's raise / lower keys.
int g_middleCarry = 0;
constexpr int kHeightStep = 12;            // points of mouse movement for one step
constexpr uint8_t kSdlMiddleButton = 2;

int Filter(void* userdata, void* event) {
    void* tool = g_pinned.load(std::memory_order_relaxed);
    if (tool != nullptr && !PinnedLooksAlive(tool)) {   // a last guard: the hooks should have let go already
        LetGo("the tool no longer looks like itself");
        tool = nullptr;
    }
    // Esc while an object is pinned goes back one step - the object follows the mouse again, keeping the height
    // and turn it was given - instead of closing the tool (a second Esc closes it, as the game does)
    static bool escTaken = false;
    if (event != nullptr) {
        const auto* k = static_cast<const uint8_t*>(event);
        uint32_t type;
        std::memcpy(&type, k, sizeof(type));
        int32_t scancode;
        std::memcpy(&scancode, k + 16, sizeof(scancode));
        constexpr uint32_t kSdlKeyDown = 0x300, kSdlKeyUp = 0x301;
        constexpr int32_t kSdlEscape = 41;
        if (type == kSdlKeyDown && scancode == kSdlEscape && tool != nullptr) {
            LetGo("Esc - back to moving it, height and turn kept");
            escTaken = true;
            return 0;
        }
        if (type == kSdlKeyUp && scancode == kSdlEscape && escTaken) {
            escTaken = false;
            return 0;
        }
    }
    if (event != nullptr && (tool != nullptr || g_middleDown.load(std::memory_order_relaxed))) {
        // the middle button: up and down drags step the height (not passed to the game, which would turn the view)
        const auto* e = static_cast<const uint8_t*>(event);
        uint32_t type;
        std::memcpy(&type, e, sizeof(type));
        if (type == kSdlMouseDown && e[16] == kSdlMiddleButton && tool != nullptr) {
            g_middleDown.store(true, std::memory_order_relaxed);
            g_middleCarry = 0;
            return 0;
        }
        if (type == kSdlMouseUp && e[16] == kSdlMiddleButton && g_middleDown.load(std::memory_order_relaxed)) {
            g_middleDown.store(false, std::memory_order_relaxed);
            return 0;
        }
        if (type == kSdlMouseMotion && g_middleDown.load(std::memory_order_relaxed)) {
            int32_t dy;
            std::memcpy(&dy, e + 32, sizeof(dy));   // movement since the last event, up / down (down is positive)
            g_middleCarry += dy;
            while (g_middleCarry <= -kHeightStep) {   // up: higher
                g_middleCarry += kHeightStep;
                lua_bridge::PostFromNative("tf3api_placement.height", "1");
            }
            while (g_middleCarry >= kHeightStep) {
                g_middleCarry -= kHeightStep;
                lua_bridge::PostFromNative("tf3api_placement.height", "-1");
            }
            return 0;
        }
    }
    return FilterRight(userdata, event);
}

int FilterRight(void* userdata, void* event) {
    void* tool = g_pinned.load(std::memory_order_relaxed);
    if (event != nullptr && tool == nullptr) {
        // a click on one of our clickable spots (a departure board) is ours: the game would take it for the
        // station or building behind it
        const auto* e = static_cast<const uint8_t*>(event);
        uint32_t type;
        std::memcpy(&type, e, sizeof(type));
        if (type == kSdlMouseDown && e[16] == 1 && road_labels::SpotWantsClick()) {
            g_spotPress.store(true, std::memory_order_relaxed);
            return 0;
        }
        if (type == kSdlMouseUp && e[16] == 1 && g_spotPress.exchange(false, std::memory_order_relaxed)) return 0;
    }
    if (event != nullptr && (tool != nullptr || g_filterRightDown.load(std::memory_order_relaxed))) {
        const auto* e = static_cast<const uint8_t*>(event);
        uint32_t type;
        std::memcpy(&type, e, sizeof(type));
        if (type == kSdlMouseDown && e[16] == kSdlRightButton && tool != nullptr) {
            g_filterRightDown.store(true, std::memory_order_relaxed);
            g_filterMoved = 0;
            g_filterCarry = 0;
            return 0;   // not for the game
        }
        if (type == kSdlMouseUp && e[16] == kSdlRightButton && g_filterRightDown.load(std::memory_order_relaxed)) {
            g_filterRightDown.store(false, std::memory_order_relaxed);
            // a right click: back to moving the object, keeping the height and turn it has now
            if (g_filterMoved < kClickSlack) LetGo("a right click - back to moving it, height and turn kept");
            return 0;
        }
        if (type == kSdlMouseMotion && g_filterRightDown.load(std::memory_order_relaxed)) {
            int32_t dx;
            std::memcpy(&dx, e + 28, sizeof(dx));   // movement since the last event, sideways
            g_filterMoved += dx < 0 ? -dx : dx;
            g_filterCarry += dx;
            const int steps = g_filterCarry / kPointsPerStep;
            if (steps != 0 && tool != nullptr) {
                g_filterCarry -= steps * kPointsPerStep;
                Turn(tool, steps);
            }
            return 0;
        }
    }
    return g_gameFilter != nullptr ? g_gameFilter(g_gameFilterData != nullptr ? g_gameFilterData : userdata, event) : 1;
}

// Puts the filter in, the first time an object is pinned (the game's input is certainly running by then).
void EnsureFilter() {
    if (g_filterIn) return;
    g_filterIn = true;   // one try
    const HMODULE sdl = GetModuleHandleW(L"SDL2.dll");
    if (sdl != nullptr) {
        g_sdlGet = reinterpret_cast<SdlGetFilter>(GetProcAddress(sdl, "SDL_GetEventFilter"));
        g_sdlSet = reinterpret_cast<SdlSetFilter>(GetProcAddress(sdl, "SDL_SetEventFilter"));
    }
    if (g_sdlGet == nullptr || g_sdlSet == nullptr) {
        TF3_LOG("placement: SDL's event filter is not there - the right button cannot be kept from the camera while an object is pinned");
        return;
    }
    g_gameFilter = nullptr;
    g_gameFilterData = nullptr;
    g_sdlGet(&g_gameFilter, &g_gameFilterData);
    g_sdlSet(&Filter, g_gameFilterData);
    g_filterActive.store(true, std::memory_order_relaxed);
    TF3_LOG("placement: the right mouse button is kept from the camera while an object is pinned (the game %s an input filter of its own)",
            g_gameFilter != nullptr ? "has" : "has not");
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

void EnsureInputFilter() { EnsureFilter(); }


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
    g_useFilter = config::GetBool("Placement", "InputFilter", true);   // seen needed: without it the right drag also moves the view
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
    if (g_filterIn && g_sdlGet != nullptr && g_sdlSet != nullptr) {
        // give the game its own filter back, if ours is still the one in place
        SdlFilter now = nullptr;
        void* data = nullptr;
        g_sdlGet(&now, &data);
        if (now == &Filter) g_sdlSet(g_gameFilter, g_gameFilterData);
    }
    MH_DisableHook(g_target);
    g_installed = false;
}

} // namespace tf3api::placement
