# Converting station mods: first look

Status: assessment only. Nothing is built. Read from two Transport Fever 2 station mods (a modular rail
station and the modular station it is built on) and from the game's own scripts, build 40408.

## What a Transport Fever 2 station mod is made of

| Part | In the two mods | What the converter does with it today |
|---|---|---|
| Models (`res/models/model/station/...`) | 39 each | converted like any other model |
| Meshes, materials, textures | 38 / 7 / 27 | converted |
| The construction (`res/construction/.../*.con`) | 1, about 1,100 lines of script | not converted |
| Modules (`*.module`) | 10, 80 to 210 lines of script each | not converted |
| The mod's own helper scripts (`res/scripts/modules/*.lua`) | 2, about 600 lines | not converted |
| Pictures for the build menu (`res/textures/ui/construction/...`) | a few | copied as textures, not placed |

So the models are the easy half. The station itself is a program: the `.con` builds the station from its
parameters and modules each time the player changes it, by calling the game's construction libraries.

## Do the libraries it calls still exist?

Every library function the two mods call, checked against the newer game's scripts:

| Library (as the mods `require` it) | In the newer game | Functions the mods use that are gone |
|---|---|---|
| `constructionutil` | `scripts/construction/constructionutil.lua` | none |
| `modulesutil` | `scripts/construction/modulesutil.lua` | none |
| `paramsutil` | `scripts/construction/paramsutil.lua` | `makeTrackTypeParam`, `makeTrackCatenaryParam` |
| `colliderutil` | `scripts/construction/colliderutil.lua` | `createBox` |
| `modules/trainstationutil` | `stations/rail.zip` -> `rail/trainstationutil.lua` | none |
| `vec2`, `vec3` | `scripts/vec2`, `scripts/vec3` | none |
| `transf` | `scripts/transf.lua`, marked obsolete; it hands out the newer matrix library | `mul`, `transl`, `rotZTransl`, `rotZYXTransl` are not in that small file itself, but the matrix library it returns has functions of those names |

The libraries moved (a plain `require "constructionutil"` no longer finds them) and three functions are gone,
but most of what the mods lean on is still there. That is far better than rebuilding a station from nothing,
and it is why this looks possible where the Transport Fever 1 -> 2 converter gave up.

## Corrections after the first station was used in the game (2026-10-12)

Reported: no platform numbers, nobody boards, no walking paths shown, underpasses not cutting the terrain,
the game's own station buildings not drawing properly. Read from the game's scripts
(`rail/modular_station/modules.script.lua`, `modular_station.script.lua`, `rail/trainstationutil.lua`,
`scripts/construction/construction.script.tl`, `legacytransportnetworks.lua`):

- **The game's own modules start with `result = result.cargoStation`.** The station script makes that inner
  table (own `models`, `groundFaces`, `colliders`, `labelText`, `laneLists`; the helper functions copied in)
  and, in its closing step (`terminateConstructionHook`), appends the outer `result.models` after the inner
  ones and makes the inner table the station's sub-construction. `labelText` is keyed by model position, so
  a module that writes into the outer result gets its board numbers attached to the wrong models. The
  adapter now passes `result.cargoStation` to the mod's module as its result.
- **Terminals** are made by the game's track module (`trainstationutil.makeTrack`) for a neighbouring module
  whose metadata says `passenger_platform`; the mod's platform carries that metadata, so nothing to add.
