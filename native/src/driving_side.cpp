#include "driving_side.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <cstring>
#include <vector>

#include "MinHook.h"

namespace tf3api::driving_side {
namespace {

template <typename T>
T Read(const uint8_t* at) {
    T value;
    std::memcpy(&value, at, sizeof(T));
    return value;
}

template <typename T>
void Write(uint8_t* at, T value) {
    std::memcpy(at, &value, sizeof(T));
}

// A std::vector as the engine lays it out: begin, end, capacity pointers. False when it is not plausible.
bool VectorOf(const uint8_t* vec, size_t elementSize, size_t maxCount, uint8_t** begin, size_t* count) {
    uint8_t* b = Read<uint8_t*>(vec);
    uint8_t* e = Read<uint8_t*>(vec + 8);
    if (b == nullptr || e < b) return false;
    const size_t bytes = static_cast<size_t>(e - b);
    if (bytes % elementSize != 0 || bytes / elementSize > maxCount) return false;
    *begin = b;
    *count = bytes / elementSize;
    return true;
}

bool IsRoadList(const uint8_t* list) {
    uint8_t* modes;
    size_t modeCount;
    if (!VectorOf(list + kListModes, 4, 32, &modes, &modeCount) || modeCount == 0) return false;
    for (size_t i = 0; i < modeCount; ++i) {
        const int mode = Read<int32_t>(modes + i * 4);
        if (mode < kFirstRoadMode || mode > kLastRoadMode) return false;   // shared with people, trains, ships ...: left alone
    }
    uint8_t* nodes;
    size_t nodeCount;
    return VectorOf(list + kListNodes, kNodeSize, 65536, &nodes, &nodeCount) && nodeCount > 0 && nodeCount % 2 == 0;
}

void TurnList(uint8_t* list) {
    uint8_t* nodes;
    size_t nodeCount;
    if (!VectorOf(list + kListNodes, kNodeSize, 65536, &nodes, &nodeCount)) return;
    for (size_t i = 0; i + 1 < nodeCount; i += 2) {
        uint8_t* a = nodes + i * kNodeSize;
        uint8_t* b = a + kNodeSize;
        uint8_t swap[kNodeSize];
        std::memcpy(swap, a, kNodeSize);
        std::memcpy(a, b, kNodeSize);
        std::memcpy(b, swap, kNodeSize);
        for (uint8_t* node : { a, b }) {
            for (int k = 0; k < 3; ++k) Write<float>(node + kNodeDirection + k * 4, -Read<float>(node + kNodeDirection + k * 4));
        }
    }
    list[kListForwardOnly] = 1;       // a lane that may be driven both ways would undo the turn
    list[kListForwardOnly + 1] = 1;
}

// Every pair (lane list, node) of a vector of such pairs that is on a turned list: true when all of them are.
bool AllOnTurned(const uint8_t* vec, const std::vector<bool>& turned) {
    uint8_t* pairs;
    size_t count;
    if (!VectorOf(vec, 8, 4096, &pairs, &count) || count == 0) return false;
    for (size_t i = 0; i < count; ++i) {
        const int32_t list = Read<int32_t>(pairs + i * 8);
        const int32_t node = Read<int32_t>(pairs + i * 8 + 4);
        if (list < 0 || static_cast<size_t>(list) >= turned.size() || !turned[static_cast<size_t>(list)] || node < 0) return false;
    }
    return true;
}

void FlipNodes(const uint8_t* vec) {
    uint8_t* pairs;
    size_t count;
    if (!VectorOf(vec, 8, 4096, &pairs, &count)) return;
    for (size_t i = 0; i < count; ++i) Write<int32_t>(pairs + i * 8 + 4, Read<int32_t>(pairs + i * 8 + 4) ^ 1);
}

} // namespace

bool TurnLanes(uint8_t* lanes, size_t count) {
    if (lanes == nullptr || count == 0) return false;
    bool forward = false, backward = false;
    for (size_t i = 0; i < count; ++i) {
        const uint8_t* lane = lanes + i * kLaneSize;
        const uint32_t modes = Read<uint32_t>(lane + kModesOffset);
        if ((modes & kRoadModes) == 0) continue;
        if (lane[kForwardOffset] != 0) forward = true;
        else backward = true;
    }
    if (!forward || !backward) return false;   // one-way (or no road lanes): left as it is
    for (size_t i = 0; i < count; ++i) {
        uint8_t* lane = lanes + i * kLaneSize;
        const uint32_t modes = Read<uint32_t>(lane + kModesOffset);
        if ((modes & kRoadModes) == 0) continue;
        lane[kForwardOffset] = lane[kForwardOffset] != 0 ? 0 : 1;
    }
    return true;
}

TurnedParts TurnSubconstruction(uint8_t* sub) {
    TurnedParts done;
    if (sub == nullptr) return done;
    uint8_t* lists;
    size_t listCount;
    if (!VectorOf(sub + kSubLaneLists, kLaneListSize, 256, &lists, &listCount) || listCount == 0) return done;
    std::vector<bool> turned(listCount, false);
    for (size_t i = 0; i < listCount; ++i) {
        uint8_t* list = lists + i * kLaneListSize;
        if (!IsRoadList(list)) continue;
        TurnList(list);
        turned[i] = true;
        ++done.lists;
    }
    if (done.lists == 0) return done;

    // a station's terminals: where road vehicles stop, named by a node of a lane list
    uint8_t* terminals;
    size_t terminalCount;
    if (VectorOf(sub + kSubStation, kTerminalSize, 256, &terminals, &terminalCount)) {
        for (size_t i = 0; i < terminalCount; ++i) {
            uint8_t* at = terminals + i * kTerminalSize + kTerminalVehicleNode;
            const int32_t list = Read<int32_t>(at);
            const int32_t node = Read<int32_t>(at + 4);
            if (list >= 0 && static_cast<size_t>(list) < listCount && turned[static_cast<size_t>(list)] && node >= 0) {
                Write<int32_t>(at + 4, node ^ 1);
                ++done.stops;
            }
        }
    }

    // a depot: vehicles came in at the end of one lane and left from the start of another; with both turned, the
    // ways in and out change places (only when every way is on a turned list)
    uint8_t* depot = sub + kSubDepot;
    if (depot[kDepotPresent] != 0 && AllOnTurned(depot + kDepotIn, turned) && AllOnTurned(depot + kDepotOut, turned)) {
        uint8_t swap[24];
        std::memcpy(swap, depot + kDepotIn, 24);
        std::memcpy(depot + kDepotIn, depot + kDepotOut, 24);
        std::memcpy(depot + kDepotOut, swap, 24);
        FlipNodes(depot + kDepotIn);
        FlipNodes(depot + kDepotOut);
        done.stops += 2;
    }
    return done;
}

namespace {

// The engine's converter from a street type's Lua table to its StreetTemplate (build 40420: 0x140bbab90).
// (first argument, the output, the Lua table); returns its second argument.
using ConvertFn = void* (*)(void* context, uint8_t* out, void* table);
ConvertFn g_original = nullptr;
void* g_target = nullptr;
std::atomic<int> g_turned{0}, g_seen{0};

// The engine's converter from a construction part's Lua table to its structure (0x142c1e910).
using PartFn = void* (*)(void* context, uint8_t* out, void* table, void* extra);
PartFn g_originalPart = nullptr;
void* g_targetPart = nullptr;
std::atomic<int> g_parts{0}, g_partLists{0}, g_partStops{0};
std::atomic<bool> g_active{false};

// The menu's PreLoadAsync (0x1406a22b0, build 40420): the start of loading a game, before any of its mods run.
using PreLoadFn = void (*)(void*, void*, void*, void*, void*, void*);
void* g_targetPreLoad = nullptr;
void* g_originalPreLoad = nullptr;

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

// PreLoadAsync takes six arguments and returns nothing (decompiled): they are passed on as they came.
void HookPreLoad(void* a, void* b, void* c, void* d, void* e, void* f) {
    if (g_active.exchange(false)) TF3_LOG("driving side: a game is being loaded - left-hand traffic is off until its mods say so");
    reinterpret_cast<PreLoadFn>(g_originalPreLoad)(a, b, c, d, e, f);
}

void* HookPart(void* context, uint8_t* out, void* table, void* extra) {
    void* result = g_originalPart(context, out, table, extra);
    if (!g_active.load(std::memory_order_relaxed)) return result;
    __try {
        const TurnedParts done = TurnSubconstruction(out);
        if (done.lists > 0) {
            const int n = g_parts.fetch_add(1) + 1;
            g_partLists.fetch_add(done.lists);
            g_partStops.fetch_add(done.stops);
            if (n == 1 || n == 10 || n == 100) {
                TF3_LOG("driving side: %d construction parts turned (%d lane lists, %d stops and depot ways so far)", n, g_partLists.load(), g_partStops.load());
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        static std::atomic<bool> said{false};
        if (!said.exchange(true)) TF3_LOG("driving side: a construction part could not be turned (the engine's layout is not what was expected)");
    }
    return result;
}

bool Hook(const char* name, const char* pattern, void* detour, void** original, void** target) {
    *target = reinterpret_cast<void*>(sigscan::FindUnique(name, pattern));
    if (*target == nullptr) {
        TF3_LOG("driving side: %s was not found - left-hand traffic is unavailable", name);
        return false;
    }
    MH_STATUS status = MH_CreateHook(*target, detour, original);
    if (status == MH_OK) status = MH_EnableHook(*target);
    if (status != MH_OK) {
        TF3_LOG("driving side: the hook for %s could not be installed (%s)", name, MH_StatusToString(status));
        *target = nullptr;
        return false;
    }
    return true;
}

} // namespace

void SetActive(bool on) {
    if (on && g_targetPart != nullptr && !g_active.exchange(true)) TF3_LOG("driving side: left-hand traffic is on for this game (its mod is enabled)");
    if (!on) g_active.store(false);
}

bool Active() { return g_active.load(std::memory_order_relaxed); }

bool Available() { return g_targetPart != nullptr && g_targetPreLoad != nullptr; }

void Install() {
    if (!config::GetBool("LeftHandTraffic", "Enabled", true)) return;
    // The buildings' lanes are turned here, in the engine; the streets are turned by the mod's own rule at the
    // street type resource (it knows which types are one-way, for the junction pieces), so this module's street
    // hook is not installed (it stays for [LeftHandTraffic] NativeStreets=1, for trying).
    bool ok = true;
    if (config::GetBool("LeftHandTraffic", "NativeStreets", false)) {
        ok = Hook("street type converter",
                  "48 89 5C 24 08 48 89 74 24 20 55 57 41 56 48 8D AC 24 D0 FA FF FF 48 81 EC 30 06 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 20 05 00 00",
                  reinterpret_cast<void*>(&HookConvert), reinterpret_cast<void**>(&g_original), &g_target);
    }
    // Both the part hook and the reset at the start of loading a game, or neither: without the reset the setting of
    // one game could carry over to the next.
    const bool parts = ok && Hook("construction part converter",
                                  "48 89 5C 24 08 48 89 54 24 10 57 48 83 EC 30 49 8B D8 48 8B FA C7 44 24 20 00 00 00 00 48 8B CA E8 ?? ?? ?? ?? C7 44 24 20 01 00 00 00 48 8D 8F 40 01 00 00",
                                  reinterpret_cast<void*>(&HookPart), reinterpret_cast<void**>(&g_originalPart), &g_targetPart);
    const bool reset = parts && Hook("start of loading a game",
                                     "48 89 5C 24 10 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 D0 FE FF FF 48 81 EC 30 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 20 01 00 00 4C 89 4C 24 60 4D 8B E0 4C 8B F9",
                                     reinterpret_cast<void*>(&HookPreLoad), &g_originalPreLoad, &g_targetPreLoad);
    if (!reset) {
        Uninstall();
        TF3_LOG("driving side: not available (a part of it could not be hooked)");
        return;
    }
    TF3_LOG("driving side: ready - construction parts are turned in games whose left-hand traffic mod is enabled");
}

void Uninstall() {
    if (g_target != nullptr) MH_DisableHook(g_target);
    if (g_targetPart != nullptr) MH_DisableHook(g_targetPart);
    if (g_targetPreLoad != nullptr) MH_DisableHook(g_targetPreLoad);
    g_target = nullptr;
    g_targetPart = nullptr;
    g_targetPreLoad = nullptr;
    g_active.store(false);
}

} // namespace tf3api::driving_side
