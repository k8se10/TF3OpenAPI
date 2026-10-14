<div align="center">

# 🚆 TF3OpenAPI

### Native Community Expansion for Transport Fever 3

[![Status](https://img.shields.io/badge/status-in%20development-orange)](PATCHNOTES.md)
[![Game build](https://img.shields.io/badge/game%20build-40420-blue)](#which-game-build-this-is-developed-against)
[![Last commit](https://img.shields.io/github/last-commit/k8se10/TF3OpenAPI)](https://github.com/k8se10/TF3OpenAPI/commits/main)
[![License](https://img.shields.io/badge/license-custom%20(free%2C%20no%20resale)-blue)](LICENSE)
[![Support on Ko-fi](https://img.shields.io/badge/support-ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/officialk8)

</div>

> Formerly "TF3 Optimizations + DLSS". Files, settings and mod ids use the short name `tf3api`.

## Current state

### 🛠️ `v0.1.0` - in development, not yet released

- 🖥️ **A native layer inside the game** - fixes, a profiler, drawing in the world, writing into the game's own
  textures, a script bridge for other mods
- 🔁 **A converter for older Transport Fever mods** - Train Fever, Transport Fever 1 and 2 vehicles,
  stations, tracks and assets converted at launch and listed with the game's own mods
- 🚉 **Departure boards** with live dot-matrix screens, a station diagram with moving trains, and stops and
  stations named the way real ones are
- 🛣️ **Road names, numbers and maps** the British way, drawn on the roads, with a window per road and an
  "Adjust road" tool
- 🏗️ **Placing in two steps** for stations, depots and assets, turned with the right mouse button and raised
  with the middle one
- 🕰️ **A day clock** running in real time, with the calendar, the sky and vehicle ageing following it

> [!WARNING]
> ⚠️ **Early development software.** Nothing is packaged for release yet. Many features are built but not yet
> seen in the game; every table below keeps "verified" (run in the game and seen to work) apart from "built"
> (written and tested outside the game only). Open problems are tracked one by one in
> [`re_notes/known_issues.md`](re_notes/known_issues.md).

> [!IMPORTANT]
> Developed against Transport Fever 3 build 40408 (launch) and, from 12 October 2026, build 40420. Engine
> functions are found by signature scanning at startup, so most of it should carry to newer builds; a feature
> whose function cannot be found switches itself off and says so in `tf3api.log`. See
> [Which game build](#which-game-build-this-is-developed-against).

## About

**An unofficial expansion of Transport Fever 3, built into the game itself.**

TF3OpenAPI fixes, extends and improves Transport Fever 3 from the inside: a native layer that lives in the game
process and works with its engine directly, a set of script mods that use it, and a converter that brings older
Transport Fever mods across. It started as a few performance fixes. It is now closer to a community patch, in
the way the MW32011NCP project treated its game, than to a programming interface: the aim is to make the game
better and larger while it still feels like the same game.

| Component | What you get | Status |
|---|---|---|
| **Native core** (`winhttp.dll`) | Engine fixes, a profiler, drawing under the game's interface, live writing into the game's textures, two-step placement, the converter's host | ✅ Loads and hooks on build 40420; fixes, profiler, overlay, board screens and placement seen working<br>⏸ Occlusion culling left off: little gain for the risk |
| **Script mods** (`mod/`) | Road names and maps, departure boards, day clock, placement, station names, a town label fix | ✅ Road names, boards, day clock, placement, the label fix, stop names and existing stations' names used in the game<br>🟡 Names of newly built stations: second fix built |
| **The mod converter** (`converter/`) | Old Train Fever / Transport Fever 1 / Transport Fever 2 mods put in a folder, converted at launch | ✅ Rail units, modular stations, tracks, billboards and signs working in the game<br>🟡 Buses converted, not yet confirmed working; ❌ bridges, tunnels, depots, ships and aircraft not converted |
| **The platform for other mods** (`tf3api` table) | Functions the official modding API lacks: files, messages between script states, a worker thread, labels, board screens, click spots | ✅ API version 18, documented in [`re_notes/platform/api.md`](re_notes/platform/api.md)<br>❌ A stable public API with versioned guarantees and example mods not built yet |

What "faithful" means here:

- **The game's own parts first.** New things use the game's windows and interface toolkit, its tools and build
  commands, its textures, its station and construction scripts, its own two-step building option. A departure
  board's screen is a texture of the game's, written live; a converted station is built by the game's own
  station script; a turned object is turned by the game's own rotation setting.
- **The engine is learned before it is changed.** Functions are found by reverse engineering and systems are
  written up ([`re_notes/engine/`](re_notes/engine/)); a feature hooks the place where the game itself does the
  thing.
- **True to the real world where the game models it.** Roads are numbered and named the British way, stops the
  way London names them, departure boards look and behave like National Rail's - each rule researched first and
  written down with its sources.
- **Nothing silently broken.** The simulation is left as the game runs it unless a feature exists to change it,
  and then only per save, on request. Saves load in the unmodified game.

The official modding API covers content - models, scripts, the interface, game rules - but does not reach the
engine: the renderer, the frame loop, drawing in the world, the engine's internal data, input, or files on disk.
TF3OpenAPI reaches those parts directly and uses them where the game's own way of doing a thing needs them. The
"API" in the name is the part other authors can use; it is one part of the project, not all of it.

It is unofficial, free, and not affiliated with Urban Games or Paradox Interactive.

## Status

### What works right now

#### 🔧 Fixes and performance

| Feature | Status | Notes |
|---|---|---|
| Cockpit camera depth fix | ✅ verified | The cockpit view is clamped to a world height of -100 m, so it breaks in deep tunnels. This removes the lower clamp. |
| Shadow map resolution limit | ✅ verified | The game sizes shadow maps from the screen (4096x4096 at 1080p, 1440p and 4K on High). This sets a maximum. |
| Town label fix (`tf3api_hud_fix`, script mod) | ✅ verified | Each town label fetched the state of every town to read its own. Now fetched at most once a second. |
| Night lighting cap | ✅ verified | The game lets each screen bucket use at most 64 lights, so at night over a town the glow of some street lamps stopped in sharp rectangles. `[Lighting] MaxLightsPerBucket` raises it (256 tried). |
| Terrain occlusion culling | ⏸ verified to run, **no measured benefit** | Off by default, and left off: little gain for the risk. Its hooks stay in with `Cull=0`, because the road names are drawn with the camera they read. See [Honest results](#honest-results). |

#### 🏗️ Building and placing

**Placing objects in two steps.** With the game's own option "Enable Drag-and-Confirm Construction Mode" on
(Settings > Advanced), stations, depots and assets get the step that option gives roads and track. Needs the
native layer (`[Placement] ConfirmObjects=1`) and the script mod `tf3api_placement`.

| Piece | Status |
|---|---|
| The first click pins the object; a second click builds it | ✅ verified |
| Holding the right mouse button and moving the mouse turns it in the game's own 10 degree steps, with the view held still | ✅ verified |
| Holding the middle button and moving the mouse up or down raises or lowers it in steps of 0.5 m (the game's fine step), through the bottom bar's own height setting | 🟠 the view stays still (verified), but the steps were still 3 m: the script could not reach the bottom bar; a second way to it is built |
| Esc or a right click goes back: the object follows the mouse again with the height and turn it was given | ✅ verified |
| A pinned object is let go when the tool is closed or destroyed (this fixed a dead right button and a crash after loading a save) | ✅ verified |
| The second click after a turn builds first time | ✅ verified |

#### 🚉 Stations, stops and departure boards

**Departure boards** (`tf3api_departure_boards`). A new model and new logic of this project's own, not a
conversion of an existing mod: a dot-matrix display whose lit points are written live into its texture by the
native layer, so they are part of the game's own picture. Departures and arrivals boards in three styles (modern
or heritage on a post, or hanging under a canopy) and seven casing colours. Place one within 100 m of a station
and it joins that station by itself and lists the next vehicles with line, platform and time, and a running
clock. A changed line is redrawn column by column as on a real board, and calling points scroll. A board serves
the platform it stands at by itself; Auto, All or chosen platforms are set in its window. Each style can also be
placed on a platform track: it lines up with the track and stands on the platform beside it. Click a board for
its window: a diagram of the station from above - platforms, tracks, buildings, stairs and the trains moving
through it, car by car - with every board as a marker at its place, a legend, an overview, and the board's layout
(National Rail, a platform board with calling points, metro, bus stop, or a station board) and dot colour. A
bulldozed board is forgotten. Boards show station names as signs do ("Maze Hill", not "Maze Hill Station").

| Piece | Status |
|---|---|
| Live writing into the screen texture, running clock | ✅ verified |
| Noted when built, kept in the save, joins the nearest station, live departures on screen | ✅ verified |
| Clicking a board (kept from the station behind it), its window, platform choice, automatic platform | ✅ verified |
| Station diagram with live trains | ✅ verified |
| Layouts, arrivals board, refresh and scrolling, styles, casing and dot colours, menu pictures, the hanging board, removal on bulldozing | ✅ verified |
| Different content on boards at different stations | ✅ verified |
| A bulldozed board also taken off the station diagram | 🟠 it stayed on the diagram; fix built |
| Boards placed at the track snap to it | 🟠 they did not snap; fix built (the snap point now names the track as the game's own rail depot does) |
| Station picker when several stations are in reach, large station boards | ⏳ planned |

After cloning, run `python -I tools/build_boards.py <folder with the three board models>` to generate the
screens' textures and the menu pictures.

**Station names as signs read them** (`tf3api_station_names`, text only, and the road-names mod) - ✅ stations
already built are renamed in the game; 🟠 a newly built station still came out as "X Station" (the game does not
take the text mod's pattern), so the road-names mod now renames new stations too (built). New stations are named
after their place - "Maze Hill", not "Maze Hill Station" - which is how the older Transport Fever named passenger
stations and how real signs read. The game's own variants for a second station in a town follow ("Maze Hill
Central", "Upper Maze Hill"). Stations already built are renamed by the road-names mod the same way, only
where the game made the name ("Maze Hill Station Central" becomes "Maze Hill Central"); a name you typed is never
touched.

**Bus and tram stops named the London way** (part of `tf3api_road_names`) - ✅ verified. Small
stops on the street are named as London names them, from TfL's bus stop standard and the national stop register's
naming guidance: after the rail station they serve ("Southwark Station", or "Southwark Station / Southwark High
Road" on a High Street or numbered road), else after the nearest side road ("Mint Street"), and where that is
taken after the road joining it ("West Hill", or "Oak Road / West Hill" when a bus route uses it). The first half
of a two-part name is always the road the stop sits on or the station it serves. Names are unique on the map.
Stops already in a save are renamed too; a stop the player renamed is theirs for good. Termini and bus stations
keep the station naming. Rules and sources: [`re_notes/map_export/bus_stop_names.md`](re_notes/map_export/bus_stop_names.md).

#### 🛣️ Roads, names and maps

Road names (`tf3api_road_names`): streets grouped from the game's road segments, named and numbered the British
way, drawn on the roads by the native layer, each with a window of its own.

| Piece | Status |
|---|---|
| Grouping road segments into streets, generating names and road numbers (British conventions) | ✅ verified on one save (8,534 segments, 1,011 streets); the rules are still being tuned in the game |
| A and B roads from what the roads connect; motorway carriageways, slip roads, roundabouts, split carriageways | ✅ used in the game; still being tuned |
| A road passing under or over another does not take its name | ✅ verified |
| Map export to interactive HTML, SVG, GeoJSON and OpenStreetMap XML | ✅ verified on the same save |
| Terrain and water on the street map: heights and water sampled in the game a little each frame, drawn as shaded relief with water in blue under the roads (HTML page and SVG) | 🟡 built; tested outside the game with made-up heights. Not in the GeoJSON and OpenStreetMap files yet |
| Road names drawn on the roads in the game, by the native layer | ✅ verified: number shields and names sit on the right roads; hidden when zoomed in past 70% |
| Zoomed far out (below 20%) only A, M and A(M) badges; labels fade and soften at the screen edges | 🟡 built |
| Road labels drawn under the game's interface | ✅ verified |
| Click a shield or name to open the road's window | ✅ verified: the window opens with the number on its sign, the name on a nameplate, kind, length and postcode |
| Changing a road in its window: name, road type (ordinary, B, A, A (M), motorway), what its label shows | ✅ verified; a typed name is taken on Enter or when the field loses focus |
| Your own road number for any road, kept for good; one number can run over several roads, and a road that had it gets another | 🟡 built; tested offline |
| Names follow building work: a road keeps the name and number it was given | ✅ verified |
| A name the player gives a road is kept: it follows the road through building work and type changes, except to motorway (known by number only) | ✅ verified |
| Only one road or junction window open at a time | ✅ verified |
| Road names worked out on a worker thread, off the game's threads | ✅ verified (a re-naming after a change answered in 8 ms in one session) |
| Writing the street map page from inside the game | ✅ verified |
| Motorway junction numbers, on the roads and on the street map page; click one for its window (what it connects, distances, postcode) | ✅ verified |
| Postcodes and cities on the street map page (postcode under the pointer, search by district, city outlines) | ✅ verified |
| What a road can carry (lanes, speed limit, theoretical vehicles an hour) in the window | 🟡 built; tested offline only. Measured traffic is planned |
| Names, numbers and the player's choices saved with the game | 🟡 handing over for saving seen in the game; a load reading them back not yet watched; a save loaded without the mod not yet tried |
| Postcodes for every spot on the map (British form, areas around the biggest towns, any map size), shown in the road window | ✅ verified |
| Marking a cut-off road abandoned: it loses its number and shows an "Abandoned" badge with its name | ✅ verified |
| "Adjust road" tool: a green line along the road with a circle at each end; take an end to another junction to shorten the road or draw it out along other roads, by whole segments | ✅ verified, including long roads and roads with bridges. 🟠 A road could not be drawn across a roundabout; a roundabout now counts as one junction for the tool (built, tested offline) |
| Cities: draw a line around several towns to define them as one city, editable later. Zoomed out, the city's name is shown in place of its towns' names; zoomed in past 35% the towns' own names return. A city can have its own postcode scheme: London's compass districts, only for a drawn city named London or Greater London (any case). The city's label and window reuse the game's own town label and town window | 🟡 the rules are built and tested offline (one place for road numbers, one postcode area, roads named after it). The drawing tool is built and used in the game: a city can be drawn and made, and London-style postcodes are only offered for a city the player drew and named London or Greater London. ⏳ Nothing shows the city on the map in the game yet: the label, the window and editing an outline afterwards are not started |
| Road systems for other countries as editable profiles (UK, US, Germany, France, generic) | ⏳ planned |
| Per-quantity unit settings for the whole game interface | ⏳ planned |
| Floating button and main settings panel | ⏳ planned |

#### 🕰️ Time

**Day clock** (`tf3api_day_clock`, a script mod, enabled per save) - ✅ used in the game. A clock that runs in
real time at normal game speed, with a choice of how the calendar goes with it: Realistic (a calendar day is 24
hours of play), Balanced (one hour) or Transport Fever (the game's own pace). The sun and moon follow the clock
unless switched off, and in the two long-day modes vehicle wear and age follow the calendar (by scaling each
model's lifespan as it loads; nothing about wear is written into saves). Built on the game's own calendar speed
and time of day. Works alongside the Timetables mod: both show the same time. The departure boards' clock is the
same clock. The sky's cycle stays the game's own choice: while the continuous cycle is chosen in the game's menu,
the sun and moon follow the clock; Custom keeps the game's own time slider. (🟡 Built; not yet seen.)

#### 🔁 Older mods: the converter

Put a Train Fever, Transport Fever 1 or Transport Fever 2 mod's folder into `legacy_mods` in the game's folder
(the layer creates it at launch). At the next launch it is converted, before the game lists its mods, into a new
mod `legacy_<name>` that appears in the mod list; the old folder is only read. Each converted mod has a
`conversion_report.txt` saying what was converted, what was missing and what was left out. Fixes are rules for
every mod of a kind, never hand edits to one mod: trains and buses are meant to work with no manual work.

Tried so far on two dozen mods: four rail multiple units (one from Transport Fever 1, three from Transport Fever
2), eight bus packs, two modular station mods, two track packs, two packs of small stations, a sign pack and three
billboard packs it builds on.

| Piece | Status |
|---|---|
| Conversion at launch from `legacy_mods`, once per mod, redone when the old mod or the rules change | ✅ verified. A full re-conversion of many mods can take up to a minute, during which the game shows nothing; a progress window is planned |
| Vehicles: old group-form models to node trees, dropped material types mapped, a mod's own scripts run, cargo names, seats, doors, multiple units, list and shop pictures, sound sets, lifespan | ✅ verified on the four rail units |
| Road vehicles: wheels and axles named as the game finds them, meshes and animations of other mods, stock dirt textures, labels tied to their parts, engine sounds, door events | 🟡 buses from eight packs convert and run in a first short test; a fuller test with many models is still to do |
| Lamps: the older games' stock lamp parts replaced by lamps of the converter's own, the mod's own lamp pictures kept (bright `.hdr` pictures rewritten as ordinary ones), light beams added, head and rear lamps switched by which end of the train they are at, rear lamps and lamps by day | ✅ verified on four units |
| Lighting textures (normal maps): read as the older games read them, and their unpainted parts made flat (they lit parts of a body as if they faced away) | ✅ verified |
| Text on models (destination displays) at the newer game's scale | ✅ verified close up; 🟠 hard to read at a distance (see [Known gaps](#known-gaps)) |
| Body sides with the windows painted into the same picture as glass: the paint drawn solid, the glass by a second, blended material on a copy of the part | ⏸ experimental, off by default (`[Converter] GlassParts=1`): with it a converted train was seen folded up and with a dark cast over parts of its body |
| Textures: `.tga` written as `.dds` with mip levels; missing textures and materials stood in for | 🟡 built; uncompressed unless `PackTextures=1`, so large |
| Mods that build on other old mods: files found in the other mods in `legacy_mods`, dependencies written | ✅ verified on the sign and billboard packs |
| Assets and other plain constructions (signs, billboards, props) | ✅ verified: billboards can be placed |
| Transport Fever 2 modular station mods (the construction, its modules and helper scripts carried over and run through an adapter shipped with the converted mod; the station is built by the game's own station script) | ✅ behind `[Converter] Stations=1`. Verified on two station mods, one building on the other: builds, is configurable, add-ons, later changes, platform signs, buildings, walking paths, boarding, underpasses |
| Whole rail stations built by one construction (stops and walking lanes into the newer game's form) | 🟡 they place in the game; trains and passengers using them not yet tried |
| Kinds of track (`res/config/track`): the newer game's street style and two templates, without and with overhead wire; converted stations lay them | ✅ verified |
| Remasters: a short list of changes for one particular old mod, made to its converted copy (an engine type, added text labels, part of a texture painted over). The old mod is not touched and nothing of it is in this repository. First one: a Docklands Light Railway unit made electric, with the destination painted on its blind replaced by a live one | ✅ verified. The blind's text is drawn lit and its panel glows from behind, made by the remaster through the game's own lit-window material (built, not yet seen) |
| Ships' and aircraft's moving parts, rendered shop pictures, repaints, zipped mods, a progress window, optional upscaling of low-resolution textures | ⏳ planned |
| Bridge and tunnel kinds, depots, road, water and air stations, cargo stations, mods that are scripts | ❌ not converted |

Modelled on EAT1963's "TPF1 --> TPF2 Konverter" for what a conversion has to do; none of its code is used. A
converted mod is still the original author's work: do not share one without their permission. A converted mod
only offers what it adds while the old mod it was made from is still in `legacy_mods` and the native layer is
loaded; passed on by itself it adds nothing. (🟡 Built; not yet seen in the game.)

#### 🧩 The platform for other mods

| Feature | Status | Notes |
|---|---|---|
| Script bridge (`tf3api` table, API version 18) | ✅ verified | `version`, `has(name)`, `log(text)`, `writeFile(name, text)`, `post(channel, text)` / `take(channel)` between script states, road labels, board screens and colours, click spots that win over what stands behind them, the station plan, the placement mode. Reference: [`re_notes/platform/api.md`](re_notes/platform/api.md). Files go to `tf3api_out` in the game folder; plain file names and data or document extensions only. |
| Worker thread with its own Lua state (`workerStart`, `workerRun`, `workerTake`) | ✅ verified | For moving a script mod's heavy computation off the game's threads. The road-names mod names the roads on it. |
| Overlay renderer | ✅ verified | The DLL's own drawing: text and rectangles. Drawn inside the game's own pass onto the screen, after the picture of the world and before the interface, so it lies under the game's windows, buttons and bars. Falls back to drawing on the finished frame. The base for road names in the world. Off by default. |
| Writing into the game's own textures | ✅ verified | How the departure boards' screens and the station diagram's pictures are drawn: a texture of a known size is found among the game's images and written from the DLL, with the game's own mip levels. |
| Calls from native code back into scripts (events) | ⏳ planned | Clicks and messages are polled for now. |

#### 📊 Diagnostics

| Feature | Status | Notes |
|---|---|---|
| Sampling profiler | ✅ verified | CPU time per thread and per function, including which script file and line the time belongs to. Can run continuously. |
| Vulkan frame statistics | ✅ verified | Frame times, time spent waiting in Vulkan calls, draw calls, render passes by size, texture and buffer traffic, GPU load. |
| Allocation profiler, `bad_alloc` probe | ✅ verified | For memory investigations. Off by default. |

### In progress

- 🛣️ **Road traffic and route finding.** A review of how road vehicles choose and change lanes
  ([`re_notes/engine/road_traffic.md`](re_notes/engine/road_traffic.md)) found that they can only change lane
  where one piece of road meets the next. That is why a bus at a kerb stop takes another route to turn, why
  vehicles rarely overtake and why traffic waits behind stopped buses. Planned, in the engine: lane changes
  anywhere along a road as a manoeuvre over a realistic distance, with a gap in the target lane, signalled and
  seen by other traffic; several lanes at once only as an exception (mostly buses pulling out of a stop); a
  route search that knows lanes can be changed; overtaking settings; bus stop bays; a faster route search.
  These change how vehicles drive, so they will be per-save options. Nothing built yet.
- ⬅️ **Left-hand traffic, natively in the engine.** The engine itself keeps the side: lanes, junction lanes,
  painted arrows and stops made for the save's driving side, one-way roads unchanged, built on the lane-change
  work above rather than a "keep left" rule. Not by converting saves or patching road data as earlier mods did.
  Saves keep every road's network as built, and the engine re-plans vehicles and people after every rebuild
  ([`re_notes/left_hand_traffic/`](re_notes/left_hand_traffic/)). Not usable yet.
- 🔎 **Finding hooked functions by what they are, not only by their bytes.** Each hook has one byte pattern, and
  a feature switches itself off when its pattern no longer matches. The game's assertions carry texts that stay
  the same from build to build; a function can be found as the one function that refers to a given set of them.
  The resolver is built and tested against the current executable on disk (no wrong answers in 400 cases; it
  refuses where texts are shared), and the occlusion module's scene hooks fall back on it. Hooks into code
  without such texts (the Lua interpreter, for one) still rest on bytes alone. Not yet seen to rescue a hook on
  a real update: that needs the next game build.
- 🧠 **Learning the engine as a whole.** Real names for several thousand of the game's functions were recovered
  from its assertions, and the older game's executable was analysed beside it. Reports on streets, navigation,
  road traffic, assets and game time are under [`re_notes/engine/`](re_notes/engine/). Further reports
  (movement, people and cargo, construction) follow, and features are built on them - first of all a converter
  that handles any old mod.

### Further out

- DLSS / upscaling through NVIDIA Streamline. NVIDIA-only, opt-in, and only useful where the graphics card is
  the limit.
- **A converter for Train Simulator content**, unattended like the one for older Transport Fever mods: put the
  content in a folder, start the game, find it converted in the mod list. An idea for later; none of the formats
  have been looked at.
- Maps that can grow beyond their original bounds. Exploratory.
- **Stations on freely drawn track, with car stop markers.** A change to the game's own logic. Today a station's
  platform tracks are built into the station as part of its construction. Instead:
  - platforms stand along ordinary track the player draws freely, with stopping points placed on it;
  - the game's own station constructions (and converted ones) have their built-in tracks taken out when they are
    placed, so every station stands on drawn track;
  - as on British railways, a platform can have a stopping point per train length - car stop markers for 2, 4,
    8 and 12 cars. A driver stops with the front of the train at the marker for its length, so a short train
    stops where its passengers are rather than at the far end of a long platform. (Several markers on one
    platform risk the wrong one being used; a common stopping point is preferred where practical. Some stations
    colour the signs by length, but that is local practice, not a network-wide code.)
  - a train's length in cars is what it really is, not the number of units bought: a multiple unit is already
    several cars (the Docklands P86 places as two cars per unit), and a train may be several units coupled. So
    the cars are counted from the train's own vehicles, and a model that is more than one car (an articulated
    unit) counts as its cars, by its own data or by its length;
  - the departure boards and their station diagram follow: a board can say where a train stops, and the diagram
    shows the markers. The diagram already finds a platform's track from its stopping point through the game's
    network, so it does not depend on the station's built-in track.
  Needs the game's stopping logic and how stations tie stops to track read first. Not started.
- **Dynamic displays on board trains, with announcements.** Passenger information inside and outside every train:
  destination and calling points on the front and side displays and on screens in the cars, updated live from the
  train's line ("Calling at: A, B, C ..."). It must work on any train model, the game's own, mods and converted
  ones, so the displays are placed on each model by itself ("smart placement": by its windows, doors and ends,
  rather than by hand per model). The same information is spoken by text-to-speech: "Welcome aboard this service
  to ... Calling at: ..., ... and ...", and the next stop as the train approaches it. Builds on the live writing
  into textures used by the departure boards. An idea for later; not started.
- **A network map.** The departure boards' station diagram grown into a map of the whole network: lines,
  stations and platforms, with trains moving on it, in the manner of the network maps of the Minecraft Transit
  Railway mod by Jonathan Ho (a behavioural reference; nothing of it is used). Not started.
- **Trains that change ends.** The game turns a whole train round to reverse it. The idea: a train reverses where
  it stands, with its lamps and driving end following. A change to the game's own behaviour, so it needs the
  simulation looked at first.
- **Multiplayer.** The last item on the list, after everything above. It would be a mode of its own, built from
  the ground up, not single-player with networking added on: single-player stays exactly as it is. Nothing has
  been looked at.

### Known gaps

Sorted by impact. The full list, each with its status and history, is
[`re_notes/known_issues.md`](re_notes/known_issues.md).

| # | Gap | Priority | Current status |
|---|---|---|---|
| 1 | Road vehicles change lane only where one piece of road meets the next | 🔴 High | Reviewed; the planned fix is in [In progress](#in-progress) |
| 2 | Text on converted models (destination displays) breaks up into dots at a distance | 🟠 Medium | The cause is in how the game draws such text, not in the converted model; not solved |
| 3 | Converting old mods happens before the game shows a window | 🟠 Medium | With many mods the game seems not to start for up to a minute after the rules change; a progress window is planned |
| 4 | Cities drawn by the player have nothing to show them on the map in the game | 🟠 Medium | The rules use them; the city label (the game's own town label, reused) is not started |
| 5 | Road labels are drawn without depth, and a click on a label also reaches the game | 🟡 Low | Terrain and buildings in front of a road do not hide its name |
| 6 | The memory growth seen in the cockpit view deep underground | 🟡 Low | Not explained yet |
| 7 | Converted textures are uncompressed and large unless `PackTextures=1` | 🟡 Low | Packed output is built and waiting to be seen in the game |
| 8 | Road names are not read back from a save | 🟡 Low | On purpose for now: the road-names mod's `ignoreSavedData` development switch is on until the naming is good enough to keep in a long-running save. It and the development city in `names.lua` are cleared before a release |

Everything built but not yet seen in the game, with what to look for in each case, is listed in
[`re_notes/testing_checklist.md`](re_notes/testing_checklist.md).

<details>
<summary><b>Why several features are "built, not yet seen"</b></summary>

Development runs in batches: a batch reads the game's own code and data first, builds what it found, tests it
outside the game, and is then handed over for one look in the game. The latest look (14 October 2026) confirmed
most of the previous batch; its leftovers - the middle-button height steps, names of newly built stations, boards
snapping to the track, removed boards on the station diagram, Adjust Road across roundabouts - have second fixes
built, and the street map has gained terrain and water. Those are waiting for the next look. The profiler slows the game while it samples; continuous mode is a
development aid, not something to leave on.

</details>

## Honest results

All figures are from one machine (RTX 2080 Ti, Ryzen 5 9600X, 2560x1440, highest settings) and one early-to-mid
game save, measured with the built-in profiler. They are single sessions, not averaged benchmark runs, and will
differ on other hardware and saves.

- **Shadow map limit, cockpit view.** At 4096x4096 the game rendered 27 shadow passes per frame, about 77% of all
  pixels drawn. Limiting to 2048 took the cockpit view from roughly 20 fps to roughly 40 fps. Going lower gave
  nothing further. No change in the zoomed-out view.
- **Town label fix, zoomed-out view.** The label script's CPU cost fell from 3.4-3.7 s per 10 s to under 0.1 s.
  Frame time went from 28-30 ms to 25-26.5 ms, about 10%.
- **Occlusion culling.** It removes 17-18% of the objects it tests, with no visible change in frame rate. The
  frame was limited elsewhere. It stays in the tree as groundwork and is off by default.
- **A draw-distance and LOD-distance mod** in the style of the Transport Fever 2 "Performance tuning" mod was
  tried and withdrawn: visible loss of detail for little gain. It is kept in `mod/` as shelved.

What the profiling showed about the game on this save: the cockpit view is limited by the graphics card, mostly by
shadow rendering and full-screen passes; the zoomed-out view is limited by the main thread, where drawing and
updating the interface cost several times more than the 3D scene. A third-party script mod was also found using
39% of the main thread during its scans, which is the kind of thing the profiler is for.

## How it works

- **Injection.** `winhttp.dll` sits beside `TransportFever3.exe`. The game loads it in place of the system library
  of that name, and it passes every call through to the real one. No external injector, nothing patched on disk.
- **Engine hooks.** Engine functions are found at startup by signature scanning (a byte pattern that must match
  exactly once), resolved once and cached for the session, then hooked with MinHook or called directly. A pattern
  that matches nowhere or more than once switches its feature off and is logged.
- **Vulkan.** The game loads Vulkan at runtime; the DLL wraps the functions the game asks for, which gives the
  frame statistics, the overlay drawn inside the game's own pass, and writing into the game's textures.
- **Scripts.** The DLL registers a `tf3api` table in each of the game's Lua states, and runs a Lua state of its
  own on a worker thread. The script mods use it where the official API stops.
- **Converter.** Its rules are Lua, run by an interpreter built into the DLL at launch, before the game lists its
  mods; it writes new mod folders and never touches the old ones.
- **Reverse engineering.** Static analysis of the game's executable (Ghidra), with function names recovered from
  the game's own assertion texts; findings are written up in [`re_notes/`](re_notes/) with how each was
  confirmed. Live debugger attach is not used.

## Which game build this is developed against

**TF3OpenAPI was developed against the launch build of Transport Fever 3, build 40408 (29 September 2026). From 12
October 2026 development and testing move to build 40420 (the first stability update, 8 October 2026).** It runs
on 40420: in a session on that build (the game's log gives the build number) every signature resolved in the
running game, the DLL's hooks installed, the mod converter ran at launch and its converted vehicles and stations
were used in the game. One signature needed loosening for 40420 (see the patch notes). Since then the road names,
the worker thread, the overlay under the game's interface, the departure boards, the two-step placement and the
mod converter have all been used on 40420, and so has the cockpit depth fix deep underground. Occlusion culling is
left off there.

No engine address is hard-coded. Because every hook is found by signature, most features should carry forward to
newer builds unchanged, and a feature whose function was rewritten should switch itself off rather than
misbehave. That is the design, not a test result: one of some thirty signatures had to be changed for 40420 (a
stack-frame size inside it differed), and a feature not listed above as seen on 40420 should be treated there as
unverified. Some hooks can also be found by the texts of the game's own assertions when their bytes change (see
[In progress](#in-progress)).

Windows only. The script-only mods in `mod/` that do not need the DLL are not tied to Windows.

## Installation

Nothing here is packaged for release yet. For development builds:

1. Requires a legitimate copy of Transport Fever 3.
2. Build `native/tf3api.vcxproj` (x64, Release) with Visual Studio (MSVC, MSBuild, Windows SDK). The output is
   `winhttp.dll`.
3. Copy `winhttp.dll` next to `TransportFever3.exe`.
4. Optionally put a `tf3api.ini` next to it (see below). Without one, defaults apply.
5. Script mods: copy a folder from `mod/` into the game's `mods` folder and enable it for a save. For the
   departure boards, first run `python -I tools/build_boards.py <folder with the three board models>`.
6. Old mods to convert: put their folders into `legacy_mods` in the game's folder and set `[Converter] Enabled=1`.

To remove: delete `winhttp.dll`, `tf3api.ini` and the `tf3api` log and profile files from the game folder. The
game and its saves are left as they were. Names the mods gave to roads and stops stay in a save as the game's own
names.

### Settings (`tf3api.ini`)

Every feature has its own switch. A feature stays off by default until it has been verified and measured.

| Section | Key | Meaning |
|---|---|---|
| `[Camera]` | `CockpitDepthFix` | 1 = cockpit view follows vehicles below -100 m |
| `[Shadows]` | `MaxResolution` | Largest shadow map edge in pixels; 0 = unchanged |
| `[Shadows]` | `ToggleKey` | Key that switches the limit off and on while playing (118 = F7) |
| `[Occlusion]` | `Enabled`, `Cull`, `ToggleKey`, ... | `Enabled=1` installs the hooks (the road names need the camera they read); `Cull=0` culls nothing (default 1); tuning |
| `[Profiler]` | `Enabled`, `Continuous`, `Seconds`, `RateHz`, `Key`, `Keep`, `VulkanStats` | Profiler and frame statistics |
| `[Debug]` | `BadAllocProbe`, `AllocProfiler` | Memory diagnostics |
| `[Bridge]` | `Enabled` | 1 = register the `tf3api` table in the game's script states |
| `[Overlay]` | `Enabled`, `ToggleKey`, `Font`, `UnderInterface` | The overlay renderer (117 = F6). `UnderInterface=0` draws on the finished frame, over the game's interface |
| `[RoadNames]` | `Enabled`, `MinHeight`, `MaxHeight`, `LogStats` | Road names in the world and the camera heights that define the zoom scale |
| `[Worker]` | `Enabled`, `SelfTest` | The worker thread's own Lua state |
| `[Converter]` | `Enabled`, `Stations`, `Remasters`, `GlassParts`, `PackTextures`, `StationDebug` | `Enabled=1` converts the old mods in `legacy_mods` at launch (default 0); `Stations=1` also converts constructions: stations, their modules, assets (default 0); `Remasters=0` leaves out the changes for particular mods (default 1); `GlassParts=1` draws painted-in window glass with a second copy of each part (experimental, default 0); `PackTextures=1` writes converted pictures packed as the game's own are, a quarter to an eighth of the size (default 0 until seen in the game); `StationDebug=1` makes a converted station write its walking lanes to `tf3api_out` each time it is built (default 0) |
| `[Boards]` | `Enabled`, `RefreshMs`, `PlanView` | `Enabled=1` writes the departure boards' screens (default 0); `RefreshMs` how long a changed line takes to be drawn in (default 1600; 0 = at once); `PlanView=1` lets a live picture in a window look straight down (no longer used; default 0) |
| `[Placement]` | `ConfirmObjects`, `InputFilter` | `ConfirmObjects=1` places objects in two steps while the game's drag-and-confirm option is on (default 0); `InputFilter=0` stops keeping the right and middle buttons and Esc from the game while an object is pinned (default 1) |
| `[Lighting]` | `MaxLightsPerBucket` | Lights per screen bucket at night; 0 = the game's 64 (default). 256 removes the dark rectangles over towns |
| `[Vulkan]` | `Hooks` | 0 = do not hook the game's Vulkan lookups (disables frame statistics, the overlay and the board screens) |

Logs go to `tf3api.log`, profiler reports to `tf3api_profile.txt` and the `tf3api_profiles` folder, all next to
the game executable.

## Distribution

TF3OpenAPI will be released on **Nexus Mods and GitHub**. The native layer will not be published through the
in-game mod browser (mod.io), whose rules require mods to use only the official scripting API. Script mods that
need the native layer will say so.

It is and will stay free. It contains no game files and no game code.

## Repository layout

| Path | Contents |
|---|---|
| [`native/`](native/) | The DLL: hooks, fixes, profiler, Vulkan statistics, script bridge, overlay renderer, board screens and station plan pictures, two-step placement, mod converter host |
| [`converter/`](converter/) | The mod converter: its rules (`convert.lua`), the adapter shipped with a converted station mod (`station_shim.lua`) and the changes for particular mods (`remasters.lua`), built into the DLL by `tools/embed_converter.py` |
| [`mod/`](mod/) | Script mods: `tf3api_road_names` (road names, maps, stop names), `tf3api_departure_boards`, `tf3api_placement`, `tf3api_day_clock`, `tf3api_station_names`, `tf3api_hud_fix`, `tf3api_left_hand_traffic` (not usable yet), `tf3api_performance` (shelved) |
| [`tools/`](tools/) | `road_map.py` (map export), `build_viewer.py`, `build_boards.py` and `board_font.py` (departure board models, screens and font), `embed_converter.py`, `embed_board_font.py`, `key_census.py` (what old mods contain against what the converter handles), `annotate_profile.py`, `check_signatures.py`, `make_sig_cases.py`, `build_shaders.py`, `ghidra/` (reverse-engineering scripts), tests in `tests/` |
| [`re_notes/`](re_notes/) | Notes: renderer, camera, shadows, Lua, road names, stop names and map export (`map_export/`), the mod converter (`converter/`), the engine's systems (`engine/`), departure boards (`boards/`), placement controls (`ui/`), left-hand traffic, the script API (`platform/api.md`), and the list of known issues (`known_issues.md`) |
| [`PATCHNOTES.md`](PATCHNOTES.md) | Development log by feature, with the commits behind each entry |

## Credits

Third-party code, each under its own licence:

- **[MinHook](https://github.com/TsudaKageyu/minhook)** by Tsuda Kageyu - function hooking (BSD 2-Clause), with a
  local change so functions compiled with AVX instructions can be hooked.
- **[Masked Software Occlusion Culling](https://github.com/GameTechDev/MaskedOcclusionCulling)** by Intel
  (Apache 2.0).
- **[Lua](https://www.lua.org/)** 5.4 by Lua.org, PUC-Rio (MIT) - runs the mod converter's rules.
- **[Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers)** by the Khronos Group (Apache 2.0 / MIT).

References whose behaviour was studied; no code or assets were taken from any of them:

- "Performance tuning" for Transport Fever 2 by okeating (the draw-distance experiment).
- How Cities: Skylines presents road names (the road-name interface).
- EAT1963's "TPF1 --> TPF2 Konverter" (what a conversion has to do).
- The Transport Fever 2 arrivals and departures displays by lollus and badgerrhax (how departure boards join a
  station and what they show).
- Transport for London's bus stop graphics standard and the national stop register's (NaPTAN) naming guidance
  (stop names); British road numbering and postcodes (road names).
- The Minecraft Transit Railway mod by Jonathan Ho (the planned network map).

Transport Fever is a trademark of Urban Games. This project is not endorsed by or affiliated with Urban Games or
Paradox Interactive.

## Support this project

This is built and maintained in spare time, at no cost to players - no ads, no paywalled features, nothing ever
sold (the licence itself forbids it, see below). If it has been useful to you, a donation is completely optional
but appreciated.

[![Support on Ko-fi](https://img.shields.io/badge/support-ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/officialk8)

## License

TF3OpenAPI's own code is under a custom permissive licence - see [`LICENSE`](LICENSE). The source is open: free to
use, change, fork and redistribute with attribution. The one restriction is that neither it nor anything derived
from it may be sold or put behind a paywall; because of that it is not "open source" in the OSI sense. It grants
no rights to Transport Fever 3 itself - you need your own copy of the game.
