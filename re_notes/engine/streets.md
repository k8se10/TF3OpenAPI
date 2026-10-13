# Streets, lanes and the road network

**Status: in progress (first pass, 2026-10-13).** Build 40420, static analysis. Function names are the
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

## What is established

1. **A lane setting is 0x18 bytes** in the engine: the direction flag (`forward`) is the byte at +0x0c and
   the transport modes are a bit set at +0x10. A lane counts as a vehicle lane when its mode set is not
   empty and its lowest bit is clear (the lowest bit is the pedestrian mode). (Read:
   `StreetGeometry::CalcLaneFromEdgeIndex`, `MakeRoundabout`.)

2. **Things placed on a street piece** are a list of 8-byte entries `{ id, type }` at +0x40 of the piece's
   data, with types 0 = stop on the left, 1 = stop on the right, 2 = signal. A piece has at most one stop
   on each side (asserted in `street_util::GetBusStopsLeftRight`, read). **So a kerb-side stop is stored
   by the side of the street it is on, counted along the piece's own direction - not by the direction of
   travel.** Turning the lanes leaves every existing stop on its kerb; the stop then serves the lane that
   now runs along that kerb.

3. **Which lane a network edge belongs to** (`StreetGeometry::CalcLaneFromEdgeIndex(edge, laneConfigs,
   tnEdgeIndex)`, read in part): the function first works out whether all vehicle lanes run the same way
   (a one-way street), then whether a stop splits the lanes on the left and on the right (`splitLeft`,
   `splitRight`; a piece with signals may have neither), and maps the network's edge number to a lane
   number from that, starting at `firstRightLaneIndex`. Nothing in it fixes a side of the road: it reads
   each lane's own direction flag.

4. **Junctions with three arms** (`0x1426b85a0`, read): three patterns are tried in turn, each found by a
   test of its own over the arms' lanes (`0x1426b81a0` with three different tests) and each yielding
   which arm is which plus one yes/no value; the first is the roundabout (`MakeRoundabout`), tried only
   when none of the three arms carries the flag at +0x91 of its context. `MakeRoundabout` asserts that the
   two ring arms have the same number of lanes, more than one in all, and that at least one lane goes
   into the third arm; the yes/no value decides from which kerb the lanes are counted.
   **Where that value comes from (matcher `0x1426b81a0`, read):** the matcher goes through the three arms
   in turn. For an arm that has vehicle lanes with the direction flag clear, it looks at each of the two
   other arms that has vehicle lanes with the flag set, asks the pattern's own test, and among the
   candidates keeps the pair whose two arms are most nearly opposite each other (smallest difference of
   their angle from a straight line). The yes/no value is simply whether the remaining arm is the next or
   the one before in the order of the arms round the node. So it comes from the lanes' own direction flags
   and the arms' angles: **there is no fixed side in it.** With every vehicle lane turned, the same
   matcher finds the mirror-image flow.

5. **Priority at a junction** (`StreetGeometry::Preference2Precedence`, read): an arm's setting at +0x94
   of its context decides - 0 gives it priority outright; otherwise, among the arms that carry vehicle
   lanes, a single arm marked at +0x90 has priority; with two marked arms of a three-arm junction the
   decision is by the angles between the arms. No rule of the "give way to the right" kind is in it.

6. **Traffic lights** follow the lanes: the game's own light script works the side out from which lanes
   need a light (see `re_notes/left_hand_traffic/reference.md`); in the engine,
   `ComputeTrafficLightLaneConfig` and `CrossroadData2TrafficLightData` prepare that per-lane data
   (named only).

## Still to be read (in this order)

- `0x1426b81a0` and its three tests; `0x1426b7640` (the lane joining of a node as a whole);
  `ConnectDirectedLanesEvenly`. Settles point 4.
- `CreateLanes` and `CreateLanesNode` in full: how lane curves are laid across a piece and through a node,
  including turning lanes and U-turns (`turnaroundEdges`).
- `street_util::ConstructTransportNetwork`, `TransportNetworkSystem::EntityAdded`, `MakeTpNetData`: what
  the network holds per edge, and - the question a change of lanes on an existing save turns on - whether
  it is written to the save or made again when a street entity is added at load.
- The street type's converter `0x140bbab90`: the full layout of a street type in memory, and every reader
  of `busAndTramRight`.
- `GroundArrowShapes`: how painted arrows choose their lane and direction.