- **Walking lanes of the game's own models** come from `legacytransportnetworks.addLaneLists`, called in the
  closing step: a table keyed by plain names such as `/stations/rail/era_a/tn_underground_connection.mdl`.
  Its fallback for a prefixed name strips `::/` including the slash, so a prefixed name never matches. The
  adapter therefore keeps the game's models under plain names while the station is built and adds `::` in a
  step of its own after the game's closing step. That step is hooked from the mod's modules (each wraps
  `result.terminateConstructionHook` once per result), not from an update script of the mod's own: the
  station's `updateScript` must stay `/stations/rail/modular_station/modular_station.script`, because other
  mods identify a modular train station by exactly that path (seen in the game: a station-range mod offered
  no setting for the converted station while its update script was the mod's own).
- **Walking lanes of the mod's models** (`metadata.transportNetworkProvider.laneLists`) are collected at
  conversion into the adapter (`shim.ownLanes`) and appended to the sub-construction's `laneLists` with the
  model's transform, the same shape `addLaneLists` writes.
- **Platform height.** `trainstationutil.makeTrack` has `local perronHeight = 1.1` and lays the waiting
  lanes (the terminals) at that height, 2.5 m from the platform's middle; the lane list's own origin is
  1.5 m from it. The Transport Fever 2 mods seen have platforms and lanes at 1.5 m. Seen in the game: feet
  inside the platform, and people jumping to the platform (the lanes do not meet). The adapter notes where
  the mod's platform modules stand and, in its closing step, lifts every flat lane list within 2 m of one
  of them, and within 1 m of the mod's lane height, to that height (the height most of the mod's lanes lie
  at). The underground connection (`tn_underground_connection`, lanes at -7 in both games) is left alone.
- **Joining the game's lanes to the mod's.** Lifting the waiting lanes cured the feet, not the jump from the
  entrance: the game's main building (`MakeMainBuildingModule`, lanes from the module's baked curves) ends
  its lanes at 1.1 m as well. The loose ends of the mod's platform lanes are at the same spots as the lane
  ends of the game's own platform (x = 0 / 10 / 20 / 30 / 40 along it, y = 0 / 1 / 2.5 across), only at
  1.5 m. The adapter's closing step moves every node of the game's lanes that lies within 0.15 m in plan
  and 0.6 m in height of a node of the mod's lanes to that node's height (upright lane lists only).
- **A built station keeps its lanes.** Seen in the game: the lane fixes only took effect once the station was
  removed and built again. Test every station change on a newly built station.
- **Hiding the terrain for the underpass stairs (build 40420).** The older game cut the terrain away under
  a ground face with `hole.lua`. The newer game does not: `infrastructure/shared/hole.gtex.lua` is an
  ordinary ground texture (`sand_02`, `priority = 5000`); the game's stairs module lays it under the stairs
  and its platform lays gravel there as well. The one function in the executable that names the texture
  (`FUN_14265b3b0`) builds ordinary ground polygons with it. What hides the terrain is on the **model**:
  `stations/rail/era_a/perron_5_underpass.mdl` has, in `metadata.lightSourceList.lights`, two entries with
  `mode = "DISCARD"`, `type = "PARALLEL"`, `mask = 1`, `invertMask = false`, `length = 6.1`, `width = 3.3`,
  `height = 2`, `strength = 10000`, `fromTime = 0`, `toTime = 24`, at x = 16.28 and 23.62 of a 40 m model,
  z = 0. Measured on its mesh, the two flights of stairs pass through ground level between x = 15 and 25,
  2 m wide, with the landing in the middle: so a box is centred on its origin, `length` along its x axis.
  77 of the game's models use `DISCARD` (73 of them tunnel portals; those use `mask = 0`,
  `invertMask = true`). Confirmed in the game the other way round: the game's own station is cut, the
  converted one (same hole face, with or without `::`, old rules or new) was not.
  The converter writes `tf3api_legacy/cut/cut_<along>x<across>.mdl` (no mesh, modelled on the game's
  `tn_underground_connection.mdl`; sides 0.4 m x 1, 2, 4 ... 64) and the adapter places them over each hole
  face a module adds, at z = 0. Seen in the game: the underpass is open, so a model without a mesh does
  carry such a box and the copied values work. Not known: what `mask` selects and what `radius` does for a box.
- **Diagnostic.** With `StationDebug=1` the adapter writes the station's lanes (before and after its
  changes, in station coordinates), models and ground faces through `tf3api.writeFile`.
- **Labels:** no model of the game's own rail stations has a `labelList`, but the executable still knows
  `labelList`, `childId`, `alphaTest`, `alphaMode`, `STATION_NAME`. The models' label lists are left as they
  are; if numbers are still missing with the index fix, look there next.
- Not known: whether a plain name written by the game's scripts inside a mod's construction is looked up in
  the mod (which would explain the buildings); the closing step makes the question moot if so.

