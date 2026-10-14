# TF3OpenAPI

> Formerly "TF3 Optimizations + DLSS". Files, settings and mod ids use the short name `tf3api`.

**An unofficial expansion of Transport Fever 3, built into the game itself.**

TF3OpenAPI fixes, extends and improves Transport Fever 3 from the inside: a native layer that lives in the
game process and works with its engine directly, a set of script mods that use it, and a converter that
brings older Transport Fever mods across. It started as a few performance fixes. It is now closer to a
community patch, in the way the MW32011NCP project treated its game, than to a programming interface: the
aim is to make the game better and larger while it still feels like the same game.

That means:

- **Faithful to the game.** New things use the game's own parts wherever it has them: its windows and
  interface toolkit, its tools and build commands, its textures, its station and construction scripts, its
  own two-step building option. A departure board's dot-matrix screen is a texture of the game's, written
  live; a converted station is built by the game's own station script; a turned object is turned by the
  game's own rotation setting.
- **Natural to the engine.** The engine is learned before it is changed: functions are found by reverse
  engineering, systems are written up (`re_notes/engine/`), and a feature hooks the place where the game
  itself does the thing.
- **True to the real world where the game models it.** Roads are numbered and named the British way, stops
  the way London names them, departure boards look and behave like National Rail's, and each such rule is
  researched first and written down with its sources.
- **Nothing silently broken.** The simulation is left as the game runs it unless a feature exists to change
  it, and then only per save, on request. Saves load in the unmodified game. A feature whose engine function
  cannot be found on a game build switches itself off and says so in a log.

The "API" in the name is the part other authors can use: the native layer registers a `tf3api` table in the
game's scripts with functions the official modding API lacks. It is one part of the project, not all of it.

It is unofficial, free, and not affiliated with Urban Games or Paradox Interactive.

---

## How it is built

Four parts:

1. **Native core** - a DLL (`winhttp.dll`) the game loads beside its executable. At startup it finds the
   engine functions it needs by signature scanning and hooks or calls them. The fixes, the profiler, the
   overlay renderer, the live departure-board screens, the two-step placement and the mod converter live
   here.
2. **Script mods** (`mod/`) - ordinary Transport Fever 3 mods, enabled per save: road names, departure
   boards, the day clock, placement, station names, the town label fix. Most use the native core where they
   need it and fall back or say so where it is missing.
3. **The mod converter** (`converter/`) - rules in Lua, run by an interpreter built into the DLL at launch:
   old mods put in a folder are converted before the game lists its mods.
4. **The platform for other mods** - the `tf3api` table: logging, file writing, messages between script
   states, a worker thread with its own Lua state, road labels, board screens, click spots, the station
   plan. Each function is added because a feature needed it, then documented (`re_notes/platform/api.md`).
   Engine addresses and layouts stay inside the DLL, so a game update is fixed in one place.

Principles the native layer holds to:

- **Read-only and render-only by default.** Anything that could change the simulation is marked as such and
  off unless asked for.
- **A mod's mistake must not take the game down silently.** Arguments are checked at the boundary and
  failures are written to a log.
- **Survive game updates.** If one function cannot be located on a new build, that feature reports itself
  unavailable and the rest still loads.
- **Open.** Public source, documented API, usable by other authors without asking.

---

## Which game build this is developed against

