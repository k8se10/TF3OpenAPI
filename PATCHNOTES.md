# Patch notes

Nothing has been released yet. This file records development work, grouped as the first release will be.
Each entry names the commits it describes. "Verified" means run in the game and seen to work; "built" means
written and tested outside the game only. All work is against game build 40408.

## v0.1.0 — Development (unreleased) — native core, diagnostics, road names

**Summary:** A native DLL that fixes the cockpit camera in deep tunnels and limits shadow map size, with a
built-in profiler that found where frames go. On top of it, the first pieces of an open platform: a bridge
that gives the game's scripts functions the official API lacks, and the DLL's own drawing pass. Their first
user is a road-names mod: British-style road numbers and street names drawn on the roads, a window per road,
and a street-map export.

### What's New

1. **Cockpit camera follows vehicles below -100 m** (verified). The cockpit view is clamped to a world
   height of -100 m; a two-byte patch removes the lower clamp only. `[Camera] CockpitDepthFix`.
   (`27b8055`, `dd577ae`)
2. **Script bridge: a `tf3api` table in every script state** (verified for `log`, `writeFile`, `has`,
   `setRoadLabels`, `takeRoadClick`). Reference: `re_notes/platform/api.md`.
   (`4d7a0ad`, `ab3e94e`, `7ca2ae2`)
3. **Overlay renderer** (verified). The DLL's own Vulkan pass on the finished frame before it is presented:
   text and rectangles, with a font atlas built from a system font. (`5b8b23a`)
4. **Road names in the world** (verified: shields and names appear on the right roads). Number shields in
   British colours and street names along the road, hidden when zoomed in past 70%. (`28bbfbd`, `ab3e94e`)
5. **Click a shield or a name to open the road's window** (verified: opens with number, name, kind, length
   and segment count; the centred layout and close button are built, not yet seen in the game).
   (`7ca2ae2`, `b6a7d57`, `0a51446`, `bdb136d`, `466980c`)
6. **Road naming and numbering, British rules** (built; verified in part, see the notes).
   - Streets grouped from segments, generated street names, High Streets, roads named after the town they
     lead to. (`c9282d3`, `edd34e5`, `0b8302d`)
   - A and B roads follow what the roads connect: the quickest drives between the biggest towns are A roads,
     the hub's radials are the single-digit roads and bound the zones, each town's links to its nearest
     towns are B roads. (`8dcbc59`, `6f1f6eb`)
   - Short numbers and M numbers need two lanes each way. No five-digit A numbers. (`8dcbc59`, `184f756`)
   - Both carriageways of a motorway are one road; direction of travel is read from the game's routing
     data. (`8967062`, `0b33598`, `7ca2ae2`)
   - Slip roads and one-way junction links take the number of the M road they join. (`0b33598`, `466980c`,
     `3b7d190`)
   - A roundabout is one street and part of the main road through it. (`3b7d190`)
   - A second carriageway that splits off a numbered road and rejoins it keeps that road's number and name.
     (`184f756`)
   - The two one-way carriageways of an ordinary road are paired before numbering (opposite directions,
     within 200 m), so both get one number even where a road crosses them and drives between towns use each
     carriageway separately. A number left on less road than its kind needs is withdrawn. (`d2d1542`)
   - A name is not drawn where the road bends away under it (tight slip roads and loops): the road shows
     its number shield only there. Built; tested offline.
   - Labels stay put while the camera moves: a label that was on screen last frame keeps its piece of road
     as long as it still fits, and new labels only take the room that is left. A name's direction along the
     road is fixed by the road, so it no longer turns round to face the camera. Built; tested offline.
   - Names follow building work: the network is checked every 3 s and read again when it changes; roads keep
     the names and numbers they were given. (`348fd99`, `8dcbc59`)
7. **Street-map export** to interactive HTML, SVG, GeoJSON and OpenStreetMap XML (verified on one save).
   (`c9282d3`, `edd34e5`, `0b8302d`, `e56e156`)
8. **Shadow map resolution limit** (verified). `[Shadows] MaxResolution`. (`4986ee0`, `1e6cfc7`)
9. **Town label fix** (`tf3api_hud_fix`, script mod, verified). (`5d366aa`)
10. **Terrain occlusion culling** (verified to run; no measured benefit, off by default). (`2f2a3b3`,
    `d754167`, `ca0d342`)
11. **Abandoned roads** (built; tested offline). A road that is cut off from the road network can be marked
    abandoned in its window: it loses its number, keeps its name and shows a grey "Abandoned" badge. Nothing
    is demolished and the game itself is not told anything; it is a label. The choice is held in memory for
    now. Joined to the network again, the road goes back to being an ordinary road.
12. **Messages between a mod's script states**: `tf3api.post(channel, text)` and `tf3api.take(channel)`
    (API version 4). The road window uses them to tell the naming script what the player chose.
13. **`ignoreSavedData` development switch** in the road-names mod: every read names the roads from
    scratch. On during development; must be off in a release. (`863eeb2`)

### Fixed

1. MinHook could not hook functions compiled with AVX instructions; the occlusion hooks failed to install.
   (`ca0d342`)
2. Allocation profiler crashed at startup; it now uses a TEB TLS slot. (`26884fa`)
3. Native log was truncated on each launch and could not be read while the game ran. (`4613873`, `880e270`)
4. Road scan found no street segments: the engine refuses to enumerate them by component type. They are
   listed through the street system's node map, in a fixed order. (`d49bcf5`, `596143b`)
