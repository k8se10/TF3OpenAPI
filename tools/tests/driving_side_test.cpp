// Checks the rule that turns the lanes of a two-way street type (native/src/driving_side.cpp, TurnLanes) without the
// game: the engine's calls are stubbed. Build: see the header of tools/tests/ (any C++17 compiler):
//   cl /EHsc /std:c++17 /I native/src /I native/third_party/minhook/include driving_side_test.cpp ../../native/src/driving_side.cpp
#include "driving_side.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <vector>

namespace tf3api {
namespace config { bool GetBool(const char*, const char*, bool d) { return d; } int GetInt(const char*, const char*, int d) { return d; } }
namespace log { void Write(const char*, ...) {} }
namespace sigscan { uintptr_t FindUnique(const char*, const char*) { return 0; } }
}
extern "C" {
int MH_CreateHook(void*, void*, void**) { return 0; }
int MH_EnableHook(void*) { return 0; }
int MH_DisableHook(void*) { return 0; }
const char* MH_StatusToString(int) { return ""; }
}

using tf3api::driving_side::kLaneSize;
using tf3api::driving_side::kForwardOffset;
using tf3api::driving_side::kModesOffset;

static std::vector<uint8_t> Lanes(std::initializer_list<std::pair<uint32_t, int>> list) {
    std::vector<uint8_t> v(list.size() * kLaneSize, 0);
    size_t i = 0;
    for (const auto& l : list) {
        std::memcpy(&v[i * kLaneSize + kModesOffset], &l.first, 4);
        v[i * kLaneSize + kForwardOffset] = static_cast<uint8_t>(l.second);
        ++i;
    }
    return v;
}

static int g_failed = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAILED: %s (line %d)\n", #c, __LINE__); ++g_failed; } } while (0)

