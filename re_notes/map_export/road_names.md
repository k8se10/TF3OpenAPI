# Road names and map export — API notes and design

Build 40408. Sources: `api/tealdef` and `base/tealdef` in the game folder, and two installed mods read as
behavioural references (no code taken): Pay Your Tolls (game script + toolbar button) and Wagon Cameras.
The first sections were written from the definitions before anything ran; "Confirmed in the game" further
down lists what the running game has since shown, including where the definitions were misleading.

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

## Design (as built, 2026-10-11)

`mod/tf3api_road_names/`:
- `road_names/core.lua` — pure logic, testable outside the game (`tools/tests/road_names_test.lua`).
- `road_names/names.lua` — word lists, thresholds, and the `ignoreSavedData` development switch.
- `road_names/road_names.script.lua` — the driver, run from the game script's `guiUpdate`: reads 250
  segments per frame, works out the links between towns (one shortest-path run per frame), then groups,
  names, hands the labels to the native layer and writes the export. Afterwards it checks the network every
  3 s and starts again when it has changed.
- `gui/tf3api/road_ui.*` — the road window and the host that watches for clicks on labels.

### The naming rules

The authority is the user's note on how British road naming works. Its central point: **a road's number, its
classification and its physical build are three separate things.**

**Streets.** Segments are grouped into streets. At a node with exactly two segments the street continues
through bends up to 75°. At a junction of three or more, segments are paired straightest-first (bend up to
35°), preferring equal class. Motorway-class never joins a lower class at a joint, but the joint is recorded
so the two can be one numbered route. A street's key is the smallest segment key (both end points rounded to
0.5 m, order-independent), because the game issues a new entity id whenever a road is split or rebuilt.

**Physical class** (`core.classOf`), from the road template's name first, because lane widths include
pavements: `highway`/`motorway` = 3, `_medium`/`_large`/`lane` = 2, `_small` = 1; unknown templates fall
back to speed (27 m/s and over = 3) and width (20 m and over = 2). It decides what is motorway standard.
It no longer decides A or B.

**Direction of travel** comes from the game's routing data (see "Confirmed in the game").

**Roundabouts** (`core.findRoundabouts`): a closed loop of one-way segments driven in one direction, up to
500 m round and 16 segments, every node within 35% of the mean radius from the centre. The ring is one
street; no approach road is merged into it. It takes the class, number and name of the most important road
meeting it, and that road's arms on the same line (beside the main arm or opposite it) are one route with it.

**Motorways.** Motorway-standard streets joined by joints or paired as carriageways form a route. Two
motorway-class streets are a pair when they run within 60 m of each other for at least half the shorter
one's length, in opposite directions where both directions are known. A route with a mile or more of
motorway standard gets an M number, if it has two lanes each way.

The number then spreads from each numbered motorway along connected motorway-standard streets that have
none (junction carriageways, links, spurs), the longest motorway first where two meet.

**Links between towns** (`core.startLinks`). Town size is the road length within 900 m of its centre; the
hub is the biggest. The biggest 12% (at least seven) are primary towns. Shortest paths by driving time,
one-way roads respected:
- radials: from the hub to primary towns in up to six directions at least 36° apart;
- A links: each primary town to its three nearest primary towns;
- B links: every town to its two nearest towns, where no A link already joins the pair.

**Numbers** (`core.name`), in this order:
1. Motorways, as above.
2. Links, most important first (radials, then A by town size, then B). A link numbers the stretches of its
   path that have no number yet and are at least 200 m; a street counts as on the path when the path uses
   half of it or 300 m. Radials get the single digit of the zone they lead into, if they have two lanes each
   way. Other A links get two digits at best (between primary towns, two lanes each way) and otherwise three
   or four, by length: 6 km, 2.5 km, 1 km, 500 m. A motorway-standard stretch on an A link is its `(M)`
   section. B links get three digits from 4 km, else four.
   Whenever a street is numbered here or in step 4, the one-way street running the opposite way within
   200 m of it for half its length (its other carriageway) gets the same number and name: a drive between
   two towns only ever uses one of the two.
3. Split carriageways: one-way streets joined end to end, or one street up to 250 m, with no number, that
   meet a numbered road at two or more places and run within 250 m of it for 60% of their length take its
   number and name.
4. Wide roads no link uses: an A number of three digits or more.
5. Slip roads: a street up to a mile long with no junction along it, motorway standard or one-way
   throughout, takes the number of the M road it touches (an A road's `(M)` section only if it has no number
   at all).
