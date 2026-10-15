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
// Buildings' own lanes (stations, depots, industries) are not touched by this module.
namespace tf3api::driving_side {

constexpr size_t kLaneSize = 0x18;
constexpr size_t kForwardOffset = 0xc;
constexpr size_t kModesOffset = 0x10;
constexpr uint32_t kRoadModes = 0x7c;   // CAR, BUS, TRUCK, TRAM, ELECTRIC_TRAM (TransportMode bits 2 .. 6)

// Turns the road lanes of a two-way street type. lanes: `count` lanes of kLaneSize bytes. Returns true when the
// type was two-way and its lanes were turned. Pure: no engine calls (tested outside the game).
bool TurnLanes(uint8_t* lanes, size_t count);

void Install();
void Uninstall();

} // namespace tf3api::driving_side
