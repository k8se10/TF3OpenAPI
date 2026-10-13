# The engine, end to end: how it is being learned

Started 2026-10-13. The aim is to know how the game's engine works as a whole, system by system, and to
write each system up as it is understood - not only the corner a feature happens to need. Features are then
built on that knowledge instead of on trial in the game.

## What makes this tractable

The executable was built with its assertions left in. Every assertion carries four things as plain text:
the condition that must hold, the source file, the line, and **the full name of the function it is in**
(`StreetGeometry::CalcLaneFromEdgeIndex`, `ecs::TransportNetworkSystem::EntityAdded`, ...). The conditions
are written in the original variable and field names (`edge.conns[0] != edge.conns[1]`,
`numSignals == 0 || (splitLeft == 0 && splitRight == 0)`), so they also name what the data is.

Collected from build 40408 with two small Ghidra scripts (static analysis only):

| File | What it holds |
| --- | --- |
| `source_map.md` | the engine's source tree as the executable names it: 893 files in 95 folders (build 40420) |
| `assert_names_40408.tsv` | 10,981 assertion sites: function address, size, **real function name**, source file, line, condition. 5,767 functions, 3,786 distinct names |
| `functions_by_source_40408.tsv` | 7,701 functions tied to the source file they refer to (covers functions whose assertion form the first script does not read) |

A name found this way belongs to the code the assertion was written in. Where the compiler put a small
function inside a bigger one, the bigger function shows several names; the one with the most sites, or the
one whose lines span the function, is the function itself.

Addresses are for build 40408 (image base 0x140000000). Functions are found again on other builds by
signature, as the rest of the project does.

## The systems, by how much is named

Functions with a recovered name, per part of the source tree:

| Part | Named functions | What it is |
| --- | --- | --- |
| `framework/core` | 1,428 | containers, thread pool, clock, errors, images, maths |
| `Lib/ecs` | 527 | the entity-component core: component manager, engine, revisions |
| `Game/ecs` | 394 | the simulation systems (62 files; see below) |
| `Game/transport` | 381 | networks, paths, path finding, vehicles, lines, stations |
| `Lib/UI` | 340 | the interface toolkit |
| `Game/scripting` | 231 | the Lua interfaces (`api.engine`, `api.gui`, `api.res`, ...) |
| `framework/res` | 226 | resource repositories |
| `Game` (top) | 190 | application, game state, serializer, renderer, time, settings |
| `Game/transport/street` | 151 | street and track construction, shapes, terminals |
| `Game/UI/Actions` | 148 | the build tools, bulldozer, camera actions |
| `Game/UrbanSim` | 115 | towns: growth, parcels, destinations, streets |
| `Game/Terrain` | 109 (+50 nodes) | terrain, its renderer, the generator's nodes |
| `Lib/renderer` + `vulkan` + `model` | about 170 | render context, textures, model rendering |
| `Game/construction` | 75 (+26 street) | proposals: making, checking and applying a build |
| `Lib/Geometry/Streets` | about 80 | lanes, crossings, switches, transitions |

The simulation is a set of systems over entities and components. The systems that have assertions (so:
names) are: Account, AircraftMove, AnimalMove, AutoGroundTex, BaseParallelStrip, CarriageList,
CatchmentArea, Collision, EmissionEmitter, EmissionGrid, GameScript, GridCollision, LandVehicleMove,
Landmark, Line, LogBook, Lot, ModelInstanceList, Name, Notification, Octree, Parcel, PassableTiles,
PersonMove, RailroadCrossing, River, Runway, ShapeList, ShipMove, Signal, SimCargo, SimEntityAtStock,
SimEntityAtTerminal, SimEntityAtVehicle, SimEntityNeedsPath, SimPersonAtTerminal, SimPersonAtVehicle,
SimPersonCache, SimPerson, StationGroup, Station, StockList, StreetConnector, StreetMaintenance, Street,
TerrainAlignment, TownBuilding, TownLandmark, Town, TpNetLink, TrafficLight, TransportNetwork,
TransportVehicle, VehicleDepot, VehicleOrder, WaterCollision.

## Order of study

Each item ends in a note of its own under `re_notes/engine/` saying what the system holds, what drives it
each step, what it reads and writes, how it is saved, and how the claim was confirmed.

1. **The core**: entities, components, systems, revisions (`Lib/ecs`); the step of the simulation and its
   order of systems (`Game/GameSim.cpp`, `Game/Game.cpp`); saving and loading (`Game/Serializer.cpp`,
   `Game/GameState.cpp`, `GameStateLegacyHandler.cpp`). Everything else stands on this.
2. **Streets and the transport network**: a street's lanes from its type (`Lib/Geometry/Streets`), the
   network built from edges and nodes (`TransportNetworkSystem`, `TransportNetworkConstructor`), junction
   connections (`lane_connection_util`, `Crossing`), traffic lights. Needed first by left-hand traffic.
3. **Movement**: paths and path finding (`Game/transport`: `PathFinder`, `AStar`, `ext_path_util`,
   `move_path_util`), `LandVehicleMoveSystem`, edge reservation and use, the other carriers.
4. **People and cargo**: `SimPerson*`, `SimCargo*`, `SimEntity*` systems; destinations; what happens to
   one whose path is no longer valid (names seen: `SimPersonJumpHome`, `SimPersonRemoveState`,
   `SimCargoRemoveState`). Needed for any safe reset.
5. **Vehicles, lines, stations, depots**: `TransportVehicleSystem`, `VehicleOrderSystem`, `LineSystem`,
   `StationSystem`, `VehicleDepotSystem`, the transformators that pose a model on its path.
6. **Construction**: proposals from script result to entities (`Game/construction`,
   `Game/transport/street/construction_util_*`), terrain alignment, collision.
7. **Towns and economy**: `Game/UrbanSim`, `TownSystem`, `TownBuildingSystem`, `ParcelSystem`, accounts.
8. **Rendering**: partly mapped already (`re_notes/renderer`, `re_notes/camera`); to be tied to the names.
9. **Interface and scripting**: the toolkit, the Lua interfaces, mod loading.
10. **Terrain**: the generator's node graph, the terrain mesh and its textures.