## What is not known yet

1. **Whether the libraries behave the same.** Same names do not mean same arguments or same results. Each of
   the calls the mods make has to be compared with the newer game's version.
2. **What the newer game expects a construction to return.** A Transport Fever 2 `updateFn` returns models,
   track and street pieces, terminals, ground faces, terrain alignment and slots for modules. The newer game
   has its own station metadata (`stations/station_metadata.tl`) and its own stations to compare against.
3. **File names and places.** The newer game's constructions are `.con.lua` and modules `.module.lua`; where a
   mod's own helper scripts have to live to be found is to be read off a working mod.
4. **The models' own station data**: lanes for passengers, terminals, the things the game's own station models
   carry (`transportNetworkProvider`). Whether the old form is upgraded on load like vehicle data is.
5. **Modules that plug into the game's own station.** One of the two mods adds modules to the stock modular
   station; those depend on the stock station's slot layout, which will have changed.

## How the newer game builds its own modular rail station (build 40408)

Read from `stations/rail.zip` (`rail/modular_station/modular_station.con.lua`, `modular_station.script.lua`,
`modules.script.lua`, the `.module.lua` files, `rail/trainstationutil.lua`), `scripts/construction/*` and the
type definitions in `api/tealdef/api/type.d.tl`.

**It is the same station, reshaped.** The newer game's script still works the way the Transport Fever 2
one does: the same grid of tracks and platforms, the same helper names on the result (`GetModuleAt`,
`trackCoord`, `connector`, `labelText`, `slots`, `occupied`, `setPlatformNumber`, `addPlatformCallback`,
`terminateConstructionHook`, ...). The Transport Fever 2 mod and the newer game's script use 24 of the same
result fields. What changed is the packaging around it:

| | Transport Fever 2 | Transport Fever 3 |
|---|---|---|
| Files | `x.con`, `y.module` | `x.con.lua`, `y.module.lua`, plus `.script.lua` files holding the functions |
| Functions | inside the file's table: `updateFn = function(params)` | named from the data: `updateScript = { fileName = "<file>.script@updateFn", params = { } }`; also `createTemplateScript`, `upgradeScript` |
| Function arguments | `updateFn(params)`; module `updateFn(result, transform, tag, slotId, addModelFn, params)`, `getModelsFn()` | a first argument is added: `updateFn(captureParams, params)`; module `updateFn(captureParams, result, transform, tag, slotId, addModel, constrParams)`, `getModelsFn(captureParams, params)` |
| Libraries | `require "constructionutil"` | `require "/scripts/construction/constructionutil.lua"`; vectors and matrices from `/scripts/vec3.tl`, `/scripts/mat4.tl` |
| Matrices | 16 numbers | still a table of 16 numbers (with operators added) |
| Menu | `category = { categories = { "misc" } }` | `menuCategory = { categories = { { category = "...", order = n } } }` |
| Track types | by name in `edgeLists[i].params.type` | street template files, e.g. `/infrastructure/track/standard/standard.street_template` |
| Model names | `station/rail/x.mdl` | from the content root, `/stations/rail/...` |
| Where passengers walk | lanes are part of each model (`transportNetworkProvider`) | lane lists belong to the construction (`laneLists`, each with the model's transform) |
| The station itself | `result.terminalGroups` and `result.stations` (lists of terminal groups by index) | `result.subconstructions = { { models, colliders, terrainAlignmentLists, groundFaces, laneLists, station = { terminals, pool }, metadata } }` |
| A terminal | a list of (model, terminal of that model) pairs | `personNodes`, `personEdges`, `vehicleNode`, each a (lane list, node) pair, plus `cargoTransferSpeeds`, `comfortFactor` |

**The game has a bridge for the old lane form.** `scripts/construction/legacytransportnetworks.lua` holds
the old per-model lane data of the game's own models (17,000 lines, keyed by model name) and a function
`addLaneLists(result, skipReplaceIndices)` that (a) gives each subconstruction a lane list for every lane of
every model in it, and (b) unless told to skip it, renumbers the terminals' node and edge references from
"(model, node of that model)" to "(lane list, node of that list)". Its table only knows the game's own
models, so it cannot be used for a mod's models as it is, but it shows exactly what has to be done with
them: the same renumbering over the mod's own lane data.

## What settles the approach: the modules fit the newer game's own station

Read further into the same files:

- **How a station is assembled** (`scripts/construction/construction.script.tl`, `constructWithModules`): the
  game calls the construction's `updateFn(scriptParams, constrParams)`, then for every module placed in a
  slot the module's `updateFn(scriptParams, result, transform, tag, slotId, addModel, constrParams)`, then
  `result.terminateConstructionHook()`. The newer game's station does its reshaping into
  `subconstructions` in that last hook.
- **The station mod's own `.con` is the older game's stock station with other defaults.** It refers to a
  dozen stock modules of the older game by name (`platform_track`, `platform_track_catenary`,
  `platform_high_speed_track`, `main_building_1..3_<era>`, `side_building_*`, `platform_cargo_era_*`,
  `platform_passenger_roof_era_*`). The newer game has modules of most of those names, but they are written
  for the newer station's result (they write lane lists into `result.cargoStation`), so they cannot be mixed
  into a result built by the old script.
- **The mod's modules are of the very types the newer game's station takes.** The mod: one
  `passenger_platform`, seven `passenger_platform_addon`, one `passenger_platform_roof`. The newer game's
  stock station: `passenger_platform`, `passenger_platform_addon`, `passenger_platform_roof`,
  `cargo_platform`.
- **Scripts of a mod** are required as `"<modId>::/path/file.lua"`, the game's as `"::/scripts/..."`; script
  functions are named `"<modId>::/path/file.script@functionName"` (read off working mods).

So the station does not have to be carried over at all. The mod's modules are converted so that they plug
into the newer game's own modular station: the player builds the game's station and picks the mod's
platform, roof and add-ons from the module menu, and everything the newer station does (tracks, terminals,
lanes, capacities, catchment) is the game's own code. The mod's `.con` then only matters as a ready-made
starting layout, which can be added afterwards as a template of the stock station.

What that needs: each `.module` as a `.module.lua` plus a `.script.lua` holding its functions with the new
first argument; the mod's helper scripts carried over with their `require`s repointed; and the places where
a platform module of the older game adds its walking lanes and terminals through its models rewritten to
what the newer station expects from a platform (`trainstationutil`, `modules.script.lua`
`platformPassenger...`: lane lists added to `result.cargoStation.laneLists`, terminals as
`{ personEdges = { { laneList, edge } }, personNodes = { { laneList, node } } }`).

## The earlier plan (carrying the whole station script over)

Kept for the record; superseded by the section above for mods whose modules have the stock station's types.
It remains the way for a station that is not built on the stock modular station.

### Steps of the earlier plan

1. **Lane data.** When a station's models are converted, their `transportNetworkProvider` lane lists and
   terminals are written to a table shipped with the converted mod (model name -> lanes, terminals).
2. **Scripts are carried over and wrapped, not rewritten.** The old `.con` and `.module` text goes into a
   `.script.lua` with its `require`s pointed at the new places; a generated `.con.lua` / `.module.lua` holds
   the data and names the functions. A small runtime library shipped with the converted mod adapts each
   call: drops the new first argument on the way in, and on the way out turns the old result into the new
   one (terminal groups and stations into a subconstruction with a station; lanes from the table of step 1,
   renumbered; model names and track types renamed).
3. **Three library functions that are gone** (`paramsutil.makeTrackTypeParam`,
   `paramsutil.makeTrackCatenaryParam`, `colliderutil.createBox`) are supplied by the same runtime library,
   written against what the newer game has in their place (`param_util.makeTrackTypeDefaultParam`, ...).
4. **Off by default until it loads.** A construction file the game cannot read can stop a save from
   loading, so station scripts are only written when a switch is on, until one station has been seen
   working.

Not looked at yet: what the newer game's `createTemplateFn` / `upgradeFn` return compared with the old; the
`cargoTransferSpeeds` a terminal needs; how the stock helper `modulesutil.getStationPoolEdges` is used; the
mod that adds modules to the game's own station.


(The steps above are superseded by "Conversion plan that follows from it".)