6. Long ordinary roads with no number: a B number from 1.5 km, or 800 m out of town.

Zones: with two or more radials, zone N lies clockwise from radial N to the next; otherwise six equal
sectors from north. A road's first digit is the furthest-anticlockwise zone it enters. One- and two-digit
numbers go by importance; three- and four-digit numbers are given out at the end, in each zone the road
nearest the hub first. A motorway that joins another at least twice its length takes that one's number plus
a digit.

**Names.** A name belongs to one road on the map (user rule, 2026-10-11); this replaces the earlier "names
may repeat between towns". A motorway and its slip roads are known by number only. Every town has a high
street (the longest ordinary street up to 1.5 km within 350 m of its centre): the hub's is "High Street",
the others "<Town> High Street". A or long roads are named after the town they lead to, taking the first free
of `names.destinationForms` ("%s Road", "Old %s Road", "%s New Road", "%s Lane" ...), one per place from any
one town. Everything else gets a generated name with a British ending. A roundabout or second carriageway has the
name of the road it is part of. Names and numbers a road has been given are kept when the network is read
again, unless `ignoreSavedData` is on.

**Abandoned roads.** `core.markIsolated` flags every street that is not joined to the main road network (the
connected part with the most road). The player can mark such a road abandoned in its window; the window
posts `abandon <id> 1` on the `tf3api_road_names` channel and the naming script names and draws again. An
abandoned road has no number, keeps its name, and is drawn with a grey "Abandoned" badge. The choice is kept
by street key, in memory, and applies only while the road stays cut off. Nothing in the game changes.

**Cities** (`core.resolveCities`). A city is the player's own object: `{ name, polygon, scheme }`, an outline
round several of the game's towns. Until there is a drawing tool it can also be given as a circle round a
town (`around`, `radius`). A town belongs to the first city whose outline holds it; the city's centre is its
biggest town. Following Britain (`uk_research.md`), the towns inside keep their identity:
- links (`core.startLinks`): member towns rank by their own size like any town. Only the choice of hub looks
  at the city as a whole: its centre town carries the city's total road for that.
- names: a road whose destination is a town inside a city, from a street outside that city, is named after
  the city by its plain name.
The naming script takes cities as messages on its channel (`city <name> <scheme> <x y x y ...>`,
`city-remove <name>`) and works the links out again when one changes.

**Postcodes** (`core.postcodePlan`, `core.postcode`). British form and hierarchy.
- Areas: the biggest 4% of the towns outside any city each head an area, with two letters from the name (the
  first letter plus the earliest later letter that keeps the code unique).
- Post towns: every town. It joins the nearest area; the area's own town is district 1 and the others are
  numbered outwards from it. So a district is a patch round a town.
- A spot has the postcode of its nearest post town. The sector (1-9) and unit (two letters from the British
  unit alphabet) are squares counted from that town: 667 m and about 33 m.
- A city's towns are its districts. `scheme = "grid"`: one area code from the city's name, numbered outwards
  from the centre. `scheme = "compass"`, the London way: the code is the direction from the centre (EC for
  the centre town, EC or WC within 1.5 km, then N, E, SE, SW, W, NW); in each direction the town nearest the
  centre is the head district, 1, and the rest are numbered alphabetically by name. Inside the outline a spot
  takes the nearest of the city's own towns; no ordinary area is given a compass code.
