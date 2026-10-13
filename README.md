# TF3OpenAPI

> Formerly "TF3 Optimizations + DLSS". Files, settings and mod ids use the short name `tf3api`.

**An open native modding platform for Transport Fever 3, growing out of a set of performance fixes.**

Transport Fever 3's official modding API covers content: models, scripts, the interface, game rules. It does
not reach the engine: the renderer, the frame loop, drawing in the world, the engine's internal data, or
files on disk. TF3OpenAPI is a native layer that sits inside the game process and reaches those parts
directly. Today it uses that reach for its own fixes and tools. The plan is to open it up, step by step,
as a documented API that any mod can build on.

It is unofficial, free, and not affiliated with Urban Games or Paradox Interactive.

---

## What it is meant to become

Three layers, built in this order:

1. **Native core** — a DLL loaded by the game that locates engine functions at startup and hooks or calls
   them. This exists and is where the current fixes live.
2. **A bridge to the game's scripts** — functions the DLL registers inside the game's Lua, so ordinary
   script mods can ask the native side for things the official API cannot do, and the native side can call
   back into scripts. The first version exists: a `tf3api` table in every script state (logging, file
   writing, messages between a mod's script states, road labels, a worker thread with a Lua state of its
   own). Calls from native code back into scripts are not built yet.
3. **A public API on top of that bridge** — stable, named, versioned functions with documentation and
   example mods. Mods call the API; engine addresses and layouts stay inside the DLL, so a game update is
   fixed in one place and mods keep working. Not built yet.

Each capability is added because a real feature needs it, then generalised. Nothing is exposed on
speculation.

Principles the platform holds to:

- **Read-only and render-only by default.** Anything that could change the simulation is marked as such and
  off unless asked for. Saves made with TF3OpenAPI's own features load in the unmodified game.
- **A mod's mistake must not take the game down silently.** Arguments are checked at the boundary and
  failures are written to a log.
- **Survive game updates.** If one function cannot be located on a new build, that function reports itself
  unavailable and the rest still loads.
- **Open.** Public source, documented API, usable by other authors without asking.

---

## Which game build this is developed against

