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
   - A motorway's number runs through every motorway-standard road joined to it (junction carriageways,
     link roads, spurs), whatever its length. Only a motorway-standard stretch that touches no motorway is
     an A road's (M) section, and its two carriageways share that number. Built; tested offline.
   - Number rules taken from the British scheme: a road's first digit is the furthest-anticlockwise zone
     it enters; three- and four-digit numbers are lower nearer the hub; a motorway that joins one at least
     twice its length takes a number derived from it (M3 -> M31). Built; tested offline.
   - Road names are unique on the map, like numbers and postcodes. Only the hub's high street is plain
     "High Street"; other towns' carry the town's name ("Ringmer High Street"). The first road to a place is
     "Lewes Road"; later ones take the next free form: "Old Lewes Road", "Lewes New Road", "Lewes Lane",
     "Lewes Way" and so on. The pieces of one road (its other carriageway, its roundabouts, a motorway's
     slip roads) share that road's name. Built; tested offline.
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
13. **Postcodes** (built; tested offline). British form, `LE4 5AB`, following the real hierarchy: a few
    major towns each head a postcode area (letters from the town's name); every town is a post town with a
    district of its own, in the nearest major town's area, numbered outwards from it; a spot has the
    postcode of its nearest post town, with sector and unit squares (about 33 m) counted from that town. Works
    at any distance, so on any map size. **Every postcode is unique on the map**: land further than about
    1 km from any town gets further districts of its nearest post town, and only one city can have
    London-style codes (a second one that asks gets an ordinary area). The road window shows the postcode and post town of the spot
    clicked, and the plan is in the map export. (The first version, a grid of 2 km squares round each big
    town, was replaced after checking how Britain does it: `re_notes/map_export/uk_research.md`.)
14. **Road window redesigned** (built; not yet seen in the game): the number on its British sign, the name
    in capitals on a street nameplate with the postcode district in red, then kind, length, postcode and
    post town.
15. **Cities, the rules** (built; tested offline). A city is an outline that takes in several of the game's
    towns. As in Britain, the towns keep their identity.
    - Road numbers: the towns inside stay destinations in their own right and main roads run through them.
      The city only counts as one place when the hub is chosen.
    - Postcodes: the city is one set of districts, its towns being the districts. With the compass scheme
      they are numbered the London way: the code is the direction from the centre (EC and WC in the middle,
      then N, E, SE, SW, W, NW), the town nearest the centre in each direction is the head district, 1, and
      the rest follow alphabetically by name, so a number says nothing about distance.
    - A road leading to the city from outside is named after it, plainly ("Lewes Road").
    - Cities are written into the map export.
    There is no tool to draw a city yet, and nothing of a city is shown in the game. For now a city reaches
    the rules as a message (the form the drawing tool will send), or from a development list in `names.lua`
    that defines one as a circle round a town. That list ships with one example and must be empty in a
    release.
16. **Editing a road in its window** (built; the rules are tested offline, the controls have not been seen in
    the game). Name: type a new one, or clear it for the automatic name; a name another road has is
    refused. Road type: automatic, ordinary road, B road, A road, A road (M), motorway. Label: number and
    name, number only, name only. Each is per road and held in memory for now.
17. **Street map from the game** (built; tested offline). The "Write street map" button in the small
    TF3OpenAPI window writes `road_map.html` into `tf3api_out`: the same interactive page `tools/road_map.py`
    makes, without leaving the game. `tools/build_viewer.py` regenerates the in-game copy of the page.
18. **Saved with the game** (built; tested offline, not yet tried with a real save). The road names and
    numbers, renamed roads, road types, label styles, abandoned roads and cities are kept in the game
    script's own state, which the game writes into the save whenever it saves or autosaves, and are read
    back on load before the roads are first named. Whether a save made this way still loads with the mod
    removed has not been checked yet.
19. **What a road can carry** (built; tested offline). The road window shows lanes, speed limit and the
    theoretical throughput in vehicles an hour, worked out from the lanes and the speed limit. Measured
    traffic is not built; the window says so.
20. **Station Road** (built; tested offline). The road a railway station stands on is "Station Road"; since
    a name is used once on a map, further ones carry their town's name. Only railway stations count: the
    game is asked which carriers call at each station, and a bus stop, harbour or airport is not one.
21. **Postcodes and cities on the street map page** (built; tested offline). The page shows the postcode
    and post town under the pointer, finds a postcode district or a city from the search box, and draws
    city outlines. It works the postcode out itself, the same way the game code does; the two were compared
    on 4,000 random spots, including inside a city, and agreed on all of them.
22. **Bypass, Ring Road, Link Road** (built; tested offline). A numbered road that goes round a town
    without entering its centre is "<Town> Bypass"; one that goes nearly all the way round is "<Town> Ring
    Road"; a short unnumbered road joining two differently numbered roads is "<Town> Link Road". On the real
    map's data: 17 bypasses, no ring roads, 6 link roads.
23. **Motorway junction numbers** (built; tested offline). Each motorway's junctions are numbered 1 upwards
    from the end nearer the hub; the meeting points of one interchange count as one junction. Shown as a
    white-on-black badge on the roads from fairly close, on the street map page, and in the export.
24. **Junction window** (built; not yet seen in the game). Clicking a junction number opens its own
    window: the motorway and junction number on their signs, the roads the junction connects (numbered roads
    first), which junction of how many it is, the distance to the junctions either side, the nearest town,
    the postcode, and how many slip-road ends it has.
25. **`ignoreSavedData` development switch** in the road-names mod: every read names the roads from
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
12. A motorway's number could end up on an ordinary road: where a motorway ran straight on into another
    road at a junction the two became one street; a one-way ordinary road beyond a slip road counted as part
    of the motorway; and a roundabout at the end of a slip road took the motorway's number. Now a
    motorway-standard road and an ordinary one are never one street, only motorway-standard roads are slip
    roads, a roundabout belongs to the ordinary road through it, and as a last check nothing that is not
    motorway standard keeps an M or (M) number unless the player chose that type for it.
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
5. **Naming no longer stalls the game.** Measured in the game before the change: 430-550 ms of grouping
   and naming plus 140-190 ms of export, each inside a single frame, every time the road network changed.
   The work now runs a slice at a time, at most 3 ms a frame, over as many frames as it needs (the long
   loops give way when their slice is used up). Same result as one pass; checked by a test that compares
   the two. Not yet re-measured in the game.
6. **Road names, cost of naming** (offline, on the exported network of that save: 8,561 segments, 175
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

00. **A Lua state of our own on a worker thread** (built; not yet run in the game). The DLL can make a
    separate Lua state with the game's own Lua and run it on its own thread, so that a script mod's heavy,
    pure work need not run on the game's threads at all. Scripts reach it through `tf3api.workerStart`,
    `workerRun` and `workerTake`. A self-test at startup runs a line of Lua in a fresh state and logs the
    result.
000. **Road naming on the worker thread** (built; tested offline with a stand-in for the worker). When the
    worker is available the whole naming pass runs there: the roads go over as text, the same naming script
    runs in the worker's state, and the labels, the export and the messages to the windows go out from the
    worker directly. Only reading the game's roads, the choices and the interface stay on the game's
    threads. Without the worker, or if it fails, the pass runs on the game's side a slice a frame as before.
    A test runs the pass both ways on the same map and requires identical labels and an identical export.
0. **Render-pass trace.** A few times a session the DLL writes one frame's render passes to `tf3api.log`
   (target, size, draws, and the size of each draw in small passes), in the order recorded. The first
   session's trace showed that the game renders almost everything without render-pass objects (dynamic
   rendering) and only one full-size pass with one: 6-7 draws into the same framebuffer each time, which
   looks like the final composition of the scene and the interface. The trace was extended to cover the
   dynamic passes. It is the map needed to draw road labels
   under the game's interface instead of over it.
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
9. **Mod converter, first part: the conversion rules** (`converter/convert.lua`; offline-tested on a made-up
   mod only, never run on a real mod or in the game). Turns a Train Fever / Transport Fever 1 / Transport
   Fever 2 mod folder into a Transport Fever 3 mod folder without touching the source: old group-form models
   become node trees with the materials moved from the meshes to the model, materials are rewritten in the
   new nested form with the older types mapped and missing maps filled with plain textures, references move
   from `res` to `content`, `mod.lua` / `strings.lua` become `mod.json` / `strings.json`, and a
   `conversion_report.txt` lists what was converted, what was missing and what was left out. Not yet built:
   animation files and rotation splitting, seats, icons, repaints. Format notes: `re_notes/converter/`.
   (`86ab2e9`)
10. **Mod converter, second part: conversion at launch** (`native/src/mod_converter.cpp`; tested outside the
    game by `tools/tests/mod_converter_test.cpp`, 18 checks; not yet run in the game). With
    `[Converter] Enabled=1` the DLL creates `legacy_mods` in the game's folder and, before the game's own
    start-up code runs, converts each old mod folder in it to `mods/release/legacy_<name>`. A mod is
    converted once and again only when its files change; a folder the converter did not make is never
    replaced; the rules can read only the old mod and write only the new one. The rules run in a Lua 5.4
    interpreter built into the DLL (with no file or system libraries), since the game's own Lua is not
    usable that early. (`db283ba`)
11. **Mod converter: a mod's own scripts and the older games' libraries.** Found on the first real mod (a
    Transport Fever 1 multiple unit, dry run outside the game): its model builds its seats and door
    animations with scripts of its own that use the older games' `vec3` and `transf` libraries, and a
    material uses `math.pow`, which newer Lua lacks. The converter now runs a mod's `res/scripts` files when
    a model asks for them, with its own `vec3` / `transf` (checked against the game's rotation convention)
    and the old `math` / `table` / `string` functions; what the scripts produce is written into the model as
    plain data. That mod then converts with no problems reported. (`534d2d0`)
12. **Mod converter: output moved to the layout the game reads as old content.** The first in-game run
    stopped at the game's assertion `legacyLocation || version >= 2`: a model older than version 2 is only
    accepted when its path below `content/` starts with `res/models/model/` (confirmed in the decompiled
    check). The converter now writes the old mod's `res` tree under `content/`, with node-tree models,
    flat materials and unchanged references, and carries the rest of `res` over. With that the converted
    unit was registered by the game and could be found in the vehicle list. A change of rules now converts
    an already converted mod again. (`7958542`)
13. **Mod converter: one-model multiple units.** Transport Fever 3 lists multiple units from `.mu.lua` files
    and keeps their cars out of the single-vehicle lists; the older games let one model be a whole unit. A
    converted rail or tram model that is both powered and carrying now gets a `.mu.lua` naming it, and
    `multipleUnitOnly`. Not yet seen in the game: whether the unit file finds a model in the old location
    by the name written. (`107b268`)
14. **Mod converter: cargo names and missing textures.** In the game the converted unit showed a capacity of
    0 and was listed as a locomotive: the older games name a cargo by a word (`PASSENGERS`), Transport Fever
    3 by its cargo file or a cargo class, and an unmatched word carries nothing. The converter now writes
    the newer game's cargo for each old one (and says so where it had to pick the nearest, or could not). A
    texture a material refers to that is not in the mod (usually a file of the older game) is replaced by a
    plain stand-in instead of being left dangling. Seen in the game: capacity right, listed as a multiple
    unit. (`a2c754e`)
15. **Mod converter: back to the newer game's own layout, now with its own model version.** With everything
    above the unit still stopped the game the moment it was put on a line. The crash dump and the decompiled
    check show the renderer finding the vehicle's model id beyond its model data, while the game's log shows
    no model being dropped at load: a model in the old location is listed but cannot be placed in the world,
    so that location looks made for the Model Editor to read old models, not for play. The converter now
    writes `content/` models as version 2 (levels of detail put in order with their per-level settings, the
    default animation driver named), materials in the nested form marked as old, and the
    `texture_metadata_cache.lua` every mod of the newer game carries. Sound sets are not converted yet (the
    vehicle is silent). **Seen in the game: the converted Transport Fever 1 multiple unit runs on a line**,
    textured, in the multiple-unit list with the right capacity. Glass and some surfaces show a dotted
    Player's check: textures right, passengers seated correctly, doors opening. (`8b4851b`)
16. **Mod converter: sound sets and lamps.** An old sound set is a list of sound files plus a function that
    works out each one's loudness and pitch every frame; the newer game wants curves over `speed01` /
    `power01` and its built-in squeal, brake and clack behaviours. The converter runs the old function once
    on stand-in values that record what was done with them, and writes the result as a `.snd.lua`; the mod's
    own sound files come along, and the older games' stock sounds are pointed at the newer game's where it
    still has them. A lamp texture that belonged to the older game now gets a lamp-coloured stand-in, so the
    lamps glow. Player's check: sound works. (`d4f66fa`)
17. **Mod converter: light sources, side-view pictures, Transport Fever 2 mods.** (a) Light sources: the
    newer game lights the scene from a list of lights on the model, each tied to a node and placed in that
    node's own space (checked on the game's own models); the converter reads each glowing mesh of an old
    model from its `.blob`, and puts a pair of headlights at the lamps of the front end and dim red lights
    at the back, at night. (b) The side views shown in lists were placeholder squares: the older games keep
    them under `res/textures/ui/models_20` and `models_small`, the newer one beside the model as
    `icons/<name>_icon20.tga` and `_icon_small.tga` with a colour mask each; they are now placed there
    (double-size `@2x` ones too), with a blank mask where the mod has none. (c) For Transport Fever 2 mods:
    `res/config/multiple_unit` files become `.mu.lua` files beside their vehicles; sound sets written with
    the older `soundsetutil` are replayed into the newer form; a part whose mesh belonged to the older game
    is left empty in place, a missing material gets a plain one, and a texture named with the wrong
    extension is found. None of (a) to (c) has been seen in the game yet; a Transport Fever 2 multiple unit
    converts without problems reported outside it. Player's check: the small side views
    show. (`8e2375e`)
18. **Mod converter: variant groups and the shop picture.** The first Transport Fever 2 mod did not appear
    in the vehicle list. The game's log named a model the mod's cars gave as their variant group and which
    never existed (the older game did not mind), and the mod's lead multiple unit named itself as its own
    group leader, which the newer game's units never do. A vehicle's group is now kept only when it is a
    model of the mod; a unit names its leader only when the leader is another unit. The large picture in
    the shop was still a placeholder: the older games have no such picture, so the biggest side view is
    placed as `<name>_store.tga`. Player's check: the Transport Fever 2 unit is listed and runs. (`3b06ef7`)
19. **Mod converter: the older games' stock lamps.** Why converted vehicles keep arriving without headlights:
    in the older games a mod does not bring its lamps. It refers to lamp meshes, a lamp material and lamp
    textures that are files of the game itself, and the newer game has none of them; and what lights the
    scene in the newer game is a list of light sources that the older formats do not have at all. A part
    whose mesh is one of those stock lamps now gets a small glowing disc of the converter's own (white or
    red by the old mesh's name) instead of being left empty, and a light source: a headlight at a white
    lamp, a rear light at a red one, each tied to its part so that it follows the direction-dependent
    showing and hiding the model already has. (`fc7f06d`)
20. **Mod converter: stock lamps use the newer game's own lamp material.** How the game's own trains do
    lamps (read from 70 of its models): head lamps are meshes with the shared material
    `/vehicle/train/emissive/train_all_lights.mtl`, rear lamps mostly `train_red_lights.mtl`, both on one
    lamp picture with the white lamp in its top left quarter and the red one below; the texture points of
    the game's lamp meshes sit in those quarters. The converter's stand-in disc for a rail vehicle now
    refers to those materials and has its texture points on the matching quarter, so it shows the game's
    lamp picture instead of a plain colour and needs no material or texture of its own. (`28ecc3b`)
21. **Mod converter: rear lamps are red.** Player's check on the Transport Fever 1 unit at night: headlights
    and their beams right, the red light on the track right, but the rear lamps themselves glowed white.
    Its head and rear lamps share one glowing material whose lamp picture was the older game's, so the one
    stand-in colour applied to both. A lamp at the rear end of an old model (or one named red) now gets a red
    twin of that material; any rear-lamp stand-in is red by default. (`a68ddbc`)
22. **Mod converter: mip levels.** The game logs "does not have mipmaps and not viable for streaming" for
    the older games' `.tga` textures and loads them whole. The native host now reads a `.tga` (plain or
    run-length packed; 8, 24 or 32 bits) and writes it as a `.dds` with every mip level, each the one above
    averaged two by two; the materials and the texture list point at the `.dds`. The converter's own plain
    textures carry their levels too. The result is uncompressed, so it is large (85 MB for a 4096 x 4096
    texture); compressing it is not done. Tested outside the game (row order, colour order, averaging); both
    test mods convert in 2.6 s with it. Not yet seen in the game. (`dc8b236`)
