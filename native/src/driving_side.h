#pragma once

#include <cstddef>
#include <cstdint>

// Driving side, in the engine.
//
// The engine has no notion of a driving side: which side vehicles use comes from the `forward` flag of each lane
// of a street type, read when the street type's Lua table is turned into the engine's own StreetTemplate
// (build 40420: the converter at 0x140bbab90; its lane list is the vector at +0x60, 0x18 bytes a lane: speed,
// width, height, `forward` byte at +0xc, transport modes at +0x10, offset at +0x14). With [LeftHandTraffic]
// Enabled=1 this hooks that converter and, for every two-way street type (road lanes in both directions), turns
// the direction of the road lanes. The type's lanes are listed kerb to kerb, so turning every flag moves the
// traffic to the other side of the road; one-way types are left alone, and so are sidewalks and rails.
//
// It applies to every street type of every mod alike, and only to streets built (or rebuilt) after the engine
// reads the type: a network is saved as built, so streets already in a save keep the side they were made with.
//
// Buildings: the engine reads a construction's parts (its "subconstructions": a station, a depot, a yard ...) with
// the converter at 0x142c1e910 (build 40420). Each part has lane lists (vector at +0x158, 0x80 bytes a list: the
// transport modes vector at +0x40, the nodes vector at +0x60 - 0x1c bytes a node: position, direction, width -
// and a `forwardOnly` byte at +0x7a). The nodes of a list come in pairs, one piece of lane each, from the first
// node to the second. After that converter runs, every list made only for road vehicles is turned: each pair
// changes places and its directions are negated, so a node numbered n is afterwards the node numbered n ^ 1. The
// things that name nodes follow: a station terminal's `vehicleNode` (terminal at 0x98 bytes, the pair at +0x30),
// and a depot's ways in and out, which change places with their lanes. This is the rule the script mod
// tf3api_left_hand_traffic (core.lua, `construction`) tested outside the game; here it is the engine's own.
namespace tf3api::driving_side {

constexpr size_t kSubLaneLists = 0x158;   // vector of lane lists (begin, end, capacity)
constexpr size_t kLaneListSize = 0x80;
constexpr size_t kListModes = 0x40;       // vector<int> of transport modes
constexpr size_t kListNodes = 0x60;       // vector of nodes
constexpr size_t kListForwardOnly = 0x7a; // value byte, then a byte that says it was given
constexpr size_t kNodeSize = 0x1c;
constexpr size_t kNodeDirection = 0xc;    // three floats
constexpr size_t kSubStation = 0x28;      // the station's terminals: a vector (begin, end, capacity)
constexpr size_t kTerminalSize = 0x98;
constexpr size_t kTerminalVehicleNode = 0x30;   // two ints: lane list, node (both -1 when there is none)
constexpr size_t kSubDepot = 0x80;
constexpr size_t kDepotPresent = 0x78;    // byte, inside the depot's own 0x80 bytes
constexpr size_t kDepotIn = 0x18;         // vectors of two-int pairs (lane list, node)
constexpr size_t kDepotOut = 0x30;
constexpr int kFirstRoadMode = 2;         // CAR .. ELECTRIC_TRAM (TransportMode 2 .. 6)
constexpr int kLastRoadMode = 6;

struct TurnedParts {
    int lists = 0;   // lane lists turned
    int stops = 0;   // stops and depot ways that follow them
};

// One part of a construction, after the engine has read it: turns its road lane lists and what names their nodes.
// `sub` is the part's structure. Every pointer is checked before it is followed; a part that does not look as
// expected is left alone. Pure apart from the memory it is given (tested outside the game).
TurnedParts TurnSubconstruction(uint8_t* sub);


constexpr size_t kLaneSize = 0x18;
constexpr size_t kForwardOffset = 0xc;
constexpr size_t kModesOffset = 0x10;
constexpr uint32_t kRoadModes = 0x7c;   // CAR, BUS, TRUCK, TRAM, ELECTRIC_TRAM (TransportMode bits 2 .. 6)

// Turns the road lanes of a two-way street type. lanes: `count` lanes of kLaneSize bytes. Returns true when the
// type was two-way and its lanes were turned. Pure: no engine calls (tested outside the game).
bool TurnLanes(uint8_t* lanes, size_t count);

// Left-hand traffic applies to a game only while the TF3OpenAPI left-hand traffic mod is enabled in it. The mod says so
// (SetActive, through the script bridge: from its run script and, every few seconds, from its game script); the
// engine's start of loading a game (the menu's PreLoadAsync) puts it back, so a save without the mod is never touched,
// whatever was played before it in the same run of the game.
void SetActive(bool on);
bool Active();
// True when the native hooks are in place (the mod uses its own script rules for buildings when they are not).
bool Available();

void Install();
void Uninstall();

} // namespace tf3api::driving_side
