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

Collected from build 40420 (the current one; all analysis is done on it) with two small scripts for the
Ghidra disassembler, static analysis only:

| File | What it holds |
| --- | --- |
| `source_map.md` | the engine's source tree as the executable names it: 893 files in 95 folders |
| `assert_names_40420.tsv` | 10,972 assertion sites: function address, size, **real function name**, source file, line, condition. 5,768 functions, 3,792 distinct names |
| `functions_by_source_40420.tsv` | 7,706 functions tied to the source file they refer to (covers functions whose assertion form the first script does not read) |

A name found this way belongs to the code the assertion was written in. Where the compiler put a small
function inside a bigger one, the bigger function shows several names. `tools/ghidra/name_calls.py` picks
the name found at the fewest addresses of the whole program (a helper put inside many functions is found at
many), which is the function's own in the cases checked.

Addresses are for build 40420 (image base 0x140000000).

## The names carry across game updates

The same harvest on the previous build (40408) gave 5,766 functions. Matching the two lists by what the
assertions say - the set of (function name, condition) pairs in a function, texts that do not change when
the code is compiled anew - pairs **3,425 functions one-to-one** (59%). 2,322 more have texts that several
functions share (generic code compiled once per type it is used with: containers, loops), so they cannot
be told apart by text alone; 19 functions exist only in the older build and 25 only in the newer.
(`tools/ghidra/match_builds.py`.)

That is what the native layer's second way of finding a function rests on (`sigscan::FindByTexts`): the
one function that refers to a given set of texts, found through the executable's own function table.
Tested against the executable on disk, mapped but never run (`tools/tests/sigscan_test.cpp`): of 400
functions taken evenly from the list, 238 were found at exactly their address, 162 were refused because
their texts are shared, none was found wrongly. The six scene-rendering functions the occlusion module
hooks are each found by their name text alone at the address their byte signature gives
(`tools/tests/sigscan_hooks_40420.tsv`), and the module now falls back on that when a byte signature
fails.

## Tools

| Tool | Use |
| --- | --- |
| `tools/ghidra/blank_exception_dir.py` | makes the copy of the executable that Ghidra can import |
| `tools/ghidra/AssertNames.java`, `FuncsBySource.java` | the two harvests |
| `tools/ghidra/DecompileAt.java`, `CallGraph.java`, `StrXrefs.java` | reading: decompile, who calls whom, who uses a text |
| `tools/ghidra/names_in.py` | the named functions of a source file, or by part of a name (`--name`) |
| `tools/ghidra/name_calls.py` | puts names beside the addresses of a call graph |
| `tools/ghidra/match_builds.py`, `reanchor.py` | match two builds; carry the addresses in notes from one to the other |
| `tools/ghidra/name_signatures.py` | which recovered function each of the native code's byte signatures lands in |
| `tools/make_sig_cases.py`, `tools/tests/sigscan_test.cpp` | test of the text-based finder |

## The systems, by how much is named

Functions with a recovered name, per part of the source tree:

| Part | Named functions | What it is |
| --- | --- | --- |
| `framework/core` | 1,428 | containers, thread pool, clock, errors, images, maths |
| `Lib/ecs` | 526 | the entity-component core: component manager, engine, revisions |
| `Game/ecs` | 394 | the simulation systems (62 files; see below) |
| `Game/transport` | 381 | networks, paths, path finding, vehicles, lines, stations |
| `Lib/UI` | 337 | the interface toolkit |
| `Game/scripting` | 231 | the Lua interfaces (`api.engine`, `api.gui`, `api.res`, ...) |
| `framework/res` | 226 | resource repositories |
| `Game` (top) | 190 | application, game state, serializer, renderer, time, settings |
| `Game/transport/street` | 146 | street and track construction, shapes, terminals |
| `Game/UI/Actions` | 148 | the build tools, bulldozer, camera actions |
| `Game/UrbanSim` | 115 | towns: growth, parcels, destinations, streets |
| `Game/Terrain` | 109 (+50 nodes) | terrain, its renderer, the generator's nodes |
| `Lib/renderer` + `vulkan` + `model` | about 170 | render context, textures, model rendering |
| `Game/construction` | 75 (+26 street) | proposals: making, checking and applying a build |
| `Lib/Geometry/Streets` | 66 | lanes, crossings, switches, transitions |

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
