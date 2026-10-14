# Road traffic and route finding - review and improvements (build 40420, 2026-10-14)

Asked for (user, 2026-10-14): "a full ai traffic and pathfinding review and look for needed improvements";
before that: road vehicles do not change lanes properly ("buses stopping left yet having to take a whole
different route to turn right instead of changing lanes"), rarely overtake slower vehicles, do not pass
stopped buses. Status words: **read** = decompiled and followed; **named** = known from the function's
assertion texts only; **inferred** = my reading of what the code implies, not yet seen in the game.
Companion notes: `navigation.md` (path search in general), `streets.md` (lanes), and
`re_notes/left_hand_traffic/saves.md` (driving side).

## How a road vehicle moves today

1. **Route.** A vehicle's route is a list of directed lane edges (`MovePath.path.edges`, each an edge of a
   transport network and a direction). Every lane of a street is its own edge; lanes are joined to other
   lanes only at the street's nodes - the junction lanes made by `StreetGeometry::CreateLanesNode` - and to
   the parallel lanes of the next edge of the same street (below). So the route search works on lanes, and a
   lane change is a junction-to-junction choice. (read: `streets.md`; the edge layout below)
2. **Lane choice, only where one edge meets the next.** Each frame, for the next edges ahead,
   `LandVehicleMoveSystem::Update2` (`0x140ac2240`, the per-vehicle part `<lambda_3>` at `0x140ab9f50`)
   asks `GetNextEdgeTrafficPenaltyAndAlternatives` (`0x140ac01d0`) for the penalty of the planned next lane
   and for the parallel lanes of the same street's next edge (`switchIndices`; a lane switch is marked 1 or 2
   for the indicator side). For each alternative it computes a penalty (`0x140abf500`); if one is lower than
   the planned lane's, it searches a short route from that lane back onto the planned route
   (`transport::path_finder::FindSimplePath`, `PathFinder<DirEdgeOptimized, DefaultMultiHeuristic>`) within
   **300 m** and splices it in. (read)
3. **The penalty** (`0x140abf500`, read; constants from `.rdata`):
   - the vehicle ahead in that lane (`EdgeUseManager`), looked for up to **60 m** ahead;
   - no penalty when it is at least **0.9x** the speed this vehicle wants, or when it is more than **30 m**
     away in some cases;
   - otherwise a penalty that grows with the speed difference and with how near it is
     (`(dv * 0.5 ... ) * (1 - gap / 60)`), plus a fixed cost for switching: **5.56** (one side) or
     **10.56** (the other side), in m/s;
   - `-1` (not allowed) for a switch in some states.
   The speed this vehicle wants is the lower of its own top speed and the edge's limits (+0x54 / +0x58 of the
   0x70-byte edge).
4. **Following and occupancy.** `transport::EdgeUseManager` (`EdgeUseManager.cpp`, named / partly read)
   keeps, per lane edge, the vehicles on it as ranges; `GetNext` finds the vehicle ahead; `SetPortLocked`
   locks a junction entry. Junction priority (`streets.md` point 5) and traffic lights
   (`TrafficLightSystem`, which can skip phases with nobody waiting: `NonPauseStateCanBeSkipped`,
   `PauseCanBeSkipped`) decide who enters a junction. (named)
5. **Stops.** A kerb stop is tied to the outermost lane (`streets.md` point 2); a bus stopping there stands
   in that lane, and the lane is occupied until it leaves. (read for the tie; inferred for the blocking)
6. **Saved state.** Routes and positions are saved with the lane edges they refer to, and networks are saved
   with their geometry (`re_notes/left_hand_traffic/saves.md`). (read)

## Why the user sees what they see

| Seen | Cause (inferred from the above) |
|---|---|
| A bus at a kerb stop takes another route to turn right | It can only change lane where an edge ends. If the stop's edge runs up to the junction, the kerb lane's only exits are that lane's turns; the route search, working on lanes, finds the right turn reachable only by going round. |
| Vehicles rarely overtake | Lane changes happen only at edge ends, the vehicle ahead is looked for only 60 m ahead, and a vehicle at 90% of the wanted speed does not count as slow. On a long edge a car stays behind until the edge ends. |
| Traffic waits behind a stopped bus | A stopped bus is a slow vehicle ahead like any other, so the same rule applies: the queue can only move out at the next edge end, and the queue is often already past it. |
| Long, odd detours | The route search for vehicles is plain Dijkstra over lane edges (`ZeroHeuristic`, `navigation.md`), costs by travel time; a lane-change need becomes a route choice. |

## Improvements, ranked

1. **Lane changes along an edge.** Let a vehicle move to a parallel lane of the same edge (same street,
   same direction) anywhere along it: a lateral move over a short distance, occupying both lanes while it
   changes (`EdgeUseManager::AddRange` on both), accepted only with a gap ahead and behind in the target lane.
   Triggers: (a) the planned turn at the next junction needs another lane - change early, at a distance that
   depends on speed; (b) a slower or stopped vehicle ahead (the penalty above, evaluated along the edge, not
   only at its end); (c) pulling out of a kerb stop and back in after passing it. This is the core fix for all
   three complaints. Needs: a lane-change state in the move path (from-lane, to-lane, progress), drawing the
   vehicle between lanes, and the path splice already used at edge ends. (to design after reading
   `Update2` in full and the move path layout)
2. **Route search that knows lanes can be changed.** Join the parallel lanes of each edge in the search
   graph with a lane-change cost, instead of only at nodes, so a route is no longer forced into a detour by
   the lane a vehicle happens to start in; then the movement carries out the change (1). (`FindPathUnified`
   / `TransportModeExpander`, to read)
3. **Overtaking rules as settings.** The look-ahead (60 m), the "slow" threshold (0.9x), the 30 m cut-off and
   the switch costs (5.56 / 10.56) are constants. Raising the look-ahead and lowering the threshold already
   makes vehicles leave a slow lane sooner where lanes allow it; with (1) it works along the whole edge.
   Smallest change, measurable alone; a first step.
4. **Overtaking on two-way roads with one lane each way** (using the oncoming lane when it is clear). Needs
   the oncoming lane's occupancy ahead and a safe-return rule; later, after (1).
5. **Bus stops.** Stop bays (a stop beside the lane, not in it) where a street type has room, so a stopped bus
   leaves the lane free; until then, (1)(c).
6. **Route search cost.** Vehicles' search is Dijkstra without a heuristic; an admissible heuristic (straight
   distance over top speed) finds the same routes with fewer edges looked at. A CPU gain, results unchanged
   (`navigation.md`).
7. **Left-hand traffic** builds on (1) and (2): lane choice and turns follow the driving side
   (`re_notes/left_hand_traffic/saves.md`).

All but (6) change how vehicles drive, so they are per-save options the player chooses, not defaults: the
project's rule that simulation results stay as the game makes them holds unless the player asks.

## To read before building (1) and (2)

- `LandVehicleMoveSystem::Update2` (`0x140ac2240`, 12 KB) in full: the move path layout (`dyn.pathPos`,
  `dyn0`, `reservedFrom/To`), how a position on an edge becomes a place in the world, where the vehicle ahead
  slows this one.
- `EdgeUseManager::GetNext` (`0x1425632b0`), `AddRange` (`0x1425603c0`), `SetPortLocked` (`0x1425650a0`).
- The road route search entry for vehicles (the address in `navigation.md` points at an air-vehicle
  function on 40420: re-find `FindPathUnified` by its assertion texts) and `TransportModeExpander`.
- How a vehicle is drawn along its lane (lateral offset of a lane edge's shape), for drawing a change.