**TF3OpenAPI was developed against the launch build of Transport Fever 3, build 40408 (29 September 2026).
From 12 October 2026 development and testing move to build 40420 (the first stability update, 8 October
2026).** It runs on 40420: in a session on that build (the game's log gives the build number) every
signature resolved in the running game, the DLL's hooks installed, the mod converter ran at launch and its
converted vehicles and stations were used in the game. One signature needed loosening for 40420 (see the
patch notes). Since then the road names, the worker thread, the overlay under the game's interface, the
departure boards, the two-step placement and the mod converter have all been used on 40420. Not yet done
there: occlusion culling measured, and the cockpit depth fix deep underground.

No engine address is hard-coded. Every hook is found at startup by signature scanning: the DLL searches the
game's code for a byte pattern that identifies the function. A pattern must match exactly once; if it
matches nowhere or more than once, that feature is skipped and the reason is written to `tf3api.log`. The
game is never patched on disk.

Because of this, most features should carry forward to newer builds unchanged, and a feature whose function
was rewritten should switch itself off rather than misbehave. That is the design, not a test result: one of
some thirty signatures had to be changed for 40420 (a stack-frame size inside it differed), and a feature not
listed above as seen on 40420 should be treated there as unverified. Some hooks can also be found by the
texts of the game's own assertions when their bytes change (see "In progress").

Windows only. The script-only mods in `mod/` that do not need the DLL are not tied to Windows.

---

## What it does today

Status words used below: **verified** = run in the game and seen to work; **built** = written and tested
outside the game only; **planned** = not started.

### Fixes and performance

| Feature | Status | Notes |
|---|---|---|
| Cockpit camera depth fix | verified | The cockpit view is clamped to a world height of -100 m, so it breaks in deep tunnels. This removes the lower clamp. |
| Shadow map resolution limit | verified | The game sizes shadow maps from the screen (4096x4096 at 1080p, 1440p and 4K on High). This sets a maximum. |
| Town label fix (`tf3api_hud_fix`, script mod) | verified | Each town label fetched the state of every town to read its own. Now fetched at most once a second. |
| Terrain occlusion culling | verified to run, **no measured benefit** | Off by default. See "Honest results". |

### Building and placing

**Placing objects in two steps.** With the game's own option "Enable Drag-and-Confirm Construction Mode" on
(Settings > Advanced), stations, depots and assets get the step that option gives roads and track. Needs the
native layer (`[Placement] ConfirmObjects=1`) and the script mod `tf3api_placement`.

| Piece | Status |
|---|---|
| The first click pins the object; a second click builds it | verified |
| Holding the right mouse button and moving the mouse turns it in the game's own 10 degree steps, with the view held still | verified |
| Holding the middle button and moving the mouse up or down raises or lowers it in steps of 0.5 m (the game's fine step), through the bottom bar's own height setting | built |
| Esc or a right click goes back: the object follows the mouse again with the height and turn it was given | built |
| A pinned object is let go when the tool is closed or destroyed (this fixed a dead right button and a crash after loading a save) | built |

### Stations, stops and departure boards

**Departure boards** (`tf3api_departure_boards`). A new model and new logic of this project's own, not a
conversion of an existing mod: a dot-matrix display whose lit points are written live into its texture by
the native layer, so they are part of the game's own picture. Departures and arrivals boards in three styles
(modern or heritage on a post, or hanging under a canopy) and seven casing colours. Place one within 100 m
of a station and it joins that station by itself and lists the next vehicles with line, platform and time,
and a running clock. A changed line is redrawn column by column as on a real board, and calling points
scroll. A board serves the platform it stands at by itself; Auto, All or chosen platforms are set in its
window. Each style can also be placed on a platform track: it lines up with the track and stands on the
platform beside it. Click a board for its window: a diagram of the station from above - platforms, tracks,
buildings, stairs and the trains moving through it, car by car - with every board as a marker at its place,
a legend, an overview, and the board's layout (National Rail, a platform board with calling points, metro,
bus stop, or a station board) and dot colour. A bulldozed board is forgotten. Boards show station names as
signs do ("Maze Hill", not "Maze Hill Station").

| Piece | Status |
|---|---|
| Live writing into the screen texture, running clock | verified |
| Noted when built, kept in the save, joins the nearest station, live departures on screen | verified |
| Clicking a board (kept from the station behind it), its window, platform choice | window verified; the effect of the platform choice not yet reported |
| Station diagram with live trains | verified |
| Layouts, arrivals board, removal on bulldozing, refresh and scrolling, styles, casing and dot colours, menu pictures, automatic platform, boards placed at the track | built, not yet seen in the game |
| Different content on boards at different stations | not yet: the game turns boards into asset groups, which keep no settings, so they all show one screen |
| Station picker when several stations are in reach, large station boards | planned |

After cloning, run `python -I tools/build_boards.py <folder with the three board models>` to generate the
screens' textures and the menu pictures.

**Station names as signs read them** (`tf3api_station_names`, text only). New stations are named after their
place - "Maze Hill", not "Maze Hill Station" - which is how the older Transport Fever named passenger
stations and how real signs read. The game's own variants for a second station in a town follow ("Maze Hill
Central", "Upper Maze Hill"). Stations already built keep their names. Built, not yet seen in the game.

**Bus and tram stops named the London way** (part of `tf3api_road_names`). Small stops on the street are
named as London names them, from TfL's bus stop standard and the national stop register's naming guidance:
after the rail station they serve ("Southwark Station", or "Southwark Station / Southwark High Road" on a
High Street or numbered road), else after the nearest side road ("Mint Street"), and where that is taken
after the road joining it ("West Hill", or "Oak Road / West Hill" when a bus route uses it). The first half of
a two-part name is always the road the stop sits on or the station it serves. Names are unique on the map.
Stops already in a save are renamed too; a stop the player renamed is theirs for good. Termini and bus
stations keep the station naming. Built and tested offline, not yet seen in the game. Rules and sources:
`re_notes/map_export/bus_stop_names.md`.

### Roads, names and maps

Road names (`tf3api_road_names`): streets grouped from the game's road segments, named and numbered the
British way, drawn on the roads by the native layer, each with a window of its own.

| Piece | Status |
|---|---|
| Grouping road segments into streets, generating names and road numbers (British conventions) | verified on one save (8,534 segments, 1,011 streets); the rules are still being tuned in the game |
| A and B roads from what the roads connect; motorway carriageways, slip roads, roundabouts, split carriageways | built; tested offline only |
| A road passing under or over another does not take its name | built |
| Map export to interactive HTML, SVG, GeoJSON and OpenStreetMap XML | verified on the same save |
| Road names drawn on the roads in the game, by the native layer | verified: number shields and names sit on the right roads; hidden when zoomed in past 70% |
| Road labels drawn under the game's interface | verified |
| Click a shield or name to open the road's window | verified: the window opens with the number on its sign, the name on a nameplate, kind, length and postcode |
| Changing a road in its window: name, road type (ordinary, B, A, A (M), motorway), what its label shows | built; a typed name is taken on Enter or when the field loses focus |
| A name the player gives a road is kept: it follows the road through building work and type changes, except to motorway (known by number only) | built |
| Only one road or junction window open at a time | built; not yet seen in the game |
| Road names worked out on a worker thread, off the game's threads | verified (a re-naming after a change answered in 8 ms in one session) |
| Writing the street map page from inside the game | built; tested offline only |
| Motorway junction numbers, on the roads and on the street map page; click one for its window (what it connects, distances, postcode) | built; tested offline only |
| Postcodes and cities on the street map page (postcode under the pointer, search by district, city outlines) | built; tested offline only |
| What a road can carry (lanes, speed limit, theoretical vehicles an hour) in the window | built; tested offline only. Measured traffic is planned |
| Names, numbers and the player's choices saved with the game | handing over for saving seen in the game; a load reading them back not yet watched; a save loaded without the mod not yet tried |
| Postcodes for every spot on the map (British form, areas around the biggest towns, any map size), shown in the road window | built; tested offline only |
| Marking a cut-off road abandoned: it loses its number and shows an "Abandoned" badge with its name | built; tested offline only |
| "Adjust road" tool: a green line along the road with a circle at each end; take an end to another junction to shorten the road or draw it out along other roads, by whole segments | verified, including long roads and roads with bridges |
| Cities: draw a line around several towns to define them as one city, editable later. Zoomed out, the city's name is shown in place of its towns' names; zoomed in past 35% the towns' own names return. A city can have its own postcode scheme (for example London's compass districts). The city's label and window reuse the game's own town label and town window | the rules are built and tested offline (one place for road numbers, one postcode area, roads named after it). The drawing tool is built: a city can be drawn and made in the game, and London-style postcodes are only offered for a city the player drew. The label, the window and editing an outline afterwards are not started |
| Road systems for other countries as editable profiles (UK, US, Germany, France, generic) | planned |
| Per-quantity unit settings for the whole game interface | planned |
| Floating button and main settings panel | planned |

