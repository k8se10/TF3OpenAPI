#include "plan_view.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>

#include "MinHook.h"

namespace tf3api::plan_view {
namespace {

// The orbit of a live view round an entity without camera positions of its own, part of UI::FollowAction
// (build 40420: 0x1405329c0, called once from UI::FollowAction::SetCameraData):
//     orbit(action, dt, entity)
//         camera = *(action + 0xc8):  +0x00 eye (3 floats), +0x0c direction of view (3), +0x18 up (3),
//                                     +0x24 the angle of the circling
//         eye = middle of the entity's bounding sphere - distance * direction, up = (0, 0, 1),
//         direction = level direction at the angle, tilted down; the angle moves on with dt.
// Found by its opening; the address of the stack check value is left open.
const char kPattern[] =
    "48 8B C4 48 89 58 10 48 89 68 18 56 57 41 56 48 81 EC B0 00 00 00 C5 F8 29 70 D8 C5 F8 29 78 C8 C5 78 29 40 B8 C5 78 29 50 A8 "
    "48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 44 24 68 49 63 D8 48 8B E9";

constexpr uint32_t kCamera = 0xc8;
constexpr int kAny = -2;   // plan_view.h: Set(-2, ...) applies to every circling live view

using Orbit = void (*)(void* action, float dt, int entity);
Orbit g_original = nullptr;
void* g_target = nullptr;
bool g_installed = false;

struct View {
    int entity = -1;
    float eye[3] = {}, up[3] = {};
};
constexpr int kViews = 8;
std::mutex g_lock;
View g_views[kViews];
int g_count = 0;   // read without the lock as a quick "anything set at all"

void Hook(void* action, float dt, int entity) {
    g_original(action, dt, entity);
    if (g_count == 0 || action == nullptr) return;
    static int toldCalls = 0;
    if (toldCalls < 5) {   // which entities the circling views are about, while a plan is asked for
        ++toldCalls;
        TF3_LOG("plan view: a live view circles entity %d", entity);
    }
    View view;
    {
        std::lock_guard<std::mutex> lock(g_lock);
        bool found = false;
        // a view set for one entity, else the one for "any" (kAny: whatever live view is circling)
        for (const View& v : g_views) {
            if (v.entity == entity || (!found && v.entity == kAny)) {
                view = v;
                found = true;
                if (v.entity == entity) break;
            }
        }
        if (!found) return;
    }
    uint8_t* camera = nullptr;
    std::memcpy(&camera, static_cast<uint8_t*>(action) + kCamera, sizeof(camera));
    if (camera == nullptr) return;
    const float down[3] = {0.0f, 0.0f, -1.0f};
    std::memcpy(camera + 0x00, view.eye, sizeof(view.eye));
    std::memcpy(camera + 0x0c, down, sizeof(down));
    std::memcpy(camera + 0x18, view.up, sizeof(view.up));
    static bool told = false;
    if (!told) {
        told = true;
        TF3_LOG("plan view: the live view of entity %d looks straight down from (%.1f, %.1f, %.1f)", entity, view.eye[0], view.eye[1],
                view.eye[2]);
    }
}

} // namespace

bool Available() { return g_installed; }

bool Set(int entity, float x, float y, float z, float height, float upX, float upY) {
    if (!g_installed || (entity < 0 && entity != kAny)) return false;
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) || !std::isfinite(height) || height < 1.0f) return false;
    float length = std::sqrt(upX * upX + upY * upY);
    if (!std::isfinite(length) || length < 1e-4f) {
        upX = 0.0f;
        upY = 1.0f;
        length = 1.0f;
    }
    std::lock_guard<std::mutex> lock(g_lock);
    View* slot = nullptr;
    for (View& v : g_views) {
        if (v.entity == entity) slot = &v;
    }
    if (slot == nullptr) {
        for (View& v : g_views) {
            if (v.entity == -1 && slot == nullptr) slot = &v;
        }
        if (slot == nullptr) return false;
        ++g_count;
    }
    slot->entity = entity;
    slot->eye[0] = x;
    slot->eye[1] = y;
    slot->eye[2] = z + height;
    slot->up[0] = upX / length;
    slot->up[1] = upY / length;
    slot->up[2] = 0.0f;
    return true;
}

void Clear(int entity) {
    std::lock_guard<std::mutex> lock(g_lock);
    for (View& v : g_views) {
        if (v.entity == entity && (entity >= 0 || entity == kAny)) {
            v.entity = -1;
            --g_count;
        }
    }
}

void Install() {
    if (!config::GetBool("Boards", "PlanView", false)) {
        TF3_LOG("plan view: off ([Boards] PlanView=0, the default until it has been seen working)");
        return;
    }
    const uintptr_t orbit = sigscan::FindUnique("live view: orbit of a building", kPattern);
    if (orbit == 0) {
        TF3_LOG("plan view: the live view's orbit was not found on this build - live views stay as the game has them");
        return;
    }
    g_target = reinterpret_cast<void*>(orbit);
    MH_STATUS status = MH_CreateHook(g_target, reinterpret_cast<void*>(&Hook), reinterpret_cast<void**>(&g_original));
    if (status == MH_OK) status = MH_EnableHook(g_target);
    if (status != MH_OK) {
        TF3_LOG("plan view: the hook could not be installed (%s)", MH_StatusToString(status));
        g_target = nullptr;
        return;
    }
    g_installed = true;
    TF3_LOG("plan view: ready at +0x%llx", static_cast<unsigned long long>(orbit - reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr))));
}

void Uninstall() {
    if (!g_installed) return;
    MH_DisableHook(g_target);
    g_installed = false;
}

} // namespace tf3api::plan_view
