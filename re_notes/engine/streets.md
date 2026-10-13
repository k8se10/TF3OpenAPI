# Streets, lanes and the road network

**Status: second pass (2026-10-13): the questions left-hand traffic turns on are answered; what is still unread is listed at the end.** Build 40420, static analysis. Function names are the
engine's own, recovered from its assertions (`assert_names_40420.tsv`); addresses are in that build.
"Read" means the decompiled function was gone through; "named only" means its role is taken from its name
and asserted conditions and has still to be read.

## The pieces, and who calls whom

```
street type (.street_template.lua)
   └─ Lua converter 0x140bbab90 reads laneConfigs, busAndTramRight ...        [converter.h]
        └─ StreetTemplateRep (0x1425f0270 ctor, FindMostSimilar 0x1425f0dc0)   [StreetTemplateRep.cpp]

a build is applied: construction_builder_util::Apply 0x1409fae80               [apply_proposal.cpp]
   ├─ street_util::GetBusStopsLeftRight 0x14265e610                            [street_util.cpp]
   └─ street_util::ConstructTransportNetwork 0x14260f7b0                       [construction_util_network.cpp]
        (called through SubconstructionIndexToEntity 0x140a083c0)

geometry of one street piece and its ends: StreetGeometry::Generate 0x1426c4690 [generation_util.cpp]
   ├─ along a piece:  CreateSplineConnection 0x1426c7420 -> CreateLanes 0x1426bb370
   └─ at a node:      Crossing / Link (MakeLinkResult 0x1426b2ff0) / Curve / End
                         -> CreateLanesNode 0x1426bc290                        [Transitions/lanes_util.cpp]
                              ├─ lane joining: 0x1426b7640 (called from PrepareLanes, StreetShapeFactory.cpp)
                              │     -> 0x1426b85a0 (three-arm patterns, matcher 0x1426b81a0)
                              │     -> MakeRoundabout 0x1426b8810, ConnectDirectedLanesEvenly 0x1426b6880,
                              │        BestMatchingStreets 0x1426b6710          [lane_connection_util.cpp]
                              ├─ priority: Preference2Precedence 0x1426bf6e0
                              ├─ traffic lights: ComputeTrafficLightLaneConfig 0x1426ba520,
                              │                  CrossroadData2TrafficLightData 0x1426beb10
                              └─ pavements: CreateSidewalkEdges 0x1426bdd50
painted arrows: GroundArrowShapes 0x1426c8c10                                  [spline_connector.cpp]

the network as the simulation holds it: ecs::TransportNetworkSystem            [TransportNetworkSystem.cpp]
   EntityAdded 0x140b6f000, MakeTpNetData 0x140b71140, UpdateCacheForConnectedEdges 0x140b71d40,
   IsValidTransition 0x140b70e10; transport::TransportNetworkConstructor (AddNode, AddEdge,
   CreateTransportNetwork 0x1425817a0); lane_util::GetTurnaroundEdgeIndex 0x1425a3b60,
   FindEdgeAtInteriorNode 0x1425a36a0
streets as entities: ecs::StreetSystem (node-to-edge map, 0x140b522e0 ...)      [StreetSystem.cpp]
```

## Layouts

**A lane setting** (`LaneConfig`, 0x18 bytes; read in `GetLaneOffset` `0x1426c5400` and five small helpers):

| Offset | Field | Notes |
| --- | --- | --- |
| +0x00 | speed | float |
| +0x04 | width | float |
| +0x08 | height | float |
| +0x0c | forward | one byte |
| +0x10 | transport modes | 32 bits, one a mode, in the order of the game's own list: 0 person, 1 cargo, 2 car, 3 bus, 4 truck, 5 tram, 6 electric tram, 7 train, 8 electric train, 9 aircraft, 10 ship, 11 small aircraft, 12 small ship, 13 helicopter, 14 tram track, 15 electric tram track |
| +0x14 | offset | float, sideways shift of the lane's line |

Masks the code uses: `0x7c` (car, bus, truck, tram, electric tram) = "a road vehicle lane"
(`0x1426c5cb0`); `0x1400` = ships; `0x2a00` = aircraft and helicopters; "a vehicle lane" = mode set not
empty and bit 0 clear (`0x1426c5be0`). "One-way" = every vehicle lane has the same `forward`
(`0x1426c5b20`).

**Things on a street piece** (`BaseEdge.objects`, read in `street_util::GetBusStopsLeftRight`
`0x14265e610`; the older game gives its signature: it takes a `const ecs::component::BaseEdge &` and
returns a pair of entities): 8-byte entries `{ entity, type }` at +0x40 of the piece, type 0 = stop on the
left, 1 = stop on the right, 2 = signal; at most one stop a side (asserted).

**An arm of a node** as the lane code sees it (`ConnectorContext`, 0x128 bytes): its lane settings at
+0x78, a priority mark at +0x90, a second mark at +0x91 (an arm with it is not tried as a roundabout arm),
its priority setting at +0x94.

## What is established

1. **Where a lane lies does not depend on its direction.** `StreetGeometry::GetLaneOffset(i, laneConfigs)`
   (`0x1426c5400`, read) is: half the sum of all widths, minus the widths of the lanes before `i`, minus
   half of lane `i`'s own width, plus lane `i`'s `offset`. Only the lane's place in the list and the
   widths enter. In `StreetGeometry::CreateLanes` (`0x1426bb370`, read in the parts that use the lane
   settings) a lane with `forward` clear is built on the piece's reversed point list with the sign of that
   offset turned - the same line, driven the other way. **So turning the `forward` flag of a lane turns
   the traffic on it and moves nothing.**

