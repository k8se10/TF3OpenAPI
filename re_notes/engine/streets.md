# Streets, lanes and the road network

**Status: in progress (first pass, 2026-10-13).** Build 40408, static analysis. Function names are the
engine's own, recovered from its assertions (`assert_names_40408.tsv`); addresses are in that build.
"Read" means the decompiled function was gone through; "named only" means its role is taken from its name
and asserted conditions and has still to be read.

## The pieces, and who calls whom

```
street type (.street_template.lua)
   └─ Lua converter 0x140bba2f0 reads laneConfigs, busAndTramRight ...        [converter.h]
        └─ StreetTemplateRep (0x1425ecd70 ctor, FindMostSimilar 0x1425ed8c0)   [StreetTemplateRep.cpp]

a build is applied: construction_builder_util::Apply 0x1409f96e0               [apply_proposal.cpp]
   ├─ street_util::GetBusStopsLeftRight 0x14265b1b0                            [street_util.cpp]
   └─ street_util::ConstructTransportNetwork 0x14260c2b0                       [construction_util_network.cpp]
        (called through SubconstructionIndexToEntity 0x140a06cd0)

geometry of one street piece and its ends: StreetGeometry::Generate 0x1426c1310 [generation_util.cpp]
   ├─ along a piece:  CreateSplineConnection 0x1426c40a0 -> CreateLanes 0x1426b7ff0
   └─ at a node:      Crossing / Link (MakeLinkResult 0x1426afc70) / Curve / End
                         -> CreateLanesNode 0x1426b8f10                        [Transitions/lanes_util.cpp]
                              ├─ lane joining: 0x1426b42c0 -> 0x1426b5220 (three-arm patterns)
                              │     -> MakeRoundabout 0x1426b5490, ConnectDirectedLanesEvenly 0x1426b3500,
                              │        BestMatchingStreets 0x1426b3390          [lane_connection_util.cpp]
                              ├─ priority: Preference2Precedence 0x1426bc360
                              ├─ traffic lights: ComputeTrafficLightLaneConfig 0x1426b71a0,
                              │                  CrossroadData2TrafficLightData 0x1426bb790
                              └─ pavements: CreateSidewalkEdges 0x1426ba9d0
painted arrows: GroundArrowShapes 0x1426c5890                                  [spline_connector.cpp]

the network as the simulation holds it: ecs::TransportNetworkSystem            [TransportNetworkSystem.cpp]
   EntityAdded 0x140b6e6a0, MakeTpNetData 0x140b707e0, UpdateCacheForConnectedEdges 0x140b713e0,
   IsValidTransition 0x140b704b0; transport::TransportNetworkConstructor (AddNode, AddEdge,
   CreateTransportNetwork 0x14257e050); lane_util::GetTurnaroundEdgeIndex 0x1425a0580,
   FindEdgeAtInteriorNode 0x1425a00c0
streets as entities: ecs::StreetSystem (node-to-edge map, 0x140b51620 ...)      [StreetSystem.cpp]
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

4. **Junctions with three arms** (`0x1426b5220`, read): three patterns are tried in turn, each found by a
   test of its own over the arms' lanes (`0x1426b4e20` with three different tests) and each yielding
   which arm is which plus one yes/no value; the first is the roundabout (`MakeRoundabout`), tried only
   when none of the three arms carries the flag at +0x91 of its context. `MakeRoundabout` asserts that the
   two ring arms have the same number of lanes, more than one in all, and that at least one lane goes
   into the third arm; the yes/no value decides from which kerb the lanes are counted. **Open: what the
   three tests are and where that yes/no value comes from** (the arms' geometry, their lanes' directions,
   or a fixed side). This is the one place found so far that could carry an assumption about the side.

5. **Priority at a junction** (`StreetGeometry::Preference2Precedence`, read): an arm's setting at +0x94
   of its context decides - 0 gives it priority outright; otherwise, among the arms that carry vehicle
   lanes, a single arm marked at +0x90 has priority; with two marked arms of a three-arm junction the
   decision is by the angles between the arms. No rule of the "give way to the right" kind is in it.

6. **Traffic lights** follow the lanes: the game's own light script works the side out from which lanes
   need a light (see `re_notes/left_hand_traffic/reference.md`); in the engine,
   `ComputeTrafficLightLaneConfig` and `CrossroadData2TrafficLightData` prepare that per-lane data
   (named only).

## Still to be read (in this order)

- `0x1426b4e20` and its three tests; `0x1426b42c0` (the lane joining of a node as a whole);
  `ConnectDirectedLanesEvenly`. Settles point 4.
- `CreateLanes` and `CreateLanesNode` in full: how lane curves are laid across a piece and through a node,
  including turning lanes and U-turns (`turnaroundEdges`).
- `street_util::ConstructTransportNetwork`, `TransportNetworkSystem::EntityAdded`, `MakeTpNetData`: what
  the network holds per edge, and - the question a change of lanes on an existing save turns on - whether
  it is written to the save or made again when a street entity is added at load.
- The street type's converter `0x140bba2f0`: the full layout of a street type in memory, and every reader
  of `busAndTramRight`.
- `GroundArrowShapes`: how painted arrows choose their lane and direction.
