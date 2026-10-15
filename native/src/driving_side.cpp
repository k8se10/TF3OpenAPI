#include "driving_side.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <cstring>

#include "MinHook.h"

namespace tf3api::driving_side {

bool TurnLanes(uint8_t* lanes, size_t count) {
    if (lanes == nullptr || count == 0) return false;
    bool forward = false, backward = false;
    for (size_t i = 0; i < count; ++i) {
        const uint8_t* lane = lanes + i * kLaneSize;
        uint32_t modes;
        std::memcpy(&modes, lane + kModesOffset, sizeof(modes));
        if ((modes & kRoadModes) == 0) continue;
        if (lane[kForwardOffset] != 0) forward = true;
        else backward = true;
    }
    if (!forward || !backward) return false;   // one-way (or no road lanes): left as it is
    for (size_t i = 0; i < count; ++i) {
        uint8_t* lane = lanes + i * kLaneSize;
        uint32_t modes;
        std::memcpy(&modes, lane + kModesOffset, sizeof(modes));
        if ((modes & kRoadModes) == 0) continue;
        lane[kForwardOffset] = lane[kForwardOffset] != 0 ? 0 : 1;
    }
    return true;
}

namespace {

// The engine's converter from a street type's Lua table to its StreetTemplate (build 40420: 0x140bbab90).
// (first argument, the output, the Lua table); returns its second argument.
using ConvertFn = void* (*)(void* context, uint8_t* out, void* table);
ConvertFn g_original = nullptr;
void* g_target = nullptr;
std::atomic<int> g_turned{0}, g_seen{0};

constexpr size_t kLanesOffset = 0x60;       // StreetTemplate: the lane vector (begin, end, capacity)
constexpr size_t kBusAndTramRightOffset = 0x7f;

void* HookConvert(void* context, uint8_t* out, void* table) {
    void* result = g_original(context, out, table);
    __try {
        if (out != nullptr) {
            uint8_t* begin = *reinterpret_cast<uint8_t**>(out + kLanesOffset);
            uint8_t* end = *reinterpret_cast<uint8_t**>(out + kLanesOffset + 8);
            if (begin != nullptr && end > begin && (static_cast<size_t>(end - begin) % kLaneSize) == 0) {
                const size_t count = static_cast<size_t>(end - begin) / kLaneSize;
                if (count <= 32) {
                    g_seen.fetch_add(1);
                    if (TurnLanes(begin, count)) {
                        out[kBusAndTramRightOffset] = 0;   // the kerb lane for buses and trams is the left one
                        const int n = g_turned.fetch_add(1) + 1;
                        if (n == 1 || n == 10 || n == 50) TF3_LOG("driving side: %d two-way street types turned to left-hand traffic (of %d read)", n, g_seen.load());
                    }
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        static std::atomic<bool> said{false};
        if (!said.exchange(true)) TF3_LOG("driving side: a street type could not be turned (the engine's layout is not what was expected)");
    }
    return result;
}

} // namespace

void Install() {
    if (!config::GetBool("LeftHandTraffic", "Enabled", false)) return;
    g_target = reinterpret_cast<void*>(sigscan::FindUnique(
        "street type converter",
        "48 89 5C 24 08 48 89 74 24 20 55 57 41 56 48 8D AC 24 D0 FA FF FF 48 81 EC 30 06 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 20 05 00 00"));
    if (g_target == nullptr) {
        TF3_LOG("driving side: the street type converter was not found - left-hand traffic is unavailable");
        return;
    }
    MH_STATUS status = MH_CreateHook(g_target, reinterpret_cast<void*>(&HookConvert), reinterpret_cast<void**>(&g_original));
    if (status == MH_OK) status = MH_EnableHook(g_target);
    if (status != MH_OK) {
        TF3_LOG("driving side: the hook could not be installed (%s)", MH_StatusToString(status));
        g_target = nullptr;
        return;
    }
    TF3_LOG("driving side: left-hand traffic is on for street types read from now on (converter at +0x%llx)",
            static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_target) - reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr))));
}

void Uninstall() {
    if (g_target == nullptr) return;
    MH_DisableHook(g_target);
    g_target = nullptr;
}

} // namespace tf3api::driving_side