- Unique on the map. The nine sectors are the 2 km block round a town. Land beyond it is cut into further
  blocks, each a further district of the same post town: block j (in a spiral, the town's own being 0) is
  district `number + count * j`, `count` being how many towns share the letters, so no district is used
  twice. Only the first city asking for the compass scheme gets it; later ones get an ordinary area
  (`plan.demoted`). Checked on the real map's data: 40,734 spots sampled 151 m apart, no code shared. Far
  from any town the district numbers get large (up to 1190 at the map's corners).
The naming script sends the plan (each post town with its letters, number and count, and the city outlines) to the road
window as text over the `tf3api_road_names.ui` channel, again whenever the window says `hello`; the window
works out the postcode of the clicked spot from the position `takeRoadClick` returns.
On the test map's real data: 175 towns, 7 ordinary areas, and a 4 km compass city of 12 towns round the hub.

**The road window** (`gui/tf3api/road_ui.*`): the number on its sign (blue, green and yellow, white, or
grey for abandoned), the name in capitals on a white nameplate with a black border and the district in red,
then kind, length, postcode, post town and the Abandoned control.

**The player's choices** are kept by street key in the naming script (`choices`): `names`, `types`
(N, B, A, AM, M), `styles` (both, number, name), `abandoned`, `cities`. They reach it as messages from the
road window (`rename`, `type`, `style`, `abandon`, `city`, `export`). A type is applied in `core.name` after
the automatic numbering (`street.typeChoice`): the road gets a number of the chosen kind unless it already
has one; M and AM make it known by its number only. A rename is refused when another road has the name. The
label style only changes what is sent to the label renderer. The current choices come back to the window in
the click's flags (`T` + type letter, `S` + style letter). All of it is in memory until saving exists.

**Still decided by digit count, not function:** the shield colour (one- and two-digit A roads green).
**Not built from the note:** Station Road, Ring Road, Bypass, Link Road; junction numbers.

### Confirmed in the game (build 40408)

- `api.engine.getEntitiesWithComponent(BASE_EDGE_STREET)` fails: "Cannot loop over this component type".
  Street segments are listed through `api.engine.system.streetSystem.getNode2StreetEdgeMap()`.
- Airport taxiways and runways are street segments (templates containing `/airport/`).
- `BaseEdge.laneConfigs` includes pavement lanes and does not give the direction of travel: a three-lane
  one-way carriageway reported "5 lanes, 4 forward, 1 backward". Widths include pavements too (a small town
  street is 16 m).
- The `TRANSPORT_NETWORK` component on a street segment does give it: `edges` are the lanes vehicles route
  over, each with `transportModes`, `geometry` and `forwardOnly`. The same carriageway: 3 lanes, 3 for cars,
  all forward. This was the user's suggestion.
- The game-script UI state has no `app.saveUserdata`; the export goes through `tf3api.writeFile`.
- A `.script.lua` module is loaded through its `function data()`; a `.tl` module returns its table. A plugin
  whose script lacks `data()` stops the game from starting.
- A window recipe must be registered with `react.RegisterWrapperRecipe(name, builtin.Window, fn)`. A plain
  `RegisterRecipe` passes the window container a node it cannot index and the game dies with an assertion.
- A `react-plugin ::GameBarInfoDisplayExtension` component is always mounted while playing; `react.onStep`
  runs in it every UI step. The road-names host uses it to poll for label clicks.
- Windows are opened with `game_react_globals.getDefaultWindowApi().addWindow(recipe, key, params)`; the
  close button needs `closable = true`.
- Stylesheets are `.css.lua` files returning rules built with `stylesheetutil.makeAdder`; `!name` selects a
  class set through `meta = { class = ... }`. Written, not yet seen to apply.
- A real map: 8,534 road segments, 1,011 streets, 668.5 km, 175 towns.

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

## Cities: Skylines 1 behaviour to match (research 2026-10-10)

User requirement: same as C:S1 — names drawn on roads from a distance, hidden close, click a name to open
the road's info. Sourced from players' descriptions (no official documentation found):

- Road names must be switched on in the options ("show road names") before they can be clicked.
  https://steamcommunity.com/app/255710/discussions/0/1473096694452856527/
- Click the road name; a panel opens; click the name in the panel and type to rename. (same thread)
- The panel has an "Adjust Road(s)" control. It shows a green line along the road's "name path" with big
  green circles at each end; left-click, hold and drag an end circle to extend or contract the path. A middle
  dot does nothing. Names follow the road's straight continuation: a bridge in line with its approach road
  shares its name until the ends are dragged apart; a bridge approached at an angle keeps its own name.
  https://steamcommunity.com/app/255710/discussions/0/1290690669220637985
- Road naming arrived with the free update released alongside the Mass Transit expansion (2017).
- Not found: camera distances for showing/fading names; the panel's full layout.

TF3 side: HUD icons (`builtin.HudIconManagerConfig`, `Builtin.Type.VisibilityThresholds.OfComponent` with
`minDist` / `maxDist` / `scale`; `gui/hud/hud_react_util`) are the candidate for the labels. Unknown: text
rotated along the road.

## Still to build

1. Names, numbers and the player's choices stored in the save (written when the game saves), and a store
   that survives a save reload within one launch.
2. The road window: rename, the five road types, label style, statistics.
3. The road extent tool (green line over whole segments, drag either end).
4. Floating button and main panel; unit settings; country profiles.
5. Intercepting the click so it does not also reach the game.
6. Transit lines, stations (and Station Road), buildings and water on the map; junction numbers.
