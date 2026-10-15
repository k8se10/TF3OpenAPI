# Left-hand traffic in the engine: what is built, how it was found, what is left (2026-10-15, build 40420)

**Superseded in part: the driving side is now a property of the save, kept by an always-on guard - see `save_guard.md`. The two hooks below are
still the native half; the street hook is off by default (the guard turns street types), and the part hook turns a building only when the
guard has said that the game's side differs from the data's.**

Requirement (user, 2026-10-14): native to the engine - the engine itself keeps left on two-way roads, markings, arrows, stops and
lights following, one-way roads unchanged; not a save conversion, not a data patch per mod. Built as a hook on the two places where
the engine turns a script's Lua tables into its own structures (`native/src/driving_side.{h,cpp}`, `[LeftHandTraffic] Enabled=1`, off by
default). Status words: **read** = decompiled and followed; **built** = in the DLL and tested outside the game with memory laid out as
read; **unseen** = not yet tried in the game.

## 1. Street types (read, built, unseen)

`Converter<StreetTemplate>::operator()` at `0x140bbab90` (signature in `driving_side.cpp`, unique on 40420) turns a street type's Lua
table into a `StreetTemplate`. Its lane list is a vector at `+0x60` (begin, end, capacity) of 0x18-byte lanes (read by the per-lane
converter `0x140bba430`): `+0x00` speed, `+0x04` width, `+0x08` height, **`+0x0c` `forward` byte**, `+0x10` transport-mode mask (bit order
= `TransportMode`: PERSON 0, CARGO 1, CAR 2, BUS 3, TRUCK 4, TRAM 5, ELECTRIC_TRAM 6, ...; road vehicles = `0x7c`), `+0x14` offset.
`busAndTramRight` is the byte at `+0x7f`. The lanes are listed kerb to kerb and `GetLaneOffset` uses only list position, widths and the
lane's own offset (`streets.md`), so turning every road lane's `forward` of a two-way type moves traffic to the other side without moving
a lane; `busAndTramRight` is set to false as the other left-hand mods do. A type is two-way when its road lanes run both ways; one-way types,
sidewalks and rails are left alone. Rule: `TurnLanes` (tests: `tools/tests/driving_side_test.cpp`).

## 2. Buildings (read, built, unseen)

The converter of a construction's part (a "subconstruction": a station, a depot, a yard...) is `0x142c1e910` (unique signature). Its output
(from the order in which it reads the keys, all offsets read from the converter and the per-key readers):

| where | what |
|---|---|
| `+0x28` | the station's terminals: vector (begin, end, capacity) of 0x98-byte terminals (`0x142c1eb70`); a terminal's `vehicleNode` = two ints (lane list, node) at `+0x30` (-1, -1 when none), `vehicleEdges` vector at `+0x38` |
| `+0x80` | the depot (optional, present byte at depot `+0x78`): transport modes vector `+0x00`, `inNodes` vector of (list, node) int pairs at `+0x18`, `outNodes` at `+0x30` |
| `+0x158` | `laneLists`: vector of 0x80-byte lane lists (converter `0x142c21360`): `+0x00` transf, **`+0x40` transport modes (vector of ints)**, `+0x58` speed limit, **`+0x60` nodes (vector, 0x1c bytes a node: position, direction, width)**, `+0x78` linkable, `+0x79` pedestrian penalty, **`+0x7a` forwardOnly (value byte, given byte)**, `+0x7c` needsReservation |

After the converter returns, every lane list whose modes are all road vehicles (2 .. 6) and whose nodes come in whole pairs is turned: each
pair swaps places and both directions are negated (a node numbered n is afterwards n ^ 1), `forwardOnly` set. Things that name nodes
follow: a terminal's `vehicleNode` node ^ 1 when its list was turned; a depot's `inNodes` and `outNodes` change places (vector headers
swapped) and their nodes ^ 1 when every one of them is on a turned list. This is the rule of the script mod's `core.construction`, which
was tested outside the game first and now is the engine's own. `vehicleEdges` (pairs of list and edge) need no change: pieces keep their
places in the list. Rule: `TurnSubconstruction` (tests on synthetic memory in the layout above).

Why both hooks or none: streets turned without the buildings' lanes (or the reverse) leave vehicles unable to get from a building onto a
street, so the DLL installs both or neither.

## 3. Saves (read earlier, `saves.md`)

Networks are saved as built, so nothing changes in a save by loading: streets and buildings already in it keep the side they were made
with. With `[LeftHandTraffic]` on, only what is built or rebuilt afterwards is left-hand. A save made with the other left-hand mod
(`left_hand_traffic_1`) is already left-hand: **that mod must be off when this is on**, or new streets and buildings are turned twice
(back to right-hand). A right-hand save becomes mixed. A per-save switch (saved with the game) is still to be made.

## 4. Not done

1. **One-way streets that a construction lays itself** (a roundabout, interchange ramps): the construction result's `edgeLists`
   (converter `0x142c1e1d0`: `edgeType` int `+0x00`, `edgeTypeName` string `+0x08`, edges vector of 6-float pairs `+0x98`, `snapNodes` `+0xb0`,
   `freeNodes` `+0xc8`, traffic-light vector `+0xe0`, `tag2nodes` `+0xf8`) are drawn for right-hand traffic: a roundabout circulates the
   wrong way. The script rule (`core.edgeLists`) turns each piece of a one-way list and renumbers what names its nodes; natively it needs to know
   whether the street type is one-way by its name. Street types live in `ResTypeRep<StreetTemplate,int>` (entries of 0x50 bytes, name at `+0x30`,
   value at `+0x40`; `Load` `0x14013a0a0`): the open question is how to reach the rep from the hook.
2. **Vehicles**: doors, driver seat, indicators and labels of the vehicle models (`core.mirrorVehicle`, `core.mirrorLabel` in the script mod,
   tested outside the game, not wired); native route: the model loader.
3. **Lane changes along a road and overtaking** (`saves.md` design direction 3 and 4): the movement system.
4. **Existing right-hand saves** converted as a whole, and the per-save setting.

## 5. How to try it (in the game)

Set `[LeftHandTraffic] Enabled=1` in `tf3api.ini`, **disable `left_hand_traffic_1`**, start a NEW map (or a copy of a save). Look for the
log lines `driving side: left-hand traffic is on ...` and `driving side: N two-way street types turned ...`, `construction parts turned`.
Expect: new two-way streets drive on the left; new bus / tram / train stations and depots work with their lanes turned (stops on the
right kerb for the left-hand side, since the buildings' own geometry is not mirrored); roundabouts and one-way ramps circulate the wrong
way (section 4.1); vehicles keep their right-hand doors.