2. **Kerb-side stops belong to a kerb, not to a direction.** In `CreateLanes` a stop of type 0 is tied to
   the first lane of the list and to the lanes after it that run the same way as it; a stop of type 1 to
   the last lane and the lanes before it that run the same way; a signal (type 2) to the middle lane,
   and then the number of lanes must be odd (asserted). "Left" is the kerb where the lane list starts.
   A stop therefore stays on its kerb whatever the lanes do, and serves the lanes on its side.

3. **Which lane a network edge belongs to** (`StreetGeometry::CalcLaneFromEdgeIndex`, `0x1426c4b70`): from
   whether the street is one-way, whether a stop splits the lanes on either side (`splitLeft`,
   `splitRight`), and the edge's number, starting at `firstRightLaneIndex`. It reads each lane's own flag.

4. **Three-arm junctions, the roundabout among them** (`0x1426b85a0`, matcher `0x1426b81a0`, both read;
   called from the lane joining `0x1426b7640`, which `PrepareLanes` in `StreetShapeFactory.cpp` calls):
   the matcher goes through the arms; for an arm with vehicle lanes whose flag is clear it looks at each
   other arm with vehicle lanes whose flag is set, asks the pattern's own test, and keeps the pair of arms
   most nearly opposite each other. The yes/no value that `MakeRoundabout` (`0x1426b8810`) uses to decide
   from which kerb lanes are counted is whether the remaining arm is next or previous in the order of
   the arms round the node. It comes from the lanes' flags and the arms' angles. **There is no fixed side
   in it**: with every vehicle lane turned, the same code finds the mirror-image flow.

5. **Priority at a junction** (`StreetGeometry::Preference2Precedence`, `0x1426bf6e0`, read): an arm's
   setting decides - 0 gives it priority outright; otherwise among the arms with vehicle lanes a single
   marked arm has priority, and with two marked arms of a three-arm junction the angles decide. No "give
   way to one side" rule.

6. **The network is stored in the save, not made again at load.** The component that holds a street's or
   a building's lanes (`ecs::component::TransportNetwork`) has a loader of its own
   (`ecs::ComponentManager::Load` for that type, `0x14019b510`; found by which named functions refer to
   the type's `type_info`, `tools/ghidra/who_uses_type.py`), and the only code that builds one,
   `construction_builder_util::ConstructTransportNetwork` (`0x140a083c0`), is reached from applying a
   build (`construction_builder_util::Apply`, `0x1409fae80`) and nowhere else. It calls
   `street_util::ConstructTransportNetwork` (`0x14260f7b0`, lanes of streets and tracks),
   `street_util::CreateTransportNetwork` (`0x1425f6950`) and
   `transport::TransportNetworkConstructor::CreateTransportNetwork` (`0x1425817a0`, four call sites: the
   lane lists of a construction). **Consequence: what a street type or a building's script says about
   lanes matters when the thing is built or rebuilt; a street already in a save keeps the lanes it was
   built with, whatever mods are active when the save is loaded.** `street_util::UpdateEngine`
   (`0x1425fe7b0`) also refers to the component (with a `RemoveFromEngine` beside it): the route by which
   an existing street's network is replaced (an upgrade, a change of type); not read yet.
   The load path does touch stored networks in one place: `GameStateLegacyHandler::MakePreProcFn`
   (two of its steps refer to the component) - repairs for saves of older versions; not read yet.

7. **Traffic lights** follow the lanes: the game's own light script works the side out from which lanes
   need a light (`re_notes/left_hand_traffic/reference.md`); in the engine `ComputeTrafficLightLaneConfig`
   (`0x1426ba520`) and `CrossroadData2TrafficLightData` prepare that per-lane data (named only).

8. **`busAndTramRight`** is a field of a street type that both games' executables know; the reader of a
   street type is `Converter<StreetTemplate>` (`0x140bbab90`). None of the newer game's 81 street types
   sets it. Where the engine uses it has not been found (by its name: on which side of a street the
   lane for buses and trams is put when a street is given one).

## What left-hand traffic must and must not touch

- **Must:** the `forward` flag of the road-vehicle lanes of two-way street types (point 1); the lane lists
  of buildings, which are fixed lines with a direction (stations, depots, industries' yards); one-way
  streets that a construction lays (their direction is the direction they are drawn in); the vehicles.
- **Need not:** stops on streets (point 2), junction lane joining and roundabouts (point 4), priority
  (point 5), traffic lights (point 7), lane positions (point 1).
- **Existing saves (point 6):** a save's streets and buildings carry the lanes they were built with. A
  save made with one left-hand-traffic mod stays left-hand under another, or under none, for everything
  already built; only what is built or rebuilt afterwards follows the mod then active. So changing mods
  cannot put a vehicle on a turned lane, and no reset of vehicles or people is needed for it. The other
  side of the same fact: switching an existing right-hand save to left-hand traffic does nothing to the
  roads already there - that would need every street and building rebuilt through the game's own
  update route (`street_util::UpdateEngine` and the construction update), which is where a reset would
  come in.

## Still unread

- `StreetGeometry::CreateLanesNode` (`0x1426bc290`) in full: turning lanes, U-turns (`turnaroundEdges`),
  how lane counts that do not match are joined (`ConnectDirectedLanesEvenly`, `0x1426b6880`).
- What a network edge holds (`transport::Edge`: ends, geometry, modes, speed) and `MakeTpNetData`
  (`0x140b71140`); `TransportNetworkSystem::EntityAdded` (`0x140b6f000`): links between networks.
- `street_util::UpdateEngine`, and the legacy steps at load that touch networks.
- `GroundArrowShapes` (`0x1426c8c10`): painted arrows.
- Where `busAndTramRight` is used.
