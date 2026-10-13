# Navigation and path finding

**Status: in progress (first pass, 2026-10-13).** Build 40420, static analysis. Names are the engine's own
(`local/assert_names_40420.tsv`). "Read" = the decompiled function was gone through; everything else is taken
from names, asserted conditions and who calls whom, and has still to be read.

## The graph

- Every street, track or construction that can be travelled is an entity with a **transport network**
  (`component::TransportNetwork`: `nodes`, `edges`, `turnaroundEdges` - for each edge the first edge on the
  opposite lane). An edge is addressed as `EdgeId { entity, index }`, a direction as `{ EdgeId, bool }`.
  Built by `transport::TransportNetworkConstructor` and `ecs::TransportNetworkSystem` (`EntityAdded`,
  `MakeTpNetData`, `UpdateCacheForConnectedEdges`, `IsValidTransition`).
- Networks of different entities are joined by **links** (`ecs::TpNetLinkSystem`; a link has `from.edgeId`
  and `to.edgeId` in different entities - asserted). Walking paths cross links; a link sits at a
  parameter along an edge, which cuts the edge into **edge parts** (`transport::GetLinkParam`,
  `GetEdgePartForParam`, `IsEdgePart`).
- A found path is a `Path` (list of directed edges) for vehicles and an `ExtPath` for people: ranges of
  edges plus link edges, made by `transport::MakeExtPath` (`0x1425a1fb0`).

## The search

One search template serves everything: `transport::PathFinder<Segment, Heuristic>` (`PathFinder.h`), with
`InsertSeg`, `EraseFromPriorityList`, `PrioritySearch`. It asserts `ss.SumD() >= m_curDepth` on insert: a
label-setting search in which costs never go down (Dijkstra's order). What differs per use:

| What is searched | Segment type | Heuristic | Expander (what the neighbours of a segment are) |
| --- | --- | --- | --- |
| a vehicle to its next stop or depot | `{ EdgeId, bool }` | **`ZeroHeuristic`** (none) | `TransportModeExpander` (`pathfinder_util.h`: speed limits, switches, `GetTurnaroundEdgeIndex`) |
| a person driving a private car | `DirEdgeOptimized` | `LandmarkHeuristic` or `DefaultMultiHeuristic` | `CachedDriveExpander` (`DriveExpanderCache`) |
| a person walking | `LinkPathSeg` | `ZeroHeuristic` | `LinkPathExpander` / `LinkGraphPathExpander` |
| a person using lines | `LineSectionOptimized` | `ZeroHeuristic` | `LinesExpander` (`VisitLines`, `AddStation`; cache `m_station2stationsAndDistances`) |
| town set-up (streets, connections) | `ecs::Entity` | `ZeroHeuristic` | `init_streets_util`, `town_connection_util::Compute` |
| ships | grid cells (`AStar<CVec2i>`) | A* with turning costs (`AStarAngleCosts`) | `pathfinder_water::FindPath`, `FindPathOversea`, then `GetSmoothedEdges` |

`LandmarkHeuristic` works from distances stored for landmarks (`m_landmark2targetDistances`;
`ecs::LandmarkSystem::GetEntityLandmarkEdges`): the known way of bounding the remaining distance by
distances to a few fixed points of the graph.

Callers:

- Vehicles: `vehicle_util::common::FindPathUnified` (`0x14266f670`, `0x14266fba0`) and `FindPathToStop2`
  (`0x142674cb0`) in `transport_vehicle_util_path_common.cpp`; lines' previews through
  `line_util::MakeExpanderTransportVehicles`.
- People and cargo: `PathFactory::Compute` (`0x1408d3170`, read), called from the system that queues
  entities needing a path (`ecs::SimEntityNeedsPathSystem`).

## How a person's journey is chosen (`PathFactory::Compute`, read)

1. The input is a list of requests (0xe0 bytes each: origin, destination, the person's per-mode weights
   at +0x78).
2. For every request **three candidate journeys** are worked out, one per mode (0x40 bytes each). The
   work is handed to the engine's thread pool as `3 x requests` independent pieces
   (`ThreadPool::LoopImpl`), each calling the search for its mode: `FindPathLines` (walk + lines,
   `0x140947a40`), `FindSimplePath` with the landmark heuristic (car), and walking (`FindPathWalkLINK`).
3. Back on the calling thread, each request takes the candidate with the smallest
   `cost x the person's weight for that mode`; at least one candidate must exist (asserted).

So destination and mode choice are computed in parallel already; a person's preference is a multiplier
per mode on the journey's cost.

## Occupancy

`transport::EdgeUseManager` keeps, per edge, the vehicles on it as intervals (`Add`, `AddRange`, `GetNext`
- the next vehicle ahead, `SetPortLocked` - junction ports locked with a count), which is what road
vehicles look at to follow and queue. `transport::EdgeReservationManager` (`Reserve`, `Release`) is the
block reservation of rail. `ecs::LandVehicleMoveSystem` (9 named functions, the biggest 12 KB) moves the
vehicles; not read yet.

## Where it could be improved (leads, to be confirmed by reading and by measurement)

1. **Vehicle route search has no heuristic** (`ZeroHeuristic`): every route to a next stop is a
   Dijkstra search that spreads in all directions, while people's car trips already use landmarks. Giving
   vehicles a distance bound (even the straight-line one) would cut the edges visited on long routes.
   To settle first: how often vehicles search (per stop? on every network change?), and whether results
   are cached.
2. **The `3 x requests` loop** is parallel, but what limits how many requests are served per step, and
   whether the main thread waits for the pool, is not read. The low processor use players report at low
   frame rates points at waiting somewhere; this loop and its caller are the first place to look.
3. **Invalidation**: what is thrown away when a street changes (`UpdateCacheForConnectedEdges`,
   `DriveExpanderCache`, the lines' station cache). A whole-map invalidation on a small edit would
   explain hitches while building.
4. **Vehicle following** (`EdgeUseManager::GetNext`, port locks) is where lane changing, overtaking and
   junction blocking would be changed; nothing can be said before `LandVehicleMoveSystem` is read.

## Still to be read

`TransportModeExpander::operator ()` (0x1405a8a70, 3 KB); `FindPathUnified`, `FindPathToStop2`;
`ecs::SimEntityNeedsPathSystem` (its update and budget); `FindPathLines`; `LandmarkHeuristic`;
`LandVehicleMoveSystem`; `EdgeUseManager::GetNext` and `SetPortLocked`; `TransportNetworkSystem`
(what is rebuilt on a change).