23. **Mod converter: lamps by direction, and lifespan.** Player's check: on both converted units every lamp
    was lit at both ends, also between coupled sets; rear lamps were now red. The older games list the parts
    that show by the vehicle's state (front going forward, back going backward, brake lights, indicators) by
    position in the vehicle's settings, and the newer game turns those lists into "on" / "off" animations
    only for models older than its own version (`metadataanimationutil`, `version < 2`). Writing version 2
    skipped that, so the converter now attaches those animations itself (the game's own shared ones) for
    rail and road vehicles. An old model that has no such lists and simply left its lamps on has them
    switched by where they are: head lamps when their end leads the train, rear lamps when it is the tail.
    Not done for ships and aircraft (rudders, propellers, beacons). Also: Transport Fever 2 lets the game
    work out a vehicle's lifespan (`-1`); the newer game takes the number as it stands, so the converted
    unit started fully worn. A vehicle with no lifespan now gets 29220, which many of the game's own trains
    have. **Player's check on both units: all fixed** (lamps by direction, none between coupled sets,
    condition). (`fc40cbf`)
24. **Mod converter: station mods, first version** (behind `[Converter] Stations=1`; not yet tried in the
    game). Read side by side, the newer game's modular rail station is the Transport Fever 2 one reshaped:
    same grid, same slot numbering, same module types, with the functions moved into script files, one more
    first argument on every function, and lanes and terminals handled by the station instead of the models
    (`re_notes/converter/stations.md`). A station mod's construction is that older stock station with its
    own name, parameters, starting layout and modules. So the converter carries the mod's `.con`, `.module`
    and helper scripts over as written, with the libraries they ask for pointed at the newer game's, and
    ships a small adapter with the converted mod (`converter/station_shim.lua`): the mod's station keeps
    its name, parameters, pictures and starting layout (its own `createTemplateFn`, with the older game's
    module and track names translated), and is built, updated and upgraded by the game's own station
    script; the mod's modules run their own code with the argument added and with the models and ground
    textures they add renamed. Three library functions the newer game dropped are supplied. First run in
    the game: listed, but the preview failed with "Could not find module resource
    legacy_...::/trainstation___/..." - from inside a mod a bare `/...` name means the mod's own files, so
    the adapter now writes the game's own names with `::/` in front. **Second run, player's report: the
    converted Transport Fever 2 station builds and is fully configurable; its add-ons work as intended and
    it can be changed after building.** Not yet checked: a line running through it (trains stopping,
    passengers boarding). (`87c57e5`, `aa4ed2a`)
