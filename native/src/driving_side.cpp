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
std::atomic<char> g_desired{0}, g_authored{0};

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
    if (g_desired.exchange(0) != 0 || g_authored.exchange(0) != 0) TF3_LOG("driving side: a game is being loaded - the sides are forgotten until its guard says them again");
    reinterpret_cast<PreLoadFn>(g_originalPreLoad)(a, b, c, d, e, f);
}

void* HookPart(void* context, uint8_t* out, void* table, void* extra) {
    void* result = g_originalPart(context, out, table, extra);
    if (!Active()) return result;
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


// The arrows of a street's edge objects (bus and tram stops; build 40420: the draw loop at 0x1408c6680 and the
// arrow itself at 0x1408c6d20). An object is stored by the side of the street it stands on: type 0 left, type 1
// right. The engine turns the arrow round only for a one-way street's left objects; for a two-way street it draws
// along the object's own direction, which was made for traffic on the right (the left side's lane runs against the
// street's direction, the right side's with it). On a street whose traffic keeps left that is the wrong way round.
// So for a game that keeps left the arrow follows the lane the stop is tied to: the first road lane for a left
// object, the last for a right one; it is turned round when that lane's direction is not the one the right-hand
// layout has (left: against, right: with). In any other game the engine's own rule is used unchanged.
using ArrowLeafFn = void (*)(void* a, void* edge, void* holder, int id, uint8_t flip, void* d, float scale);
using ArrowLoopFn = void (*)(void* a, uint8_t* holder, uint8_t* edge, void* d, float scale);
ArrowLoopFn g_originalArrows = nullptr;
ArrowLeafFn g_arrowLeaf = nullptr;
void* g_targetArrows = nullptr;
std::atomic<int> g_arrowsTurned{0};

bool IsRoadLane(const uint8_t* lane) {
    uint32_t modes;
    std::memcpy(&modes, lane + 0x10, 4);
    return (modes & 1) == 0 && modes != 0;
}

// The engine's rule (0x1426c5b20): every non-pedestrian lane has the same direction.
bool AllLanesAlike(const uint8_t* begin, const uint8_t* end) {
    int seen = -1;
    for (const uint8_t* lane = begin; lane != end; lane += kLaneSize) {
        if (!IsRoadLane(lane)) continue;
        if (seen < 0) seen = lane[kForwardOffset];
        else if (seen != lane[kForwardOffset]) return false;
    }
    return true;
}

void HookArrows(void* a, uint8_t* holder, uint8_t* edge, void* d, float scale) {
    // holder: the edge with its object list (+0x40 begin, +0x48 end, 8 bytes each: id, type) and its lanes (+0x70)
    __try {
        if (g_desired.load(std::memory_order_relaxed) != 'L' || edge == nullptr || holder == nullptr || g_arrowLeaf == nullptr) {
            g_originalArrows(a, holder, edge, d, scale);
            return;
        }
        const uint8_t* objects = *reinterpret_cast<uint8_t**>(holder + 0x40);
        const uint8_t* objectsEnd = *reinterpret_cast<uint8_t**>(holder + 0x48);
        const uint8_t* lanes = *reinterpret_cast<uint8_t**>(holder + 0x70);
        const uint8_t* lanesEnd = *reinterpret_cast<uint8_t**>(holder + 0x78);
        if (objects == objectsEnd) return;
        if (lanes == nullptr || lanesEnd < lanes || (static_cast<size_t>(lanesEnd - lanes) % kLaneSize) != 0) {
            g_originalArrows(a, holder, edge, d, scale);
            return;
        }
        bool ships = false;
        const uint8_t* first = nullptr;
        const uint8_t* last = nullptr;
        for (const uint8_t* lane = lanes; lane != lanesEnd; lane += kLaneSize) {
            uint32_t modes;
            std::memcpy(&modes, lane + 0x10, 4);
            if ((modes & 0x1400) != 0) ships = true;
            if (IsRoadLane(lane)) {
                if (first == nullptr) first = lane;
                last = lane;
            }
        }
        const bool oneWay = AllLanesAlike(lanes, lanesEnd);
        for (const uint8_t* object = objects; object != objectsEnd; object += 8) {
            int id, type;
            std::memcpy(&id, object, 4);
            std::memcpy(&type, object + 4, 4);
            if (ships) scale += scale;   // as the engine does, once more for every object
            uint8_t flip;
            if (oneWay || first == nullptr) {
                flip = (oneWay && type == 0) ? 1 : 0;   // the engine's own rule
            } else {
                const bool forward = (type == 0 ? first : last)[kForwardOffset] != 0;
                flip = (forward != (type != 0)) ? 1 : 0;
                if (flip != 0) g_arrowsTurned.fetch_add(1);
            }
            g_arrowLeaf(a, edge, holder, id, flip, d, scale);
        }
        static std::atomic<bool> said{false};
        if (g_arrowsTurned.load() > 0 && !said.exchange(true)) TF3_LOG("driving side: the arrow of a stop on a two-way street follows its lane (left-hand traffic)");
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        static std::atomic<bool> said{false};
        if (!said.exchange(true)) TF3_LOG("driving side: a stop arrow could not be drawn by the DLL's rule (the engine's layout is not what was expected)");
    }
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

void SetSides(char desired, char authored) {
    auto valid = [](char c) { return c == 'R' || c == 'L'; };
    if (!valid(desired)) desired = 0;
    if (!valid(authored)) authored = 0;
    const char before = Active() ? 1 : 0;
    const char oldDesired = g_desired.exchange(desired);
    const char oldAuthored = g_authored.exchange(authored);
    if (oldDesired != desired || oldAuthored != authored) {
        TF3_LOG("driving side: this game keeps to the %c, its data was written for the %c - buildings are %s", desired != 0 ? desired : '?', authored != 0 ? authored : '?',
                Active() ? "turned" : "left as they are");
    }
    (void)before;
}

void GetSides(char* desired, char* authored) {
    *desired = g_desired.load(std::memory_order_relaxed);
    *authored = g_authored.load(std::memory_order_relaxed);
}

bool Active() {
    const char desired = g_desired.load(std::memory_order_relaxed);
    const char authored = g_authored.load(std::memory_order_relaxed);
    return desired != 0 && authored != 0 && desired != authored;
}

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

    // The arrows of bus and tram stops: optional, the buildings and streets work without it.
    {
        const uintptr_t leaf = sigscan::FindUnique("stop arrow",
            "48 8B C4 48 89 58 10 48 89 70 20 55 57 41 56 48 8D 6C 24 80 48 81 EC 80 01 00 00 C5 F8 29 70 D8 C5 F8 29 78 C8 C5 78 29 40 B8");
        if (leaf != 0 && Hook("stop arrow loop",
                              "48 8B C4 48 89 58 18 55 57 41 55 41 56 41 57 48 83 EC 50 48 8B 5A 40 4D 8B F1 48 8B 6A 48 4D 8B E8 48 8B FA 4C 8B F9",
                              reinterpret_cast<void*>(&HookArrows), reinterpret_cast<void**>(&g_originalArrows), &g_targetArrows)) {
            g_arrowLeaf = reinterpret_cast<ArrowLeafFn>(leaf);
        }
    }
    TF3_LOG("driving side: ready - construction parts are turned in games whose left-hand traffic mod is enabled");
}

void Uninstall() {
    if (g_target != nullptr) MH_DisableHook(g_target);
    if (g_targetPart != nullptr) MH_DisableHook(g_targetPart);
    if (g_targetPreLoad != nullptr) MH_DisableHook(g_targetPreLoad);
    if (g_targetArrows != nullptr) MH_DisableHook(g_targetArrows);
    g_targetArrows = nullptr;
    g_arrowLeaf = nullptr;
    g_target = nullptr;
    g_targetPart = nullptr;
    g_targetPreLoad = nullptr;
    g_desired.store(0);
    g_authored.store(0);
}

} // namespace tf3api::driving_side