**TF3OpenAPI was developed against the launch build of Transport Fever 3, build 40408 (29 September 2026).
From 12 October 2026 development and testing move to build 40420 (the first stability update, 8 October
2026).** It runs on 40420: in a session on that build (the game's log gives the build number) every
signature resolved in the running game, the DLL's hooks installed, the mod converter ran at launch and its
converted vehicles and stations were used in the game. One signature needed loosening for 40420 (see the
patch notes). Since then the road names, the worker thread, the overlay under the game's interface and the
mod converter have all been used on 40420. Not yet done there: occlusion culling measured, and the cockpit
depth fix deep underground.

No engine address is hard-coded. Every hook is found at startup by signature scanning: the DLL searches
the game's code for a byte pattern that identifies the function. A pattern must match exactly once; if it
matches nowhere or more than once, that feature is skipped and the reason is written to `tf3api.log`. The
game is never patched on disk.

Because of this, most features should carry forward to newer builds unchanged, and a feature whose
function was rewritten should switch itself off rather than misbehave. That is the design, not a test
result: one of some thirty signatures had to be changed for 40420 (a stack-frame size inside it differed),
and a feature not listed above as seen on 40420 should be treated there as unverified.

Windows only. The script-only mods in `mod/` do not depend on the DLL and are not tied to Windows.

---

## What exists today

Status words used below: **verified** = run in the game and seen to work; **built** = written and tested
outside the game only; **planned** = not started.

### Fixes

| Feature | Status | Notes |
|---|---|---|
| Cockpit camera depth fix | verified | The cockpit view is clamped to a world height of -100 m, so it breaks in deep tunnels. This removes the lower clamp. |
| Shadow map resolution limit | verified | The game sizes shadow maps from the screen (4096x4096 at 1080p, 1440p and 4K on High). This sets a maximum. |
| Town label fix (`tf3api_hud_fix`, script mod) | verified | Each town label fetched the state of every town to read its own. Now fetched at most once a second. |
| Terrain occlusion culling | verified to run, **no measured benefit** | Off by default. See "Honest results". |

### Diagnostics

| Feature | Status | Notes |
|---|---|---|
| Sampling profiler | verified | CPU time per thread and per function, including which script file and line the time belongs to. Can run continuously. |
| Vulkan frame statistics | verified | Frame times, time spent waiting in Vulkan calls, draw calls, render passes by size, texture and buffer traffic, GPU load. |
| Allocation profiler, `bad_alloc` probe | verified | For memory investigations. Off by default. |

### Platform

| Feature | Status | Notes |
|---|---|---|
| Script bridge (`tf3api` table) | verified | `version`, `has(name)`, `log(text)`, `writeFile(name, text)`, `setRoadLabels(text)`, `takeRoadClick()`, `post(channel, text)`, `take(channel)`. Reference: `re_notes/platform/api.md`. Files go to `tf3api_out` in the game folder; plain file names and data or document extensions only. |
| Worker thread with its own Lua state (`workerStart`, `workerRun`, `workerTake`) | verified | For moving a script mod's heavy computation off the game's threads. The road-names mod names the roads on it. |
| Overlay renderer | verified | The DLL's own drawing: text and rectangles. Drawn inside the game's own pass onto the screen, after the picture of the world and before the interface, so it lies under the game's windows, buttons and bars. Falls back to drawing on the finished frame. The base for road names in the world. Off by default. |

### Road names and map export (in progress)

| Piece | Status |
|---|---|
| Grouping road segments into streets, generating names and road numbers (British conventions) | verified on one save (8,534 segments, 1,011 streets); the rules are still being tuned in the game |
| A and B roads from what the roads connect; motorway carriageways, slip roads, roundabouts, split carriageways | built; tested offline only |
| Map export to interactive HTML, SVG, GeoJSON and OpenStreetMap XML | verified on the same save |
| Road names drawn on the roads in the game, by the native layer | verified: number shields and names sit on the right roads; hidden when zoomed in past 70% |
| Click a shield or name to open the road's window | verified: the window opens with the number on its sign, the name on a nameplate, kind, length and postcode |
| Changing a road in its window: name, road type (ordinary, B, A, A (M), motorway), what its label shows | built; rules tested offline, controls not yet seen in the game |
| Only one road or junction window open at a time | built; not yet seen in the game |
| Road names worked out on a worker thread, off the game's threads | verified (a re-naming after a change answered in 8 ms in one session) |
| Road labels drawn under the game's interface | verified |
| Writing the street map page from inside the game | built; tested offline only |
| Motorway junction numbers, on the roads and on the street map page; click one for its window (what it connects, distances, postcode) | built; tested offline only |
| Postcodes and cities on the street map page (postcode under the pointer, search by district, city outlines) | built; tested offline only |
| What a road can carry (lanes, speed limit, theoretical vehicles an hour) in the window | built; tested offline only. Measured traffic is planned |
| Names, numbers and the player's choices saved with the game | handing over for saving seen in the game; a load reading them back not yet watched; a save loaded without the mod not yet tried |
| Names follow building work; a road keeps the name and number it was given | built; tested offline only |
| Postcodes for every spot on the map (British form, areas around the biggest towns, any map size), shown in the road window | built; tested offline only |
| Marking a cut-off road abandoned: it loses its number and shows an "Abandoned" badge with its name | built; tested offline only |
| "Adjust road" tool: a green line along the road with a circle at each end; take an end to another junction to shorten the road or draw it out along other roads, by whole segments | verified |
| Cities: draw a line around several towns to define them as one city, editable later. Zoomed out, the city's name is shown in place of its towns' names; zoomed in past 35% the towns' own names return. A city can have its own postcode scheme (for example London's compass districts). The city's label and window reuse the game's own town label and town window | the rules are built and tested offline (one place for road numbers, one postcode area, roads named after it). The drawing tool is built: a city can be drawn and made in the game, and London-style postcodes are only offered for a city the player drew. The label, the window and editing an outline afterwards are not started |
| Road systems for other countries as editable profiles (UK, US, Germany, France, generic) | planned |
| Per-quantity unit settings for the whole game interface | planned |
| Floating button and main settings panel | planned |

### Converter for older mods (in progress)