int main() {
    // stop arrows: right-hand layout (left lane backward, right lane forward) is never turned; left-hand (flags swapped) always
    CHECK(!tf3api::driving_side::StopArrowFlip(false, 0, false) && !tf3api::driving_side::StopArrowFlip(false, 1, true));
    CHECK(tf3api::driving_side::StopArrowFlip(false, 0, true) && tf3api::driving_side::StopArrowFlip(false, 1, false));
    CHECK(tf3api::driving_side::StopArrowFlip(true, 0, true) && !tf3api::driving_side::StopArrowFlip(true, 1, true));   // one-way: the engine's rule
    const uint32_t ROAD = 0x7c, PERSON = 1, TRAM = 1u << 5;
    // sidewalk, back lane, back lane, fwd lane, fwd lane, sidewalk (kerb to kerb): two-way
    auto two = Lanes({ { PERSON, 1 }, { ROAD, 0 }, { ROAD, 0 }, { ROAD, 1 }, { ROAD, 1 }, { PERSON, 1 } });
    CHECK(tf3api::driving_side::TurnLanes(two.data(), 6));
    CHECK(two[0 * kLaneSize + kForwardOffset] == 1 && two[5 * kLaneSize + kForwardOffset] == 1);   // sidewalks stay
    CHECK(two[1 * kLaneSize + kForwardOffset] == 1 && two[2 * kLaneSize + kForwardOffset] == 1);   // were backward
    CHECK(two[3 * kLaneSize + kForwardOffset] == 0 && two[4 * kLaneSize + kForwardOffset] == 0);   // were forward
    // one-way: all road lanes the same way: untouched
    auto one = Lanes({ { PERSON, 1 }, { ROAD, 1 }, { ROAD, 1 }, { PERSON, 1 } });
    CHECK(!tf3api::driving_side::TurnLanes(one.data(), 4));
    CHECK(one[1 * kLaneSize + kForwardOffset] == 1 && one[2 * kLaneSize + kForwardOffset] == 1);
    // a one-way street with a tram lane running the other way is two-way for road lanes: turned (tram included)
    auto mixed = Lanes({ { ROAD, 1 }, { TRAM, 0 } });
    CHECK(tf3api::driving_side::TurnLanes(mixed.data(), 2));
    CHECK(mixed[0 * kLaneSize + kForwardOffset] == 0 && mixed[1 * kLaneSize + kForwardOffset] == 1);
    // no road lanes (a footpath), nothing at all
    auto path = Lanes({ { PERSON, 1 }, { PERSON, 0 } });
    CHECK(!tf3api::driving_side::TurnLanes(path.data(), 2));
    CHECK(!tf3api::driving_side::TurnLanes(nullptr, 3));
    CHECK(!tf3api::driving_side::TurnLanes(two.data(), 0));
    // turning twice gives the original back
    auto again = Lanes({ { ROAD, 0 }, { ROAD, 1 } });
    tf3api::driving_side::TurnLanes(again.data(), 2);
    tf3api::driving_side::TurnLanes(again.data(), 2);
    CHECK(again[0 * kLaneSize + kForwardOffset] == 0 && again[1 * kLaneSize + kForwardOffset] == 1);
    // ---- a construction part: lane lists, a station terminal and a depot, laid out as the engine does
    using namespace tf3api::driving_side;
    struct List {
        std::vector<int32_t> modes;
        std::vector<float> nodes;   // 7 floats a node: position, direction, width
    };
    auto node = [](float x, float dx) { return std::vector<float>{ x, 0, 0, dx, 0, 0, 3.f }; };
    auto lane = [&](float x0, float x1) {
        std::vector<float> v = node(x0, 1);
        std::vector<float> b = node(x1, 1);
        v.insert(v.end(), b.begin(), b.end());
        return v;
    };
    auto twoPieces = [&]() {
        std::vector<float> v = lane(0, 10);
        std::vector<float> w = lane(20, 30);
        v.insert(v.end(), w.begin(), w.end());
        return v;
    };
    List road{ { 2, 3, 4 }, twoPieces() };            // a road lane list: two pieces, x 0 to 10 and x 20 to 30
    List people{ { 0 }, lane(5, 6) };                 // pedestrians: left alone
    List shared{ { 2, 7 }, lane(7, 8) };               // road and train: left alone
    std::vector<List*> all{ &road, &people, &shared };
    std::vector<uint8_t> lists(all.size() * kLaneListSize, 0);
    auto setVec = [](uint8_t* at, void* begin, size_t bytes) {
        uint8_t* b = static_cast<uint8_t*>(begin);
        uint8_t* e = b + bytes;
        std::memcpy(at, &b, 8);
        std::memcpy(at + 8, &e, 8);
        std::memcpy(at + 16, &e, 8);
    };
    auto layLists = [&]() {
        for (size_t i = 0; i < all.size(); ++i) {
            uint8_t* l = &lists[i * kLaneListSize];
            setVec(l + kListModes, all[i]->modes.data(), all[i]->modes.size() * 4);
            setVec(l + kListNodes, all[i]->nodes.data(), all[i]->nodes.size() * 4);
        }
    };
    layLists();
    struct Terminal { uint8_t raw[kTerminalSize]; };
    std::vector<Terminal> terminals(3);
    std::memset(terminals.data(), 0, terminals.size() * sizeof(Terminal));
    auto vehicleNode = [&](size_t i, int list, int n) {
        std::memcpy(terminals[i].raw + kTerminalVehicleNode, &list, 4);
        std::memcpy(terminals[i].raw + kTerminalVehicleNode + 4, &n, 4);
    };
    vehicleNode(0, 0, 1);    // on the road list, node 1
    vehicleNode(1, 1, 0);    // on the pedestrian list
    vehicleNode(2, -1, -1);  // none
    std::vector<uint8_t> sub(0x300, 0);
    setVec(&sub[kSubLaneLists], lists.data(), lists.size());
    setVec(&sub[kSubStation], terminals.data(), terminals.size() * kTerminalSize);
    TurnedParts done = TurnSubconstruction(sub.data());
    CHECK(done.lists == 1);
    CHECK(road.nodes[0] == 10 && road.nodes[7] == 0);             // the first piece now runs from x 10 to x 0
    CHECK(road.nodes[3] == -1 && road.nodes[10] == -1);           // directions negated
    CHECK(road.nodes[14] == 30 && road.nodes[21] == 20);          // the second piece too
    CHECK(road.nodes[6] == 3.f && road.nodes[13] == 3.f);         // widths follow the nodes
    CHECK(lists[kListForwardOnly] == 1 && lists[kListForwardOnly + 1] == 1);
    CHECK(people.nodes[0] == 5 && shared.nodes[0] == 7);           // other lists untouched
    int32_t n0, l1, n1;
    std::memcpy(&n0, terminals[0].raw + kTerminalVehicleNode + 4, 4);
    std::memcpy(&l1, terminals[1].raw + kTerminalVehicleNode, 4);
    std::memcpy(&n1, terminals[1].raw + kTerminalVehicleNode + 4, 4);
    CHECK(n0 == 0);                    // node 1 is now node 0
    CHECK(l1 == 1 && n1 == 0);         // a stop on another list stays
    CHECK(done.stops == 1);
    // a depot whose ways are on the turned list: ways in and out change places, and their nodes follow
    std::vector<int32_t> inNodes{ 0, 0 }, outNodes{ 0, 3, 0, 1 };   // in: (list 0, node 0); out: (0, 3), (0, 1)
    road.nodes = twoPieces();
    layLists();
    std::vector<uint8_t> sub2(0x300, 0);
    setVec(&sub2[kSubLaneLists], lists.data(), lists.size());
    sub2[kSubDepot + kDepotPresent] = 1;
    setVec(&sub2[kSubDepot + kDepotIn], inNodes.data(), 8);
    setVec(&sub2[kSubDepot + kDepotOut], outNodes.data(), 16);
    done = TurnSubconstruction(sub2.data());
    CHECK(done.lists == 1 && done.stops == 2);
    uint8_t* in2 = nullptr;
    uint8_t* out2 = nullptr;
    std::memcpy(&in2, &sub2[kSubDepot + kDepotIn], 8);
    std::memcpy(&out2, &sub2[kSubDepot + kDepotOut], 8);
    int32_t a, b, c, d;
    std::memcpy(&a, in2, 4); std::memcpy(&b, in2 + 4, 4); std::memcpy(&c, in2 + 8, 4); std::memcpy(&d, in2 + 12, 4);
    CHECK(a == 0 && b == 2 && c == 0 && d == 0);   // the old out ways (nodes 3 and 1) are the new in ways (2 and 0)
    std::memcpy(&a, out2, 4); std::memcpy(&b, out2 + 4, 4);
    CHECK(a == 0 && b == 1);                       // the old in way (node 0) is the new out way (node 1)
    // nothing readable: left alone
    std::vector<uint8_t> empty(0x300, 0);
    CHECK(TurnSubconstruction(empty.data()).lists == 0);
    CHECK(TurnSubconstruction(nullptr).lists == 0);
    std::printf("%s\n", g_failed == 0 ? "driving side test: ALL OK" : "driving side test: FAILED");
    return g_failed;
}