5. Airport taxiways and runways were named and drawn as roads. (`0b8302d`)
6. Game failed to start with the road UI: a `.script.lua` module must expose its table through
   `function data()`. (`b6a7d57`)
7. Fatal error on opening the road window: a window has to be registered as a wrapper around the game's
   `Window`. (`0a51446`)
8. Road window had lost its close button. (`466980c`)
9. Parallel motorway carriageways got different numbers: the lane list on a segment includes pavements and
   does not give the direction of travel. (`0b33598`, `7ca2ae2`)
10. Only 14 B roads on a 175-town map: nearly every road counted as a town street. (`6f1f6eb`)
11. A road built as two one-way carriageways showed two numbers (A4 one way, A500 the other): a drive
    between two towns only uses one carriageway, so each was numbered by a different drive. (`d2d1542`)

### Performance

Measured on one machine (RTX 2080 Ti, Ryzen 5 9600X, 2560x1440, highest settings), one early-to-mid game
save, single sessions with the built-in profiler. Not averaged benchmark runs.

1. **Shadow map limit, cockpit view.** 4096x4096 → 2048x2048: roughly 20 fps → roughly 40 fps. No change in
   the zoomed-out view; going below 2048 gave nothing further. (`4986ee0`)
2. **Town label fix, zoomed-out view.** Label script CPU 3.4-3.7 s per 10 s → under 0.1 s; frame time
   28-30 ms → 25-26.5 ms. (`5d366aa`)
3. **Occlusion culling.** Culls 17-18% of the boxes it tests; no visible change in frame rate. (`d754167`,
   `5804334`)
4. **Draw-distance / LOD-distance mod** (`tf3api_performance`): withdrawn, visible loss of detail for little
   gain. Kept in the tree as shelved. (`73b11ff`, `6451f85`)
5. **Road names, cost of naming** (offline, on the exported network of that save: 8,561 segments, 175
   towns): grouping about 100 ms, links between towns about 250 ms spread over about 150 frames (worst
   frame 26 ms), numbering and naming about 250 ms in one frame. Runs once per load and once after each
   change to the road network. Not yet measured in the game.

### Documentation

1. `README.md`: what the project is and is meant to become, the build it targets, status tables, honest
   results, licence. (`2f77932`, `0cf2030`, `28bbfbd`, `01f8445`)
2. `LICENSE`: permissive with attribution; no charging for the code or derivatives. (`01f8445`)
3. `re_notes/camera/camera_pipeline.md`, `re_notes/renderer/culling.md`, `re_notes/renderer/shadows.md`,
   `re_notes/scripting/lua_vm.md`, `re_notes/map_export/road_names.md`, `re_notes/platform/api.md`.
4. Project renamed to TF3OpenAPI, short name `tf3api`. (`f6ec2a6`, `0cf2030`, `c74d316`)

### Groundwork

1. **Sampling profiler** in the DLL: CPU per thread and function, script file and line, continuous mode,
   Vulkan call timing, draw and triangle counts per render pass size, texture and buffer traffic, GPU load,
   camera height per report. (`5804334`, `51db9b8`, `2cb833a`, `0e8e89c`, `5950df5`, `a2b0d78`, `655294f`,
   `42ed614`, `589ef72`)
2. **Allocation profiler and `bad_alloc` probe.** (`dce0414`, `9410c20`)
3. **Signature scanning** for every hook; `tools/check_signatures.py` checks all of them against an
   executable.
4. **Camera for world-space drawing**: the render camera is published each frame, and the field of view is
   taken from the engine's own frustum planes. (`28bbfbd`, `ab3e94e`)
5. **Offline tests**: `tools/tests/road_names_test.lua` (naming rules on a synthetic map),
   `tools/tests/road_labels_test.cpp` (label placement and hide rule against a stubbed camera),
   `tools/tests/vkwin_test.cpp` (overlay in a real Vulkan window under validation).
6. **Camera diagnostic mod** used to find the cockpit clamp. (`2614a19`, `6235f4e`, `ad13ee9`, `a19d1d7`)
7. Lua C API functions located by signature for the bridge. (`7b879e0`)
8. Repository housekeeping: ignore rules for game files, RE databases, runtime output. (`03524af`)

### Investigated, Not Yet Resolved

1. **Memory growth in the cockpit view deep underground** (about 4 GB per minute seen once). The allocation
   profiler counts commits without frees, so the owner is not proven. (`9410c20`, `d24152d`, `8f0a8e0`)
2. **27 shadow passes for 4 cascades** in the cockpit view: not explained.
3. **Zoomed-out view is limited by the main thread**, mostly drawing and stepping the interface. No fix yet
   beyond the town label one.
4. **Clicks on road labels also reach the game**, and a label behind a game window can still be clicked.
   Needs the game's input to be intercepted.
5. **Road labels are not hidden by terrain or buildings** in front of them: the overlay draws on the
   finished frame without depth.
6. **Whether an upgrade replaces a road segment** (which is how a change is noticed) is assumed, not
   confirmed.
7. **Road names are not stored in the save yet**; they are regenerated on load.
8. Nothing has been run on the current retail build (40420).
