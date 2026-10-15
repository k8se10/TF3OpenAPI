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
    std::printf("%s\n", g_failed == 0 ? "driving side test: ALL OK" : "driving side test: FAILED");
    return g_failed;
}