25. **Mod converter: long paths.** The same station mod has file names long enough that, behind the game's
    folder, a path passes the 260 characters most file calls stop at; copying failed. The converter's file
    work now uses the extended path form, which has no such limit.

### Investigated, Not Yet Resolved

0. **Station mods.** One Transport Fever 2 modular rail station converts, builds and is configurable in
   the game, add-ons and later changes included (Groundwork 24). Not yet checked: a line running through it,
   and a mod that depends on another mod. Not covered: cargo stations, stations not built on the stock modular
   station, other kinds of construction.
0. **Converted vehicles: what is still not done.** Two rail multiple units (one from Transport Fever 1, one
   from Transport Fever 2) convert and run with sound, lamps, beams, doors, seats and pictures. Not done:
   the state animations of ships and aircraft; station and other construction mods; compressing the
   textures written with mip levels; a real shop picture; lamps of stock shapes other than round.
0. **(Resolved by the layout change, kept for the record.) Buying a converted vehicle stops the game.** The converted Transport Fever 1 multiple unit can be found
   in the vehicle list, but buying it ends in the game's assertion
   `milSystem.GetNumModelIds() <= modelData.models.GetSize()` (`UI::GetCurrentlyUsedModelIds`). Cause not
   found for certain; it happens when the vehicle is put on a line, only for the converted unit, and the
   old-location route is the suspect (entry 15 under Groundwork replaces that route).