### Time

**Day clock** (`tf3api_day_clock`, a script mod, enabled per save). A clock that runs in real time at normal
game speed, with a choice of how the calendar goes with it: Realistic (a calendar day is 24 hours of play),
Balanced (one hour) or Transport Fever (the game's own pace). The sun and moon follow the clock unless
switched off, and in the two long-day modes vehicle wear and age follow the calendar (by scaling each model's
lifespan as it loads; nothing about wear is written into saves). Built on the game's own calendar speed and
time of day. Works alongside the Timetables mod: both show the same time. The departure boards' clock is the
same clock.

### Older mods: the converter

Put a Train Fever, Transport Fever 1 or Transport Fever 2 mod's folder into `legacy_mods` in the game's folder
(the layer creates it at launch). At the next launch it is converted, before the game lists its mods, into a
new mod `legacy_<name>` that appears in the mod list; the old folder is only read. Each converted mod has a
`conversion_report.txt` saying what was converted, what was missing and what was left out. Fixes are rules
for every mod of a kind, never hand edits to one mod: trains and buses are meant to work with no manual
work.

Tried so far on two dozen mods: four rail multiple units (one from Transport Fever 1, three from Transport
Fever 2), eight bus packs, two modular station mods, two track packs, two packs of small stations, a sign
pack and three billboard packs it builds on.

| Piece | Status |
|---|---|
| Conversion at launch from `legacy_mods`, once per mod, redone when the old mod or the rules change | verified. A full re-conversion of many mods can take up to a minute, during which the game shows nothing; a progress window is planned |
| Vehicles: old group-form models to node trees, dropped material types mapped, a mod's own scripts run, cargo names, seats, doors, multiple units, list and shop pictures, sound sets, lifespan | verified on the four rail units |
| Road vehicles: wheels and axles named as the game finds them, meshes and animations of other mods, stock dirt textures, labels tied to their parts, engine sounds, door events | built; buses from eight packs convert, not yet confirmed working in the game |
| Lamps: the older games' stock lamp parts replaced by lamps of the converter's own, the mod's own lamp pictures kept (bright `.hdr` pictures rewritten as ordinary ones), light beams added, head and rear lamps switched by which end of the train they are at, rear lamps and lamps by day | verified on four units |
| Lighting textures (normal maps): read as the older games read them, and their unpainted parts made flat (they lit parts of a body as if they faced away) | verified |
| Text on models (destination displays) at the newer game's scale | verified close up; hard to read at a distance (see Known limitations) |
| Body sides with the windows painted into the same picture as glass: the paint drawn solid, the glass by a second, blended material on a copy of the part | experimental, off by default (`[Converter] GlassParts=1`): with it a converted train was seen folded up and with a dark cast over parts of its body |
| Textures: `.tga` written as `.dds` with mip levels; missing textures and materials stood in for | built; uncompressed unless `PackTextures=1`, so large |
| Mods that build on other old mods: files found in the other mods in `legacy_mods`, dependencies written | verified on the sign and billboard packs |
| Assets and other plain constructions (signs, billboards, props) | verified: billboards can be placed |
| Transport Fever 2 modular station mods (the construction, its modules and helper scripts carried over and run through an adapter shipped with the converted mod; the station is built by the game's own station script) | behind `[Converter] Stations=1`. Verified on two station mods, one building on the other: builds, is configurable, add-ons, later changes, platform signs, buildings, walking paths, boarding, underpasses |
| Whole rail stations built by one construction (stops and walking lanes into the newer game's form) | built; simulated builds only |
| Kinds of track (`res/config/track`): the newer game's street style and two templates, without and with overhead wire; converted stations lay them | verified |
| Remasters: a short list of changes for one particular old mod, made to its converted copy (an engine type, added text labels, part of a texture painted over). The old mod is not touched and nothing of it is in this repository. First one: a Docklands Light Railway unit made electric, with the destination painted on its blind replaced by a live one | verified |
| Ships' and aircraft's moving parts, rendered shop pictures, repaints, zipped mods, a progress window, optional upscaling of low-resolution textures | planned |
| Bridge and tunnel kinds, depots, road, water and air stations, cargo stations, mods that are scripts | not converted |

Modelled on EAT1963's "TPF1 --> TPF2 Konverter" for what a conversion has to do; none of its code is used.
A converted mod is still the original author's work: do not share one without their permission. A converted
mod only offers what it adds while the old mod it was made from is still in `legacy_mods` and the native
layer is loaded; passed on by itself it adds nothing. (Built; not yet seen in the game.)

### The platform for other mods

| Feature | Status | Notes |
|---|---|---|
| Script bridge (`tf3api` table, API version 18) | verified | `version`, `has(name)`, `log(text)`, `writeFile(name, text)`, `post(channel, text)` / `take(channel)` between script states, road labels, board screens and colours, click spots that win over what stands behind them, the station plan, the placement mode. Reference: `re_notes/platform/api.md`. Files go to `tf3api_out` in the game folder; plain file names and data or document extensions only. |
| Worker thread with its own Lua state (`workerStart`, `workerRun`, `workerTake`) | verified | For moving a script mod's heavy computation off the game's threads. The road-names mod names the roads on it. |
| Overlay renderer | verified | The DLL's own drawing: text and rectangles. Drawn inside the game's own pass onto the screen, after the picture of the world and before the interface, so it lies under the game's windows, buttons and bars. Falls back to drawing on the finished frame. The base for road names in the world. Off by default. |
| Writing into the game's own textures | verified | How the departure boards' screens and the station diagram's pictures are drawn: a texture of a known size is found among the game's images and written from the DLL, with the game's own mip levels. |
| Calls from native code back into scripts (events) | planned | Clicks and messages are polled for now. |

### Diagnostics

| Feature | Status | Notes |
|---|---|---|
| Sampling profiler | verified | CPU time per thread and per function, including which script file and line the time belongs to. Can run continuously. |
| Vulkan frame statistics | verified | Frame times, time spent waiting in Vulkan calls, draw calls, render passes by size, texture and buffer traffic, GPU load. |
| Allocation profiler, `bad_alloc` probe | verified | For memory investigations. Off by default. |

---

## In progress

- **Left-hand traffic.** A mod of this project's own, built on what the engine was found to do
  (`re_notes/left_hand_traffic/`, `re_notes/engine/streets.md`): streets, the lanes inside stations, depots and
  industries, vehicles mirrored only where the mirror is right (text on displays turned round to stay
  readable) and otherwise not offered. The engine keeps the lanes a street or building was built with in the
  save, so existing saves need no reset of vehicles. So far: the rules for streets and for text on mirrored
  vehicles, tested outside the game. Not usable yet.
- **Finding hooked functions by what they are, not only by their bytes.** Each hook has one byte pattern, and
  a feature switches itself off when its pattern no longer matches. The game's assertions carry texts that
  stay the same from build to build; a function can be found as the one function that refers to a given set
  of them. The resolver is built and tested against the current executable on disk (no wrong answers in 400
  cases; it refuses where texts are shared), and the occlusion module's scene hooks fall back on it. Hooks
  into code without such texts (the Lua interpreter, for one) still rest on bytes alone. Not yet seen to
  rescue a hook on a real update: that needs the next game build.
- **Learning the engine as a whole.** Real names for several thousand of the game's functions were recovered
  from its assertions, and the older game's executable was analysed beside it. Reports on streets, navigation,
  assets and game time are under `re_notes/engine/`. Further reports (movement, people and cargo,
  construction) follow, and features are built on them - first of all a converter that handles any old mod.

## Further out

- DLSS / upscaling through NVIDIA Streamline. NVIDIA-only, opt-in, and only useful where the graphics card
  is the limit.
- **A converter for Train Simulator content**, unattended like the one for older Transport Fever mods: put the
  content in a folder, start the game, find it converted in the mod list. An idea for later; none of the
  formats have been looked at.
- Maps that can grow beyond their original bounds. Exploratory.
- **Stations on freely drawn track, with car stop markers.** A change to the game's own logic. Today a
  station's platform tracks are built into the station as part of its construction. Instead:
  - platforms stand along ordinary track the player draws freely, with stopping points placed on it;
  - the game's own station constructions (and converted ones) have their built-in tracks taken out when they
    are placed, so every station stands on drawn track;
  - as on British railways, a platform can have a stopping point per train length - car stop markers for 2, 4,
    8 and 12 cars. A driver stops with the front of the train at the marker for its length, so a short train
    stops where its passengers are rather than at the far end of a long platform. (Several markers on one
    platform risk the wrong one being used; a common stopping point is preferred where practical. Some
    stations colour the signs by length, but that is local practice, not a network-wide code.)
  - a train's length in cars is what it really is, not the number of units bought: a multiple unit is already
    several cars (the Docklands P86 places as two cars per unit), and a train may be several units coupled. So
    the cars are counted from the train's own vehicles, and a model that is more than one car (an articulated
    unit) counts as its cars, by its own data or by its length;
  - the departure boards and their station diagram follow: a board can say where a train stops, and the
    diagram shows the markers. The diagram already finds a platform's track from its stopping point through
    the game's network, so it does not depend on the station's built-in track.
  Needs the game's stopping logic and how stations tie stops to track read first. Not started.
- **A network map.** The departure boards' station diagram grown into a map of the whole network: lines,
  stations and platforms, with trains moving on it, in the manner of the network maps of the Minecraft Transit
  Railway mod by Jonathan Ho (a behavioural reference; nothing of it is used). Not started.
- **Trains that change ends.** The game turns a whole train round to reverse it. The idea: a train reverses
  where it stands, with its lamps and driving end following. A change to the game's own behaviour, so it needs
  the simulation looked at first.
- **Multiplayer.** The last item on the list, after everything above. It would be a mode of its own, built from
  the ground up, not single-player with networking added on: single-player stays exactly as it is. Nothing has
  been looked at.

---

## Honest results

All figures are from one machine (RTX 2080 Ti, Ryzen 5 9600X, 2560x1440, highest settings) and one
early-to-mid game save, measured with the built-in profiler. They are single sessions, not averaged
benchmark runs, and will differ on other hardware and saves.

- **Shadow map limit, cockpit view.** At 4096x4096 the game rendered 27 shadow passes per frame, about 77% of
  all pixels drawn. Limiting to 2048 took the cockpit view from roughly 20 fps to roughly 40 fps. Going lower
  gave nothing further. No change in the zoomed-out view.
- **Town label fix, zoomed-out view.** The label script's CPU cost fell from 3.4-3.7 s per 10 s to under 0.1 s.
  Frame time went from 28-30 ms to 25-26.5 ms, about 10%.
- **Occlusion culling.** It removes 17-18% of the objects it tests, with no visible change in frame rate. The
  frame was limited elsewhere. It stays in the tree as groundwork and is off by default.
- **A draw-distance and LOD-distance mod** in the style of the Transport Fever 2 "Performance tuning" mod was
  tried and withdrawn: visible loss of detail for little gain. It is kept in `mod/` as shelved.

What the profiling showed about the game on this save: the cockpit view is limited by the graphics card,
mostly by shadow rendering and full-screen passes; the zoomed-out view is limited by the main thread, where
drawing and updating the interface cost several times more than the 3D scene. A third-party script mod was
also found using 39% of the main thread during its scans, which is the kind of thing the profiler is for.

---

## Installing

Nothing here is packaged for release yet. For development builds:

1. Build `native/tf3api.vcxproj` (x64, Release). The output is `winhttp.dll`.
2. Copy `winhttp.dll` next to `TransportFever3.exe`. The game loads it in place of the system library of that
   name, and it passes every call through to the real one.
3. Optionally put a `tf3api.ini` next to it (see below). Without one, defaults apply.
4. Script mods: copy a folder from `mod/` into the game's `mods` folder and enable it for a save. For the
   departure boards, first run `python -I tools/build_boards.py <folder with the three board models>`.
5. Old mods to convert: put their folders into `legacy_mods` in the game's folder and set
   `[Converter] Enabled=1`.

To remove: delete `winhttp.dll`, `tf3api.ini` and the `tf3api` log and profile files from the game folder.
The game and its saves are left as they were. Names the mods gave to roads and stops stay in a save as the
game's own names.

### Settings (`tf3api.ini`)

Every feature has its own switch. A feature stays off by default until it has been verified and measured.

| Section | Key | Meaning |
|---|---|---|
| `[Camera]` | `CockpitDepthFix` | 1 = cockpit view follows vehicles below -100 m |
| `[Shadows]` | `MaxResolution` | Largest shadow map edge in pixels; 0 = unchanged |
| `[Shadows]` | `ToggleKey` | Key that switches the limit off and on while playing (118 = F7) |
| `[Occlusion]` | `Enabled`, `ToggleKey`, ... | Terrain occlusion culling and its tuning |
| `[Profiler]` | `Enabled`, `Continuous`, `Seconds`, `RateHz`, `Key`, `Keep`, `VulkanStats` | Profiler and frame statistics |
| `[Debug]` | `BadAllocProbe`, `AllocProfiler` | Memory diagnostics |
| `[Bridge]` | `Enabled` | 1 = register the `tf3api` table in the game's script states |
| `[Overlay]` | `Enabled`, `ToggleKey`, `Font`, `UnderInterface` | The overlay renderer (117 = F6). `UnderInterface=0` draws on the finished frame, over the game's interface |
| `[RoadNames]` | `Enabled`, `MinHeight`, `MaxHeight`, `LogStats` | Road names in the world and the camera heights that define the zoom scale |
| `[Worker]` | `Enabled`, `SelfTest` | The worker thread's own Lua state |
| `[Converter]` | `Enabled`, `Stations`, `Remasters`, `GlassParts`, `PackTextures`, `StationDebug` | `Enabled=1` converts the old mods in `legacy_mods` at launch (default 0); `Stations=1` also converts constructions: stations, their modules, assets (default 0); `Remasters=0` leaves out the changes for particular mods (default 1); `GlassParts=1` draws painted-in window glass with a second copy of each part (experimental, default 0); `PackTextures=1` writes converted pictures packed as the game's own are, a quarter to an eighth of the size (default 0 until seen in the game); `StationDebug=1` makes a converted station write its walking lanes to `tf3api_out` each time it is built (default 0) |
| `[Boards]` | `Enabled`, `RefreshMs`, `PlanView` | `Enabled=1` writes the departure boards' screens (default 0); `RefreshMs` how long a changed line takes to be drawn in (default 1600; 0 = at once); `PlanView=1` lets a live picture in a window look straight down (no longer used; default 0) |
| `[Placement]` | `ConfirmObjects`, `InputFilter` | `ConfirmObjects=1` places objects in two steps while the game's drag-and-confirm option is on (default 0); `InputFilter=0` stops keeping the right and middle buttons and Esc from the game while an object is pinned (default 1) |
| `[Vulkan]` | `Hooks` | 0 = do not hook the game's Vulkan lookups (disables frame statistics, the overlay and the board screens) |

Logs go to `tf3api.log`, profiler reports to `tf3api_profile.txt` and the `tf3api_profiles` folder, all next
to the game executable.

---

## Known limitations

- Developed and tested on one machine, on build 40408 and, from 12 October 2026, 40420. See above.
- The memory growth seen in the cockpit view deep underground is not explained yet.
- Road names: saving with the game has not been checked end to end. The naming rules are still being tuned.
  The road-names mod ships with its `ignoreSavedData` development switch on, and with one development city (a
  4 km circle round the biggest town) in `names.lua`.
- Road labels are drawn without depth, so terrain and buildings in front of a road do not hide its name; and
  a click on a label also reaches the game underneath.
- Bus and tram stop names, station names without "Station", and several placement and board features are
  built but not yet seen in the game (marked "built" above).
- Text on converted models (destination displays) breaks up into dots at a distance. The cause is in how the
  game draws such text, not in the converted model; not solved.
- Converting old mods happens before the game shows a window: with many mods the game seems not to start for
  up to a minute after the rules change.
- Converted textures the converter writes itself are uncompressed and large unless `PackTextures=1`.
- Departure boards that the game has turned into asset groups all show the same screen, so boards at two
  different stations show the same departures.
- The profiler slows the game while it samples; continuous mode is a development aid, not something to leave
  on.
- Open problems are tracked one by one in `re_notes/known_issues.md`.
- No installer, no releases yet.

---

## Distribution

TF3OpenAPI will be released on **Nexus Mods and GitHub**. The native layer will not be published through the
in-game mod browser (mod.io), whose rules require mods to use only the official scripting API. Script mods
that need the native layer will say so.

It is and will stay free. It contains no game files and no game code.

---

## Repository layout

| Path | Contents |
|---|---|
| `native/` | The DLL: hooks, fixes, profiler, Vulkan statistics, script bridge, overlay renderer, board screens and station plan pictures, two-step placement, mod converter host |
| `converter/` | The mod converter: its rules (`convert.lua`), the adapter shipped with a converted station mod (`station_shim.lua`) and the changes for particular mods (`remasters.lua`), built into the DLL by `tools/embed_converter.py` |
| `mod/` | Script mods: `tf3api_road_names` (road names, maps, stop names), `tf3api_departure_boards`, `tf3api_placement`, `tf3api_day_clock`, `tf3api_station_names`, `tf3api_hud_fix`, `tf3api_left_hand_traffic` (not usable yet), `tf3api_performance` (shelved) |
| `tools/` | `road_map.py` (map export), `build_viewer.py`, `build_boards.py` and `board_font.py` (departure board models, screens and font), `embed_converter.py`, `embed_board_font.py`, `key_census.py` (what old mods contain against what the converter handles), `annotate_profile.py`, `check_signatures.py`, `make_sig_cases.py`, `build_shaders.py`, `ghidra/` (reverse-engineering scripts), tests in `tests/` |
| `re_notes/` | Notes: renderer, camera, shadows, Lua, road names, stop names and map export (`map_export/`), the mod converter (`converter/`), the engine's systems (`engine/`), departure boards (`boards/`), placement controls (`ui/`), left-hand traffic, the script API (`platform/api.md`), and the list of known issues (`known_issues.md`) |
| `PATCHNOTES.md` | Development log by feature, with the commits behind each entry |

---

## Credits and licences

TF3OpenAPI's own code is under a custom permissive licence: free to use, change, fork and redistribute with
attribution, but neither it nor anything derived from it may be sold or put behind a paywall. Because of that
restriction it is not "open source" in the OSI sense. Full terms: [`LICENSE`](LICENSE). Third-party code keeps
its own licences:

- [MinHook](https://github.com/TsudaKageyu/minhook) by Tsuda Kageyu — function hooking (BSD 2-Clause), with a
  local change so functions compiled with AVX instructions can be hooked.
- [Masked Software Occlusion Culling](https://github.com/GameTechDev/MaskedOcclusionCulling) by Intel (Apache
  2.0).
- [Lua](https://www.lua.org/) 5.4 by Lua.org, PUC-Rio (MIT) — runs the mod converter's rules.
- [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) by the Khronos Group (Apache 2.0 / MIT).

References whose behaviour was studied; no code or assets were taken from any of them:

- "Performance tuning" for Transport Fever 2 by okeating (the draw-distance experiment).
- How Cities: Skylines presents road names (the road-name interface).
- EAT1963's "TPF1 --> TPF2 Konverter" (what a conversion has to do).
- The Transport Fever 2 arrivals and departures displays by lollus and badgerrhax (how departure boards join a
  station and what they show).
- Transport for London's bus stop graphics standard and the national stop register's (NaPTAN) naming
  guidance (stop names); British road numbering and postcodes (road names).
- The Minecraft Transit Railway mod by Jonathan Ho (the planned network map).

Transport Fever is a trademark of Urban Games. This project is not endorsed by or affiliated with Urban Games
or Paradox Interactive.
