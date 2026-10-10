# Road names and map export — API notes and design

Build 40408. Sources: `api/tealdef` and `base/tealdef` in the game folder, and two installed mods read as
behavioural references (no code taken): Pay Your Tolls (game script + toolbar button) and Wagon Cameras.
Status of each point is marked; nothing here has been confirmed in-game until the first export run.

## What the API gives us (from the definitions)

- **Road graph.** `api.engine.getEntitiesWithComponent(api.type.ComponentType.BASE_EDGE_STREET)` lists street
  segments. `BASE_EDGE` on a segment: `node0`, `node1`, `position0/1`, `tangent0/1` (Vec3f), `laneConfigs`
  (`width`, `speed`, `forward`, `transportModes`, `offset`), `type` (NORMAL / BRIDGE / TUNNEL), `roadTemplate`
  and `roadStyle` (resource names), `distance`. `api.engine.system.streetSystem` has `getNode2StreetEdgeMap`,
  `getNodeStreetSegments(node)`.
- **Towns.** `TOWN` entities; name via `api.engine.util.getEntityName`; position from `BOUNDING_VOLUME.bbox`.
- **Roads cannot be named natively** (user, 2026-10-10): the `NAME` component and
  `api.cmd.makeEntitySetNameCmd` are for assets, stations, depots and the like.
- **File output.** Only `app.saveUserdata(dir, file, table)`: a Lua file `function data() return {...} end`
  under the user-data folder. `app.getAllUserdata(dir)` lists a folder (loading a missing file logs an error
  even inside `pcall`, per Pay Your Tolls' notes).
- **Saved state.** A game script's state is stored in the savegame. Engine side: `state:get()/set()` convert
  the whole table; `get_native()` returns a `NativeLuaTable` with `find`, `findPath`, `insert`, `remove` for
  cheap partial access. The UI side gets it read-only.
- **Engine-side script locals are per thread** (the engine runs game scripts on its Sim Pool threads, each
  with its own Lua state — also visible in our profiler). Nothing may be kept engine-side outside the state.
  The UI side is one Lua state: caches and frame-by-frame work belong there.
- **Events.** UI → engine: `api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(...))`, handled in the
  game script's `handleEvent`. The player's own builds reach `guiHandleEvent` as `builder.proposalApply`.
- **UI.** Toolbar button: a `.res.lua` of type `react-plugin ::MainModButtonAreaExtension` (radial menu's
  mod button area). Running code when a UI Lua state starts: `react-replacement-config`.
  World drawing: `api.gui` `setZone(key, polygon, draw, color, ...)`, `setHighlighted`. Mouse:
  `api.gui.camera.screen2World`, `traceToTerrain`.

## Design (as built so far)

`mod/tf3opt_road_names/`:
- `road_names/core.lua` — pure logic, testable outside the game (`tools/tests/road_names_test.lua`).
  - **Segment key** = both end points rounded to 0.5 m, order-independent. Names attach to keys, because the
    game issues a new entity id whenever a road is split or rebuilt.
  - **Grouping.** At a node with exactly two segments the street continues through bends up to 75°. At a
    junction of three or more, segments are paired straightest-first (bend ≤ 35°), preferring equal road
    class; unpaired segments end there. Motorway-class never joins lower classes at a joint.
  - **Class** from lanes: 3 = top speed ≥ 27 m/s, 2 = width ≥ 16 m or speed ≥ 19 m/s, else 1.
  - **Names and numbers follow British practice** (user decision; reference: the user's note on UK road
    naming). Numbers belong to ROUTES: `core.group` also returns the joints where a road carries on at a
    different standard (main road <-> motorway-standard), and `core.name` unions streets over those joints, so
    an A road keeps its number through a motorway-standard stretch (`A2` - `A2(M)` - `A2`). Zones fan out
    clockwise from north around the hub town (most road); first digit = zone; per zone the longest gets the
    shortest number. One- and two-digit A roads are primary. Names: High Street per town, destination names
    ("Farley Road" leads to Farley), then generated names with British endings. Deterministic throughout.
  - **Road type is the player's choice** (user decision): Normal road, B road, A road, A road (M), Motorway,
    picked by tickbox per road. Not built yet; the automatic class is the default until the player picks.
- `road_names/names.lua` — word lists and suffix rules.
- `road_names/road_names.script.lua` — UI-side driver: 250 segments per frame, then group, name, export.

`tools/road_map.py` turns the export into four files: an interactive HTML street map in the Google Maps UK
look (curves from the game's tangents, British road-number shields, names along roads, town names, search,
scale bar), an SVG picture, GeoJSON and OSM XML (the flat game map is placed at a chosen latitude/longitude).

## UI toolkit (from `base/tealdef/scripts/builtin.d.tl`, `react.d.tl`, `gui/main/tool_react_util.d.tl`)

The game's UI is a Lua React-style framework; mods can use the same components the stock UI uses.

| Need | Toolkit piece |
|---|---|
| Toolbar entry | `.res.lua` of type `react-plugin ::MainModButtonAreaExtension`; `builtin.ToolButton { toolDefinition, text/content }` |
| A tool with a window | `tool_react_util.registerToolWithWindow(toolName, windowId, windowRecipe)`; window recipe gets `{ onClose, payload = { toolParam, setActionFn } }` |
| Activating / leaving | `game_react_globals.getDefaultToolStackApi()` -> `push(tool, key, params)`, `pop(tool, key)`; `ToolStackContext.popSelf()` |
| Picking in the world | `builtin.Selector { onSelect(entity, indices, details), onHover, filter(entity), onProcessMouseEvent, selectionColor ... }` set as the tool's action via `setActionFn` |
| Coloured line on roads | `builtin.EdgeRenderable { edges = { Type.EdgeRenderable.Edge.new(EdgeGeometry) with colors, width, offsetZ, stepSize }, ignoreDepth }` |
| Window | `builtin.Window { title, content, onClose, id, titleEditable, onTitleChange, ... }`, opened through `game_react_globals.getDefaultWindowApi()` |
| Inputs | `TextInputField { value, onValueChange, maxLength }`, `CheckBox { label, value, onValueChange }`, `ToggleButtonGroup`, `Button { content, onClick }`, `ComboBox`, `Slider` |
| Layout / text | `BoxLayout`, `FlowLayout`, `TableLayout`, `ScrollArea`, `TextView`, `ImageView`, `ProgressBar` |
| World labels | `HudIconParam`, `HudIconManagerConfigParam` (the town-label mechanism) |

`EdgeGeometry` and `Gui.SelectionDetails` are not in these files; find their definitions (api `gui.d.tl` /
`type.d.tl`) before writing the tool. Whether `Selector` reports street segments, and with which
`indices`, has to be seen in-game.

## Still to build

1. Saved names (engine-side state, keyed by segment key) and renaming.
2. Keeping names through edits: a new segment inherits from a vanished key that shared an end point, else
   joins a neighbouring street it continues, else gets a new name. Town-built roads need a background scan.
3. The road extent tool (green line over whole segments, drag either end).
4. In-game labels (must be cheap: the UI layer is the measured hotspot on this build).
5. Transit lines, stations (and Station Road), buildings and water on the map; junction numbers.
6. Road panel: name field, the five road-type tickboxes, the extent tool.