00. **Road names: errors while naming a slice a frame, and no worker thread in the running game.** The game
   log of a session shows 148 Lua exceptions from the road-names script's sliced naming ("Value is not a
   string, but a thread", raised inside the coroutine), although the naming finished. And the native log
   says `worker: not available (Lua functions missing)`: the worker's Lua functions, found in the file on
   disk, are not all found in the running game. Both to be looked at.

1. **Memory growth in the cockpit view deep underground** (about 4 GB per minute seen once). The allocation
   profiler counts commits without frees, so the owner is not proven. (`9410c20`, `d24152d`, `8f0a8e0`)
2. **27 shadow passes for 4 cascades** in the cockpit view: not explained.
3. **Zoomed-out view is limited by the main thread**, mostly drawing and stepping the interface. No fix yet
   beyond the town label one.
4. **Road labels are drawn over the game's interface**, not under it. They are added to the finished frame
   just before it is shown. Putting them under the interface means drawing them between the game's 3D
   passes and its interface pass; the render-pass trace is the first step towards finding where that is.
4a. **Labels cannot be clicked while a tool is in use** (built; not yet seen in the game): with anything other
    than the game's default look-around tool active, a click on a label opens nothing.
4b. **Clicks on road labels also reach the game**, and a label behind a game window can still be clicked.
   Needs the game's input to be intercepted.
5. **Road labels are not hidden by terrain or buildings** in front of them: the overlay draws on the
   finished frame without depth.
6. **Whether an upgrade replaces a road segment** (which is how a change is noticed) is assumed, not
   confirmed.
7. **Saving road names with the game is untested in the game**, including whether such a save loads
   without the mod.
8. Nothing has been run on the current retail build (40420).