Put a Train Fever, Transport Fever 1 or Transport Fever 2 mod's folder into `legacy_mods` in the game's
folder (the layer creates it at launch). At the next launch it is converted, before the game lists its mods,
into a new mod `legacy_<name>` that appears in the mod list; the old folder is only read. Each converted
mod has a `conversion_report.txt` saying what was converted, what was missing and what was left out.

Tried so far on sixteen mods: four rail multiple units (one from Transport Fever 1, three from Transport
Fever 2), two modular station mods, two track packs, two packs of small stations, a sign pack and three
billboard packs it builds on.

| Piece | Status |
|---|---|
| Conversion at launch from `legacy_mods`, once per mod, redone when the old mod or the rules change | verified. A full re-conversion of a dozen mods takes about half a minute, during which the game shows nothing; a progress window is planned |
| Vehicles: old group-form models to node trees, dropped material types mapped, a mod's own scripts run, cargo names, seats, doors, multiple units, list and shop pictures, sound sets, lifespan | verified on the four units |
| Lamps: the older games' stock lamp parts replaced by lamps of the converter's own, the mod's own lamp pictures kept (bright `.hdr` pictures rewritten as ordinary ones), light beams added, head and rear lamps switched by which end of the train they are at, rear lamps and lamps by day | verified on four units |
| Lighting textures (normal maps): read as the older games read them, and their unpainted parts made flat (they lit parts of a body as if they faced away) | verified |
| Text on models (destination displays) at the newer game's scale | verified close up; hard to read at a distance (see Known limitations) |
| Body sides with the windows painted into the same picture as glass: the paint drawn solid, the glass by a second, blended material on a copy of the part | experimental, off by default (`[Converter] GlassParts=1`): with it a converted train was seen folded up and with a dark cast over parts of its body |
| Textures: `.tga` written as `.dds` with mip levels; missing textures and materials stood in for | built; uncompressed, so large |
| Mods that build on other old mods: files found in the other mods in `legacy_mods`, dependencies written | verified on the sign and billboard packs |
| Assets and other plain constructions (signs, billboards, props) | verified: billboards can be placed |
| Transport Fever 2 modular station mods (the construction, its modules and helper scripts carried over and run through an adapter shipped with the converted mod; the station is built by the game's own station script) | behind `[Converter] Stations=1`. Verified on two station mods, one building on the other: builds, is configurable, add-ons, later changes, platform signs, buildings, walking paths, boarding, underpasses |
| Whole rail stations built by one construction (stops and walking lanes into the newer game's form) | built; simulated builds only |
| Kinds of track (`res/config/track`): the newer game's street style and two templates, without and with overhead wire; converted stations lay them | verified |
| Remasters: a short list of changes for one particular old mod, made to its converted copy (an engine type, added text labels, part of a texture painted over). The old mod is not touched and nothing of it is in this repository. First one: a Docklands Light Railway unit made electric, with the destination painted on its blind replaced by a live one | verified |
| Ships' and aircraft's moving parts, compressed textures, rendered shop pictures, repaints, zipped mods, a progress window, optional upscaling of low-resolution textures | planned |
| Bridge and tunnel kinds, depots, road, water and air stations, cargo stations, mods that are scripts | not converted |

Modelled on EAT1963's "TPF1 --> TPF2 Konverter" for what a conversion has to do; none of its code is used.
A converted mod is still the original author's work: do not share one without their permission. A
converted mod only offers what it adds while the old mod it was made from is still in `legacy_mods` and the
native layer is loaded; passed on by itself it adds nothing. (Built; not yet seen in the game.)

### Planned next

- **Departure boards for stations.** A new model and new logic of this project's own, not a conversion of an
  existing mod: a dot-matrix display whose lit points are written live into its texture by the native layer.
  A board on a post can be placed; it shows a running clock and the next departures of the station it
  stands at (boards share a "screen number" per station, 32 in all). The clock and the live writing are seen
  working in the game; the departures are built and not yet seen there. After cloning, run
  `python -I tools/build_boards.py <board model>` to generate the screens' textures.

- **Day clock.** A script mod (`tf3api_day_clock`), enabled per save: a clock that runs in real time at
  normal game speed, with a choice of how the calendar goes with it - Realistic (a calendar day is 24 hours
  of play), Balanced (one hour) or Transport Fever (the game's own pace). The sun and moon follow the clock
  unless switched off, and in the two long-day modes vehicle wear and age follow the calendar. Built on the game's own calendar speed and time of day; works alongside the Timetables mod (both show the same time).

- **Left-hand traffic.** A mod of this project's own, built on what the engine was found to do
  (`re_notes/left_hand_traffic/`, `re_notes/engine/streets.md`): streets, the lanes inside stations, depots
  and industries, vehicles mirrored only where the mirror is right (text on displays turned round to stay
  readable) and otherwise not offered, and a safe reset for vehicles and people where lanes change under
  them. So far: the rules for streets and for text on mirrored vehicles, tested outside the game. Not
  usable yet.
- **Finding hooked functions by what they are, not only by their bytes.** Each hook has one byte pattern,
  and a feature switches itself off when its pattern no longer matches. The game's assertions carry texts
  that stay the same from build to build; a function can be found as the one function that refers to a
  given set of them. The resolver is built and tested against the current executable on disk (no wrong
  answers in 400 cases; it refuses where texts are shared), and the occlusion module's scene hooks fall
  back on it. Hooks into code without such texts (the Lua interpreter, for one) still rest on bytes
  alone. Not yet seen to rescue a hook on a real update: that needs the next game build.
- **Learning the engine as a whole.** Real names for several thousand of the game's functions were recovered
  from its assertions; reports on streets, navigation and assets are under `re_notes/engine/`. Further
  reports (movement, people and cargo, construction) follow, and features are built on them.

### Further out

- DLSS / upscaling through NVIDIA Streamline. NVIDIA-only, opt-in, and only useful where the graphics card
  is the limit.
- **A converter for Train Simulator content**, unattended like the one for older Transport Fever mods: put
  the content in a folder, start the game, find it converted in the mod list. An idea for later; none of
  the formats have been looked at.
- Maps that can grow beyond their original bounds. Exploratory.
- **Trains that change ends.** The game turns a whole train round to reverse it. The idea: a train reverses
  where it stands, with its lamps and driving end following. A change to the game's own behaviour, so it
  needs the simulation looked at first.
- **Multiplayer.** The last item on the list, after everything above. It would be a mode of its own, built
  from the ground up, not single-player with networking added on: single-player stays exactly as it is.
  Nothing has been looked at.

---

## Honest results

All figures are from one machine (RTX 2080 Ti, Ryzen 5 9600X, 2560x1440, highest settings) and one
early-to-mid game save, measured with the built-in profiler. They are single sessions, not averaged
benchmark runs, and will differ on other hardware and saves.

- **Shadow map limit, cockpit view.** At 4096x4096 the game rendered 27 shadow passes per frame, about 77%
  of all pixels drawn. Limiting to 2048 took the cockpit view from roughly 20 fps to roughly 40 fps.
  Going lower gave nothing further. No change in the zoomed-out view.
- **Town label fix, zoomed-out view.** The label script's CPU cost fell from 3.4-3.7 s per 10 s to under
  0.1 s. Frame time went from 28-30 ms to 25-26.5 ms, about 10%.
- **Occlusion culling.** It removes 17-18% of the objects it tests, with no visible change in frame rate.
  The frame was limited elsewhere. It stays in the tree as groundwork and is off by default.
- **A draw-distance and LOD-distance mod** in the style of the Transport Fever 2 "Performance tuning" mod
  was tried and withdrawn: visible loss of detail for little gain. It is kept in `mod/` as shelved.

What the profiling showed about the game on this save: the cockpit view is limited by the graphics card,
mostly by shadow rendering and full-screen passes; the zoomed-out view is limited by the main thread, where
drawing and updating the interface cost several times more than the 3D scene. A third-party script mod was
also found using 39% of the main thread during its scans, which is the kind of thing the profiler is for.

---

## Installing

Nothing here is packaged for release yet. For development builds:

1. Build `native/tf3api.vcxproj` (x64, Release). The output is `winhttp.dll`.
2. Copy `winhttp.dll` next to `TransportFever3.exe`. The game loads it in place of the system library of
   that name, and it passes every call through to the real one.
3. Optionally put a `tf3api.ini` next to it (see below). Without one, defaults apply.
4. Script mods: copy a folder from `mod/` into the game's `mods` folder and enable it for a save.

To remove: delete `winhttp.dll`, `tf3api.ini` and the `tf3api` log and profile files from the game folder.
The game and its saves are left as they were.

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
| `[Vulkan]` | `Hooks` | 0 = do not hook the game's Vulkan lookups (disables frame statistics and the overlay) |

Logs go to `tf3api.log`, profiler reports to `tf3api_profile.txt` and the `tf3api_profiles` folder, all
next to the game executable.

---

## Known limitations

- Developed and tested on one machine, on build 40408 and, from 12 October 2026, 40420. See above.
- The memory growth seen in the cockpit view deep underground is not explained yet.
- Road names: editing a road's name, type and label in its window is built and has not been seen in the
  game. Saving with the game has not been checked end to end. The naming rules are still being tuned.
- Road labels are drawn without depth, so terrain and buildings in front of a road do not hide its name;
  and a click on a label also reaches the game underneath.
- Text on converted models (destination displays) breaks up into dots at a distance. The cause is in how
  the game draws such text, not in the converted model; not solved.
- Converting old mods happens before the game shows a window: with many mods the game seems not to start
  for up to half a minute after the rules change.
- Converted textures the converter writes itself are uncompressed and large.
- The road-names mod ships with its `ignoreSavedData` development switch on, and with one development city
  (a 4 km circle round the biggest town) in `names.lua`.
- The profiler slows the game while it samples; continuous mode is a development aid, not something to
  leave on.
- No installer, no releases yet.

---

## Distribution

TF3OpenAPI will be released on **Nexus Mods and GitHub**. The native layer will not be published through
the in-game mod browser (mod.io), whose rules require mods to use only the official scripting API. Script
mods that need the native layer will say so.

It is and will stay free. It contains no game files and no game code.

---

## Repository layout

| Path | Contents |
|---|---|
| `native/` | The DLL: hooks, fixes, profiler, Vulkan statistics, script bridge, overlay renderer, mod converter host |
| `converter/` | The mod converter: its rules (`convert.lua`), the adapter shipped with a converted station mod (`station_shim.lua`) and the changes for particular mods (`remasters.lua`), built into the DLL by `tools/embed_converter.py` |
| `mod/` | Script mods: `tf3api_hud_fix`, `tf3api_road_names`, `tf3api_performance` (shelved) |
| `tools/` | `road_map.py` (map export), `annotate_profile.py`, `check_signatures.py`, `build_shaders.py`, tests (`road_names_test.lua`, `road_labels_test.cpp`, `vkwin_test.cpp`, `converter_test.lua`, `mod_converter_test.cpp`) |
| `re_notes/` | Notes: renderer, camera, shadows, Lua, road names and map export, the mod converter (`converter/`), the script API (`platform/api.md`) |
| `PATCHNOTES.md` | Development log by feature, with the commits behind each entry |

---

## Credits and licences

TF3OpenAPI's own code is under a custom permissive licence: free to use, change, fork and redistribute with
attribution, but neither it nor anything derived from it may be sold or put behind a paywall. Because of
that restriction it is not "open source" in the OSI sense. Full terms: [`LICENSE`](LICENSE). Third-party
code keeps its own licences:

- [MinHook](https://github.com/TsudaKageyu/minhook) by Tsuda Kageyu — function hooking (BSD 2-Clause),
  with a local change so functions compiled with AVX instructions can be hooked.
- [Masked Software Occlusion Culling](https://github.com/GameTechDev/MaskedOcclusionCulling) by Intel
  (Apache 2.0).
- [Lua](https://www.lua.org/) 5.4 by Lua.org, PUC-Rio (MIT) — runs the mod converter's rules.
- [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) by the Khronos Group (Apache 2.0 / MIT).
- The draw-distance experiment followed the idea of "Performance tuning" for Transport Fever 2 by okeating.
  No code was taken.
- The road-name interface is modelled on how Cities: Skylines presents road names. No code or assets were
  taken.

Transport Fever is a trademark of Urban Games. This project is not endorsed by or affiliated with Urban
Games or Paradox Interactive.
