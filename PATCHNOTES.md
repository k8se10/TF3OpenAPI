# Patch notes

Nothing has been released yet. This file records development work, grouped as the first release will be.
Each entry names the commits it describes. "Verified" means run in the game and seen to work; "built" means
written and tested outside the game only. Work up to 2026-10-12 was against game build 40408; from that
day on it is against build 40420.

## v0.1.0 — Development (unreleased) — native core, diagnostics, road names, mod converter

**Summary:** A native DLL that fixes the cockpit camera in deep tunnels and limits shadow map size, with a
built-in profiler that found where frames go. On top of it, the first pieces of an open platform: a bridge
that gives the game's scripts functions the official API lacks, and the DLL's own drawing pass. Their first
user is a road-names mod: British-style road numbers and street names drawn on the roads, a window per road,
and a street-map export. The largest addition since is a converter for older mods: Train Fever, Transport
Fever 1 and Transport Fever 2 vehicles, stations, tracks and assets put into a folder are converted at
launch and appear in the mod list.

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
     an A road's (M) section, and its two carriageways share that number. Built; tested offline. (`81bf5a7`)
   - Number rules taken from the British scheme: a road's first digit is the furthest-anticlockwise zone
     it enters; three- and four-digit numbers are lower nearer the hub; a motorway that joins one at least
     twice its length takes a number derived from it (M3 -> M31). Built; tested offline. (`f78b5b6`)
   - Road names are unique on the map, like numbers and postcodes. Only the hub's high street is plain
     "High Street"; other towns' carry the town's name ("Ringmer High Street"). The first road to a place is
     "Lewes Road"; later ones take the next free form: "Old Lewes Road", "Lewes New Road", "Lewes Lane",
     "Lewes Way" and so on. The pieces of one road (its other carriageway, its roundabouts, a motorway's
     slip roads) share that road's name. Built; tested offline. (`2080364`)
   - A roundabout is one street and part of the main road through it. (`3b7d190`)
   - A second carriageway that splits off a numbered road and rejoins it keeps that road's number and name.
     (`184f756`)
   - The two one-way carriageways of an ordinary road are paired before numbering (opposite directions,
     within 200 m), so both get one number even where a road crosses them and drives between towns use each
     carriageway separately. A number left on less road than its kind needs is withdrawn. (`d2d1542`)
   - A name is not drawn where the road bends away under it (tight slip roads and loops): the road shows
     its number shield only there. Built; tested offline. (`6d7dfe2`)
   - Labels stay put while the camera moves: a label that was on screen last frame keeps its piece of road
     as long as it still fits, and new labels only take the room that is left. A name's direction along the
     road is fixed by the road, so it no longer turns round to face the camera. Built; tested offline.
     (`dd79c2a`)
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
    now. Joined to the network again, the road goes back to being an ordinary road. (`7b6f88d`)
12. **Messages between a mod's script states**: `tf3api.post(channel, text)` and `tf3api.take(channel)`
    (API version 4). The road window uses them to tell the naming script what the player chose. (`7b6f88d`)
13. **Postcodes** (built; tested offline). British form, `LE4 5AB`, following the real hierarchy: a few
    major towns each head a postcode area (letters from the town's name); every town is a post town with a
    district of its own, in the nearest major town's area, numbered outwards from it; a spot has the
    postcode of its nearest post town, with sector and unit squares (about 33 m) counted from that town. Works
    at any distance, so on any map size. **Every postcode is unique on the map**: land further than about
    1 km from any town gets further districts of its nearest post town, and only one city can have
    London-style codes (a second one that asks gets an ordinary area). The road window shows the postcode and post town of the spot
    clicked, and the plan is in the map export. (The first version, a grid of 2 km squares round each big
    town, was replaced after checking how Britain does it: `re_notes/map_export/uk_research.md`.)
    (`fb725b9`, `8b983cb`, `28ae7b3`)
14. **Road window redesigned** (built; not yet seen in the game): the number on its British sign, the name
    in capitals on a street nameplate with the postcode district in red, then kind, length, postcode and
    post town. (`fb725b9`, `7488f9d`, `2198577`)
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
    A city reaches the rules as a message from the drawing tool (entry 26), or from a development list in
    `names.lua` that defines one as a circle round a town. That list ships with one example and must be
    empty in a release. Nothing of a city is shown in the game yet beyond its outline while it is drawn.
    (`8216aa1`, `8b983cb`)
16. **Editing a road in its window** (built; the rules are tested offline, the controls have not been seen in
    the game). Name: type a new one, or clear it for the automatic name; a name another road has is
    refused. Road type: automatic, ordinary road, B road, A road, A road (M), motorway. Label: number and
    name, number only, name only. Each is per road, and saved with the game (entry 18). (`c24940d`)
17. **Street map from the game** (built; tested offline). The "Write street map" button in the small
    TF3OpenAPI window writes `road_map.html` into `tf3api_out`: the same interactive page `tools/road_map.py`
    makes, without leaving the game. `tools/build_viewer.py` regenerates the in-game copy of the page.
    (`c24940d`)
18. **Saved with the game** (built; tested offline, not yet tried with a real save). The road names and
    numbers, renamed roads, road types, label styles, abandoned roads and cities are kept in the game
    script's own state, which the game writes into the save whenever it saves or autosaves, and are read
    back on load before the roads are first named. Seen in the game: the choices are handed over for saving
    (58 KB on a 175-town map). A load reading them back has not been watched yet, and whether a save made
    this way still loads with the mod removed has not been checked. (`b58a765`)
19. **What a road can carry** (built; tested offline). The road window shows lanes, speed limit and the
    theoretical throughput in vehicles an hour, worked out from the lanes and the speed limit. Measured
    traffic is not built; the window says so. (`b58a765`)
20. **Station Road** (built; tested offline). The road a railway station stands on is "Station Road"; since
    a name is used once on a map, further ones carry their town's name. Only railway stations count: the
    game is asked which carriers call at each station, and a bus stop, harbour or airport is not one.
    (`b58a765`, `7c44321`)
21. **Postcodes and cities on the street map page** (built; tested offline). The page shows the postcode
    and post town under the pointer, finds a postcode district or a city from the search box, and draws
    city outlines. It works the postcode out itself, the same way the game code does; the two were compared
    on 4,000 random spots, including inside a city, and agreed on all of them. (`ed03dd2`)
22. **Bypass, Ring Road, Link Road** (built; tested offline). A numbered road that goes round a town
    without entering its centre is "<Town> Bypass"; one that goes nearly all the way round is "<Town> Ring
    Road"; a short unnumbered road joining two differently numbered roads is "<Town> Link Road". On the real
    map's data: 17 bypasses, no ring roads, 6 link roads. (`2eae343`)
23. **Motorway junction numbers** (built; tested offline). Each motorway's junctions are numbered 1 upwards
    from the end nearer the hub; the meeting points of one interchange count as one junction. Shown as a
    white-on-black badge on the roads from fairly close, on the street map page, and in the export.
    (`e044cca`)
24. **Junction window** (built; not yet seen in the game). Clicking a junction number opens its own
    window: the motorway and junction number on their signs, the roads the junction connects (numbered roads
    first), which junction of how many it is, the distance to the junctions either side, the nearest town,
    the postcode, and how many slip-road ends it has. (`6547689`)
25. **`ignoreSavedData` development switch** in the road-names mod: every read names the roads from
    scratch. On during development; must be off in a release. (`863eeb2`)

26. **Drawing a city** (`16953e5`; seen in the game: a city can be drawn and is made; the list of cities
   then failed, fixed under Fixed 19c and not seen since). "Draw a city" in the TF3OpenAPI window
   starts a tool: left click on the map sets a corner of the city's outline, right click takes the last one
   back, and the outline is shown on the ground as it grows. With a name and at least three corners it is
   finished; the roads and postcodes are worked out again with the towns inside as one city. The window lists
   the cities drawn and can remove them. While the tool is open, clicks on the map select nothing and road
   labels are not clickable.
27. **London-style postcodes are for drawn cities only** (`16953e5`). The compass scheme (EC, WC, N, E, SE ...)
   can be chosen for a city the player drew, for one on a map. A circle round a town, or any outline that
   does not come from the player, gets ordinary postcodes whatever it asks for.
28. **Mod converter: old mods that build on other old mods** (`5b826de`; dry runs only, not yet seen in the
   game). A station pack that uses a track pack's materials, a repaint that uses the station's meshes, signs
   that use a billboard pack's mesh: a file a mod refers to and does not have is looked for in the other old
   mods in `legacy_mods`, and referred to in that mod as it is converted. The converted mod names the other
   as a dependency, and its report lists which converted mods have to be enabled with it. Tried on eleven
   Transport Fever 2 mods together: three that had 101, 286 and 1,370 references leading nowhere now have 0,
   0 and 12 (those 12 are files the mod itself never shipped).
29. **Mod converter: assets and other plain constructions** (`5b826de`; dry runs and a simulated build only).
   A construction that is not a modular station - a sign, a billboard, a prop - keeps its parameters and its
   own update function, is offered under the game's asset menus, and what it builds is put into a part of
   the construction as the newer game has it. Seen in the game: converted billboards can be placed. Whole
   rail stations built by one construction and kinds of track came later (Fixed 19e, entry 31). Not
   covered: bridge and tunnel kinds (`res/config/bridge|tunnel`), and mods that are scripts rather than
   things to build.
30. **Road names: Adjust Road** (`a8654f3`, `e50aa21`; seen working in the game). A button in a road's window shows the road as a green line with a large circle at each end.
   Take a circle and let it go where the road should end (or click the circle, then the place): on the road
   itself it is cut there and the part beyond becomes a road of its own; further along another road it is
   drawn out by the shortest way by road, taking those segments from the road they belonged to. The road
   changes by whole segments and its ends are at junctions; the end has to be let go within 150 m of one,
   and a road can be drawn out by up to 5 km at a time. The road keeps its name, number, type and label
   style, and what was set is kept with the other road choices in the save. Not built yet: putting a road
   back to automatic, and marking part of a connected road abandoned.
31. **Mod converter: kinds of track** (`7e1e429`, `8bd12c9`; seen working in the game). A track type of
   the older games (`res/config/track/<name>.lua`) is written as the newer game's street style
   (`content/track/<name>.street.lua`: shape, sleeper, rail, pole and bumper models, materials) and two
   templates, without and with overhead wire (speed, years, cost, menu entry under Tracks, the mod's own
   menu picture). Models and materials the track names from the older game itself are replaced by the
   newer game's standard or high-speed ones. A converted station that lays such a track now lays the
   converted kind, its own or another converted mod's, where it used to get the game's standard track.
   Seen working in the game. Cost is scaled by the ratio between the two games' own tracks (2.4 for
   ordinary track, 3.6 for high-speed; `8bd12c9`); slope and curve limits are the mod's where it sets them,
   else the game's own; the mod's bed picture is laid once across and once per step. Bridge and
   tunnel kinds are still not converted.
32. **Mod converter: remasters** (`f39c2c3`; both changes of the first one seen working in the game). A remaster is a short list of
   changes for one particular old mod, made to the converted copy while it is converted: the old mod is
   not touched, and nothing of it is in the converter. `converter/remasters.lua` holds them; a remaster
   applies when the files it names are in the mod. What a remaster can do so far: set the engine type of a
   model, add text labels to it, and paint over part of a `.dds` texture with its own background (by whole
   packed blocks, in every mip level, without unpacking the picture). `[Converter] Remasters=0` turns them
   all off. First one: the Docklands Light Railway P86 - an electric unit instead of a diesel one, and the
   destination painted on the blind behind each windscreen replaced by a live next-stop label.
33. **Mod converter: a converted mod needs the old mod it was made from** (`b65401e`; built; tested outside
   the game only). A converted mod is the original author's work, made on the player's machine from the player's own
   copy. So that a converted mod passed on by itself is of no use, each one now carries a small script that
   asks the native layer whether the old mod is still in `legacy_mods` (`tf3api.legacySource`, API version
   8). Without the old mod, or without the native layer, the converted mod's vehicles, constructions and
   tracks are not offered in the menus. Nothing is removed from the game: what is already running in a
   saved game keeps running and the save loads. Its description says where it came from and that it is
   not for redistribution. Consequence: if a game update stops the native layer from loading, converted
   mods are not offered until it loads again.
34. **Departure boards: the screen is written live** (seen in the game: the board places, the message shows and the
   clock is written live). A dot-matrix
   departure board of this project's own (model, picture and logic; nothing of any other mod): a placeable
   board on a post under the landscaping assets, its screen 240 x 50 amber dots. The native layer notices
   the texture the game loads for the screen and copies a new picture into it when the text changes, so
   the lit dots are part of the game's own picture - hidden behind what stands in front, glowing at night.
   For now every board shows the same thing: the three lines "TF3OpenAPI / Departure information
   unavailable / github.com/k8se10/TF3OpenAPI" (boards are not yet wired to stations) and a running clock.
   The clock is the game's own running time read as a clock (an hour of play at normal speed is an hour
   on the board; it stops when the game is paused). The first version followed the sky's time of day and
   ran backwards: in the game's usual setting the sky does not run through a day, the game moves it
   between a morning, a noon and an evening state by chance, in either direction. `[Boards] Enabled=1` in `tf3api.ini` (default 0 until
   seen working); without the native layer, or with it off, a board shows its shipped picture with
   `--:--:--`. Script side: `tf3api.boardLines`, `tf3api.boardClock`, `tf3api.boardsSeen` (API version 9).
   What the native code paints is checked to be the shipped picture byte for byte
   (`tools/tests/board_picture_test.cpp`). (`3dfe684`)
35. **Day clock: a clock in real time, and three ways to play** (the clock seen running in the game, in
   step with the Timetables mod's; the calendar modes, the sky and the wear scaling not yet reported on). A new script mod, `tf3api_day_clock`, enabled per save. As the game ships, a calendar
   day lasts four seconds and the sky has nothing to do with the date. With the mod there is a clock that
   runs in real time - at normal game speed a second of play is a second on the clock, in every mode - and
   a setting for the calendar: **Realistic** (a calendar day is 24 hours of play; the date changes at
   midnight), **Balanced** (a calendar day is one hour of play; the date changes on the hour) and
   **Transport Fever** (the calendar keeps the game's own pace, so years, vehicles and costs are balanced
   as shipped; only the clock is added). The sun and moon follow the clock - day and night come at the
   clock's hours - unless that is switched off in the mod's second setting ("Sun and moon"); switched off,
   the sky goes back to the cycle it had. It uses only the game's own commands: the calendar speed (the
   value the game's "Calendar Speed" control sets, which by the game's own description changes the
   calendar and not the simulation) and the sky's time of day. A calendar the player has stopped stays
   stopped, and a player who picks another sky cycle keeps it. **What follows from a long day:** years
   pass 21,600 times more slowly in Realistic and 900 times in Balanced, so vehicles and buildings that
   appear by year appear that much later in play. Removing the mod leaves both settings as they are; the
   game's own controls set them back (calendar speed 1x, cycle "Dynamic"). **Works alongside the Timetables mod** (`celmi_timetables`): seen in the game with both
   enabled, the two show exactly the same time (an earlier version of this entry declared the pair
   unsupported; that declaration is gone). The
   departure boards show the same clock. **Vehicle wear and age follow the calendar** in Realistic and
   Balanced: the game wears a vehicle, and counts it towards the end of its life, by hours of play in
   proportion to its model's lifespan, so every model's lifespan is multiplied by what the day was
   stretched by (900 or 21,600) when the game loads it. A vehicle then wears over the same calendar years
   as in the game as shipped, and vehicles keep their proportions to one another. Nothing of it is stored
   in a save (a save keeps a vehicle's condition and when it was bought); it can be switched off in the
   mod's settings. No native code. Test: `tools/tests/day_clock_test.lua`.

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
    motorway standard keeps an M or (M) number unless the player chose that type for it. (`e044cca`)
10. Only 14 B roads on a 175-town map: nearly every road counted as a town street. (`6f1f6eb`)
18. The worker thread never started in the running game ("Lua functions missing"). The bridge finds
    `luaopen_base` and hooks it, which replaces the function's first bytes; the worker then scanned for the
    same bytes and found nothing. The worker now takes the unhooked function from the bridge. Seen on both
    builds; on disk the signature always matched. Seen in the game on build 40420: `worker: available`,
    the self-test ran, and the road-names script loaded its six files into the worker. The self-test also
    showed the worker's state without the `tf3api` table (the unhooked function had been handed over); the
    worker now calls the hooked one, like the game does. (`28cd629`, `9120435`; seen in the game: the
    self-test reports the table, and road names are drawn again, named on the worker thread)
    That missing table is also why road names stopped being drawn once the worker ran: the naming pass in
    the worker hands the labels to the native side through that table.
19a. Only one road or junction window is open at a time: opening another closes the one that was open. The
    small TF3OpenAPI window is not counted. (`9bf290a`; not yet seen in the game)
19c. Drawing a city: the city was made, then the TF3OpenAPI window stopped with a Lua error ("attempt to call
    local '_'"): a loop variable in the list of cities had the name of the game's translate function.
    (`0304702`; seen in the game before the fix, not yet after)
19d. Mod converter: placing a converted whole-station construction stopped the game (`edgeList.edgeType ==
    BaseEdgeType::NORMAL || edgeTypeIndex >= 0`): it named a kind of bridge or tunnel the newer game does not
    have. Kinds of track, street, bridge and tunnel are now turned into the newer game's own (the standard
    ones where there is no like), and a construction that is a whole station or depot in itself, not built
    from modules, is no longer written out at all until its stops and platforms are converted; the report
    says so. (`0304702`; not yet seen in the game)
19f. Mod converter, lamps (`a3f32c8`; seen wrong in the game, the fixes not yet seen): on one converted train
    the rear lamps were white headlamps with headlight beams, on another there were no rear lamps by day.
    Old mods put the older game's round lamp mesh on a vehicle with a material of their own; the converter
    had taken the lamp's colour from the mesh's name ("white") and thrown the material away. Now the colour
    comes from the material's glow (red = a rear lamp), the material is kept with its own picture, each lamp
    part gets a name of its own (five parts shared one, so lights were tied to the wrong lamp), a lamp
    material is lit round the clock as the newer game's own are, and one whose picture was the older game's
    is given a glow strength that shows with the stand-in picture. Seen in the game once entries 19h and 22
    were in as well: the lamps of that train are right.
19g. Mod converter, text on models (`a3f32c8`; seen in the game: sharp close up): a destination display
    was a smear. The newer
    game draws a label's text at the label's size taken as picture points and scales it into place (its
    own: 161 x 9 with a transform of 0.01); the older game's labels give metres (0.78 x 0.12). Converted
    labels get a hundred times the size and a hundredth of the scale: same place, same extent.
19h. Mod converter, lamp pictures in `.hdr` (`c7c630a`, `c5e57b4`; seen in the game: the pictures load): after
    19f one converted train had a single working headlamp and no rear lamps. Its other lamps use the mod's
    own bright `.hdr` pictures; the game's log says "Unknown/Unsupported format used E5B9G9R9UfloatPack32"
    for each. The converter now reads such a picture (Radiance RGBE, packed or plain) and writes an
    ordinary `.dds` with mip levels, with the picture's brightest value as full white; the brightness the
    picture no longer carries goes into the material's glow strength, the colour stays. (`c5e57b4` reads the
    picture's size line without a library call the DLL's build settings reject.)
19e. Mod converter: whole rail stations built by one construction now convert (`2c747dc`; simulated builds
    only, not yet seen in the game). In the older game the platform models carried the walking lanes and
    the stops, and the construction listed which model's stop goes with which track node. The converter
    collects each model's lanes and stops; when the station is built, the lanes of every model are laid out
    in order in the station, and each stop's node and edge numbers - which count through its model's lanes
    - are turned into the newer game's (lane list, number) pairs, with the track node where the train
    stands, the kinds of train it takes, a catchment circle and capacities from the game's own function.
    Five mini stations and their five repaints, built outside the game with stand-in libraries, come out
    with one or two stops each and every waiting edge pointing at a real lane. Whole depots and road,
    water and air stations are still held back. Track kinds an old mod brings are replaced by the game's
    standard track until those are converted.
19b. The naming script's messages also go to `tf3api.log`: on build 40420 the game's own log showed none
    of them. (`9bf290a`)
13. Converted station: underpasses did not cut the terrain away. The older game's `hole.lua` ground texture
    is now mapped to the newer game's. (`fe23326`; built, not yet seen in the game)
14. Converted station: platform numbers and name boards stayed empty, nobody could walk to the platforms,
    and the game's own buildings in the station were reported as not drawing properly. Three causes found
    by reading the game's station scripts beside the mod's (`dd61d53`, with the move to build 40420 in
    `4fbd2eb`):
    the newer game's modules build into the station's inner part and board numbers count that part's
    models, while converted modules built into the outer one - they are now given the inner part; the
    game's table of walking lanes for its own models is keyed by plain names, which the adapter had already
    prefixed - the game's models now keep plain names while a station is built and are prefixed in a
    closing step; and lanes the mod's own models carried (12 of 39 models in the test mod) were dropped,
    since lanes belong to the station in the newer game - they are collected at conversion and handed to
    the station. Seen in the game on build 40420: platform signs, the station buildings and the underpass
    cut are right. Boarding and walking paths: see entry 16.
15. Converted station was not taken for a train station by another mod (one that adds a range setting to
    stations recognises them by the path of the update script, and entry 14 had pointed that at the
    converted mod's own script). The update script is the game's own again; the closing step is now put in
    place by the mod's modules when they run. A converted station with none of the mod's own modules left
    in it does not get the closing step. Seen in the game: the range option is offered again. (`012f627`)
16. Converted station: people stood with their feet inside the platform and jumped to it instead of walking
    there (seen in the game; boarding and alighting worked). The newer game's track lays the lanes people
    wait on at the height of its own platforms, 1.1 m; the converted mod's platforms and its walking lanes
    are at 1.5 m, so the waiting lanes lay inside the platform and did not meet the mod's lanes. The game's
    waiting lanes that run along one of the mod's platforms are now lifted to the height of the mod's
    lanes. Seen in the game: feet are right. People still jumped from the station entrance onto the
    platform: the game's buildings end their lanes at the game's platform height too. Every end of one of
    the game's lanes that lies straight below a node of the mod's lanes (up to 0.6 m) is now moved up to
    it - the mod's platform has its lane ends at the same spots as the game's own platform, 0.4 m higher.
    Seen in the game: people use the platform, underpass and building paths. A station built before the
    fix has to be removed and built again - the lanes of a built station are kept as they were.
    (`db80a07`, `49eb73d`)
19. Converted station: the terrain was not cut away for the underpass stairs. Two wrong turns first (taking
    the platform's ground out from under the stairs, `a9d8aac`; leaving the texture name without `::`,
    `2420a48`), both withdrawn or harmless. A test build with the rules of the build where the cut had
    seemed to work showed the same filled underpass, so none of the later lane changes had broken it; and
    the game's own station, built beside it, was cut. Reading the game's own underpass model gave the
    answer: the newer game does not cut terrain for the "hole" ground texture at all (its file is plain
    sand). Its underpass model, like its tunnel portals, carries entries in its light list with
    `mode = "DISCARD"`: boxes inside which the terrain is not drawn. The converted mod now ships models
    that are nothing but such a box, in 49 sizes, and its station library covers every hole face a module
    lays with as few of them as fit (a 20 x 3.2 m face takes three). (`8428d15`; seen in the game on build 40420: the
    underpass is open)
20. `[Converter] StationDebug=1`: a converted station writes its walking lanes, models and ground faces to
    `tf3api_out\station_lanes_<mod>.txt` each time it is built, for finding problems like the ones above.
    (`3f1136e`)
17. Converted vehicles: rear lights were lit at night only. The red light sources the converter adds are
    now on round the clock, and so is the red stand-in material for a rear lamp whose picture the mod does
    not carry (as the game's own rear lamp material is). Headlight beams stay night-only. Seen in the game.
    (`db80a07`)
21. Converted vehicles: body sides and windows of some older models looked stippled and see-through (seen
    on a converted Class 450). Such a body is one material of a transparent kind with a cut-out threshold,
    its paint almost but not quite opaque. The newer game dithers by opacity and only cuts at its own
    threshold, which was left at nothing. A material the mod marks as cut-out now cuts at the mod's
    threshold, and paint from 90% opacity up is drawn solid; glass keeps its dither. (`014e047`; applies to
    every converted mod. Entry 25 goes further for a picture that holds paint and glass.)
22. Converted vehicles: a lamp with the mod's own lamp picture showed a pattern of five small lamps (seen
    on a converted Javelin). Such a picture is a sheet of five lamps made for the older game's lamp
    meshes; the stand-in lamp showed the whole sheet. It now shows the one lamp its old mesh pointed at
    (the middle one for a white lamp, the top left one for a red lamp). The exact spots and the lamp's size
    were then read from the older game's own lamp meshes. (`9335b18`, `8bd12c9`; seen in the game: right.)
23. Converted vehicles: destination displays were hard to read from a distance, the text breaking up into
    dots. Old models ask for text with hard edges (`alphaMode = "CUTOUT"`); the newer game's own models
    only use blended text. Converted labels are now blended. (`b6325db`; seen in the game: no better at a
    distance. The cause is in how the game draws text on models: see Investigated.)
24. Converted vehicles: the head lamps of an older-form model (one whose lamps were always on) only glowed
    at night. A lamp that is switched by direction now glows by day as well, as the game's own lamps do
    and as trains run in daylight; the beam on the ground stays for the night. Models in the newer form
    already did this. (`a71258c`; seen in the game.)
25. Converted vehicles: a body whose windows are painted into its picture as partly opaque glass (the
    Class 450) was drawn as a pattern of dots at the windows. The older game drew such a material evenly;
    the newer one has no single material that does. The converter now reads the picture, and where it is
    paint and glass it writes the material twice - the paint solid with the glass left out, and a blended
    glass twin - and adds each such part to the model a second time for the glass, moving with its doors.
    (`67171c1`; applies to every converted mod.) Seen in the game: it broke the train - carriages facing
    the wrong way and folded into each other. The wheels and bogie frames use the body's material, so they
    were copied too, and the game finds a vehicle's axles by the name of their mesh: twice the wheel sets,
    in a second place in the model. A bogie is now left out of the copy, whole (`379fce8`). Seen in the
    game after that: right while standing at a depot, then folded up again, on newly bought trains each
    time. So it is the added parts themselves that upset how the vehicle stands on the track, not only the
    copied wheel sets; why is not known. The glass copies are off unless `[Converter] GlassParts=1` is set
    (`c37592f`); without them the body is solid and the glass is drawn as the body's own material draws
    it. (The dark cast seen at the same time was something else: entry 27.)
26. Converted vehicles: a dark cast over parts of a body whose picture is otherwise right (seen on the
    Class 450, with the carriages the right way round again and the windows as glass). The older games'
    shaders read a normal map by its red and green only and work the third value out; the newer game does
    that only for a texture marked `redGreen`, and otherwise reads all three. This mod's normal map is
    plain grey wherever nothing was painted, which read as three colours is a direction pointing into the
    surface. Every normal map of an old mod is now marked `redGreen`. (`e982200`; seen in the game: the
    dark cast is still there, so this was not its cause, or not all of it.)
27. Converted vehicles: the dark cast over parts of the Class 450's body (it was there before any of the
    work above, as the player said). Found by laying this mod beside the three that look right: its normal
    maps are not painted where the body's picture is. One is plain grey over 46% of its area, the other a
    dark blue over 57%, and neither colour means "flat": by the two values the games read, both say the
    surface leans hard to one side, so it is lit as if it faced away. The converter now knows which
    textures a mod's materials use as normal maps and, when it writes one out with its mip levels, makes
    flat whatever is grey or leans by more than about 50 degrees. The three other trains' normal maps are
    left as they are (nothing of theirs is over the limit). Only `.tga` normal maps are covered; a packed
    `.dds` one is not rewritten. (`1790ed9`; seen in the game: the dark cast is gone and the train is whole.)
28. Converted road vehicles: most buses of a first batch of eight bus mods were missing from the game. Its
    log gave two causes. (a) 247 models were skipped while loading: a model that borrows its meshes from
    another old mod had its wheels and axles still named as if the meshes were its own, and the game looks
    each of those names up among the model's parts and gives the model up when one is not there. Wheel and
    axle names are now written exactly as the part's mesh is, and a name no part carries is left out with
    its radius (the older games passed over those). (b) 141 models were removed for naming door animations
    that were not there: animations of another old mod are now referred to in that mod, as meshes and
    materials already were, and an animation of the older game itself is taken off the part (the door does
    not move) instead of losing the vehicle. (`04bf886`; checked outside the game on the eight mods: 486
    models, every mesh, material and animation they name exists. Not yet seen in the game.)
29. Converted vehicles: the dirt and rust that every vehicle material lays over its paint came out as plain
    grey, because old mods use the older game's four textures for it without carrying them. The newer game
    has the same four under another name; they are used now. (`04bf886`; not yet seen in the game.)
30. Converted vehicles: the text of a destination display slid off its display in curves. The newer game's
    own models tie every label to a part of the body; old models leave that empty, which ties the text to
    the model's origin, and a body lies between its bogies in a curve, not on that origin. A label without
    a part is now tied to the nearest part that moves with the body (no axle, bogie or animated part), and
    placed in that part's own space. (`04bf886`; not yet seen in the game - that a label is placed in its
    part's space is taken from how the game's own models are written.)
33. **Departure boards: the graphics device was lost a short while after a board's full-size screen
    texture loaded** (three sessions; the game reports "Device lost error: there was a problem with the
    graphic card", the driver logs an error at the same second). Not proven which of these was the cause;
    all three are corrected (built and deployed; not yet seen to cure it in the game):
    (a) the game makes two images of a screen's full size at once and fills only one - the writer took any
    image of the right size and format as a screen, and may have copied into one that has nothing behind
    it; it now writes only into an image the game has itself copied data into;
    (b) the game could destroy an image while a copy of ours into it was still waiting to run (its
    textures are swapped for larger and smaller ones as the camera moves); the image list is now held
    from choosing to submitting, and the game's destroy call waits for a pending copy that names the image;
    (c) our copy was submitted on the game's queue without regard to the game's own submits from other
    threads; every submit and present of the game and our own now share one lock.
32. Departure boards could not be found in the game: the tool that builds the board's mod wrote an empty
    list as `{ , }`, which is not Lua; the game skipped the construction with a line in its log and
    nothing on screen. Fixed, and a test now loads every file of the mod as the game would
    (`tools/tests/boards_test.lua`). (`32e5376`)
31. Converted road vehicles: doors that did not move. The older game sends two door events the newer one no
    longer has, `doors_open` and `doors_close` (they stand beside `open_all_doors` in the older game's
    executable and are absent from the newer one's); several bus mods file their door movements under
    them. Such movements are now put under `open_all_doors` / `close_all_doors`. (`ae0edc6`, `80b2b48`;
    not yet seen in the game.)
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
   the two. Not yet re-measured in the game. (`7c44321`)
6. **Road names, cost of naming** (offline, on the exported network of that save: 8,561 segments, 175
   towns): grouping about 100 ms, links between towns about 250 ms spread over about 150 frames (worst
   frame 26 ms), numbering and naming about 250 ms in one frame. Runs once per load and once after each
   change to the road network. Not yet measured in the game.
7. **Road naming on the worker thread.** With the worker available the whole naming pass leaves the game's
   threads (Groundwork). Seen in the game on build 40420: "named on the worker thread; the answer came
   after 8 ms" for a re-naming after a change. One session, one save. (`29d55ba`, `9120435`)

### Documentation

1. `README.md`: what the project is and is meant to become, the build it targets, status tables, honest
   results, licence. (`2f77932`, `0cf2030`, `28bbfbd`, `01f8445`)
2. `LICENSE`: permissive with attribution; no charging for the code or derivatives. (`01f8445`)
3. `re_notes/camera/camera_pipeline.md`, `re_notes/renderer/culling.md`, `re_notes/renderer/shadows.md`,
   `re_notes/scripting/lua_vm.md`, `re_notes/map_export/road_names.md`, `re_notes/platform/api.md`.
4. Project renamed to TF3OpenAPI, short name `tf3api`. (`f6ec2a6`, `0cf2030`, `c74d316`)
5. Converter notes: `re_notes/converter/tf3_formats.md` (the newer game's formats and what it already does
   for old content), `design.md` (what a conversion has to do, decisions, what was learned from each mod
   tried), `stations.md` (the two games' modular stations side by side). (`92f0dda`, `1e3d77d`, `e2a8ba6`,
   `5332894`, `d939f29`, `7c9853a`)
6. `re_notes/map_export/uk_research.md`: how British road numbers, postcodes and cities work, with sources;
   the naming rules follow it. (`f78b5b6`, `8b983cb`)
7. Roadmap in `README.md`: a converter for Train Simulator content (`87c57e5`), trains that change ends,
   and multiplayer as a mode of its own, last of all (`5d1049d`, `6d19163`).

### Groundwork

000. **Signatures checked against build 40420.** `tools/check_signatures.py` on the newer executable: all
    match once except the occlusion module's "terrain tiles" caller, which matched nowhere - two stack-frame
    sizes inside the pattern had changed. The function was found again as the only one with that opening
    that calls the frustum test, and the pattern now leaves those sizes open and runs on until it is unique
    on both builds. (`4fbd2eb`)
00. **A Lua state of our own on a worker thread** (`d084af2`; seen in the game on build 40420 after Fixed
    18). The DLL can make a
    separate Lua state with the game's own Lua and run it on its own thread, so that a script mod's heavy,
    pure work need not run on the game's threads at all. Scripts reach it through `tf3api.workerStart`,
    `workerRun` and `workerTake`. A self-test at startup runs a line of Lua in a fresh state and logs the
    result.
000. **Road naming on the worker thread** (`29d55ba`; tested offline with a stand-in for the worker, then
    seen in the game on build 40420). When the
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
   under the game's interface instead of over it. (`6437b04`, `6547689`)
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
    work now uses the extended path form, which has no such limit. (`87c57e5`)
26. **The older game's own files as a reference.** With Transport Fever 2 installed beside the newer game,
    converter rules that had been worked out from mods alone were checked against that game's files: all
    185 text labels on its own vehicles ask for hard-edged text; its round lamp meshes point at fixed spots
    of a five-lamp picture (and are 17.5 cm across); its lamp material is a glowing one on a bright `.hdr`
    picture; its two kinds of track cost 75 and 150 where the newer game's cost 180 and 540; its
    transparent shaders throw away what is at or below the threshold and it uses "cut-out" for leaves,
    benches and aerials, which are drawn solid. (`8bd12c9`, `67171c1`)
27. **The engine's own function names, recovered.** The game is built with its assertions in, and every
    assertion carries, as plain text, its condition, its source file, its line and the full name of the
    function it is in. Two small scripts for the Ghidra disassembler collect them: on the current build
    (40420), 10,972 assertion sites give real names for 5,768 functions (`StreetGeometry::CreateLanes`,
    `ecs::TransportNetworkSystem::EntityAdded`, `PathFactory::Compute`, ...) and the conditions name the
    data in the original words. With the source paths the executable names (893 files in 95 folders) this is
    a map of the whole engine. The method and the scripts: `re_notes/engine/`, `tools/ghidra/`; the lists themselves
    are made by anyone with the game and are not published (they are texts out of the game's executable).
    (`8c273a5`, `b149d4d`, `1b78bcc`, `c2dc170`)
28. **First reports on three systems**, each marking what was read against what is only known by name:
    streets, lanes and the road network (`re_notes/engine/streets.md`); navigation and path finding
    (`navigation.md`) - one search template for vehicles, people on foot, by car and by line, and ships; a
    person's journey is three candidates, one per mode, worked out on the thread pool, the cheapest by the
    person's own weighting taken; vehicles search with no distance estimate; and the asset pipeline from
    files to the graphics card (`assets.md`). (`b149d4d`, `1b78bcc`)
29. **A second way to find a hooked function: by the texts it refers to.** When a byte pattern no longer
    matches after a game update, the function can be found as the one function that refers to a given set
    of texts (assertion conditions and names stay the same from build to build while the code is compiled
    anew), using the executable's own function table; refused unless exactly one function qualifies.
    `sigscan::FindByTexts`, `FindUniqueOrByTexts`; a test that maps a game executable without running it
    (`tools/tests/sigscan_test.cpp`, cases from `tools/make_sig_cases.py`). Results on the current build:
    of 400 functions taken evenly from the list of named ones, 238 found at exactly their address, 162
    refused because several functions share their texts, none found wrongly. Across a real update (the
    previous build's list against this one's) 3,425 functions keep one identity by their texts, 59%. The
    occlusion module's six scene-rendering hooks that have a name of their own now fall back on it when
    their byte pattern fails; the Lua interpreter's functions and a few others carry no such texts and
    still rest on bytes alone. (`c2dc170`, and the commit after this entry.)
30. **Left-hand traffic: groundwork for a mod of this project's own.** Read first: the game has no setting
    for the side of the road - it follows from each lane's direction, the lanes of stations, depots and
    industries, and the vehicle models; the game's own traffic-light script already works the side out from
    the lanes; the older game's mod and the one in use today were gone through as references of behaviour
    (`re_notes/left_hand_traffic/reference.md`, no code or data of either used). Built and tested outside
    the game only: the rule for streets (every vehicle lane of a two-way street turned; a one-way street
    keeps its direction) and the rule that turns the text of a display round on a mirrored vehicle so that
    it stays on its display and reads the right way. Not in the game, not usable yet.
    (`789b97b`, `73f0a56`, `8e5a293`, `d790cba`)
31. **Converter: pictures can be written packed, as the game's own are.** Counted over the game's 1,917
    vehicle pictures: all are packed in 4 x 4 blocks with every mip level - colour as DXT1 or (with opacity)
    DXT5, normal maps as two channels. The converter wrote plain 32-bit pictures, four to eight times the
    size (85 MB for one 4096 x 4096 picture). It can now pack what it writes with mip levels the same way;
    checked by unpacking its output again and comparing with the plain one (average error of one to three
    levels in 255; two train mods went from 185 MB to 106 MB). `[Converter] PackTextures`, off by default
    until seen in the game. (`78cfaab`)
32. **Converter: road vehicles' engine sounds.** Bus and truck mods of the older game build their sound set
    with one helper call that the converter did not know, so they came out silent. That helper is two
    engine sounds (standing and driving) with a loudness curve over speed and a pitch that rises with it;
    the converter now writes those two out, as the newer game's own bus sound sets are made, and finds the
    older game's own road sounds (horns, doors, engines of its bus, car, truck and tram families) under the
    names the newer game keeps them by. (`fb847dd`; checked outside the game on three bus mods.)
33. **The two games' executables compared for what the model format lost.** Every word the older game's
    executable knows and the newer one's does not, limited to words the older game's own models and
    materials use: most are still handled by the newer game's load-time scripts (lamp and indicator part
    lists, emissions, compartments) or are material kinds now defined in data. Not handled anywhere in the
    newer game: `doors_open` / `doors_close` (now converted, Fixed 31), `headLights` (a road vehicle's
    parts shown only at night - not converted yet), `maxTakeOffWeight`, `vehicleDepot` and
    `terrainAlignmentProvider` on models. The full list of events a part can move on, per kind of vehicle,
    was counted from the newer game's own models (`re_notes/left_hand_traffic/reference.md`); it is the
    list the converter needs for ships and aircraft. (`2b508db`, `ae0edc6`)
34. **How the game keeps time** (`re_notes/engine/game_time.md`; build 40420). The engine counts running
    time in milliseconds and holds one number for the calendar: milliseconds per day (4000 as shipped).
    Each simulation step a new day is recorded whenever the running time passes a multiple of that number,
    so the place within the current day is the running time modulo the day's length. The sky's time of day
    is a separate value that nothing in the engine advances: the game's own script sets it, in one of four
    modes (moved between morning, noon and evening by chance - the default; a continuous cycle; the
    computer's clock; left alone).

### Investigated, Not Yet Resolved


0. **Station mods.** Two Transport Fever 2 modular rail stations (one building on the other) convert,
   build and are configurable in the game, with add-ons, later changes, platform signs, buildings, walking
   paths, boarding and the underpass (Groundwork 24, Fixed 13-19). Whole rail stations built by one
   construction convert (Fixed 19e) but have not been seen in the game. Not covered: cargo stations,
   depots, road, water and air stations, a mod's `runFn`, bridge and tunnel kinds.
0. **Converted vehicles: what is still not done.** Four rail multiple units (one from Transport Fever 1,
   three from Transport Fever 2) convert and run with sound, lamps, beams, doors, seats and pictures. Not
   done: the state animations of ships and aircraft; compressing the textures written with mip levels; a
   real shop picture; lamps of stock shapes other than round; telling marker lamps from head lamps (all
   front lamps of a vehicle light together); a window that shows progress while mods convert at launch
   (about half a minute with a dozen mods, during which the game shows nothing).
0. **Text on models breaks up into dots at a distance** (seen in the game on converted trains; the older
   game showed the same displays well). The newer game draws all such text with one small shader of its
   own (`label_text`), which reads the glyph picture at a single spot per screen point and throws away
   what is under the threshold; small text falls apart, and a lit display is put out at its plain colour.
   Blended text (Fixed 23) did not help. A changed copy of that shader (sixteen spots spread over the
   point, a brighter lit display) was made for a test in the game; the result is not in yet. If it
   helps, it helps every display in the game, and the change belongs in the native layer.
0. **Glass painted into a body's picture** (Fixed 21 and 25): settled for now. With the body solid and lit
   right, the windows look fine in the game as the body's own material draws them (player's check on the
   Class 450). Drawing them as separate glass with added parts broke the train and stays switched off.
0. **Adjust Road** (What's New 30): works in the game. Still to build: putting a road back to automatic,
   and marking part of a connected road abandoned.
0. **(Resolved by the layout change, kept for the record.) Buying a converted vehicle stops the game.** The converted Transport Fever 1 multiple unit can be found
   in the vehicle list, but buying it ends in the game's assertion
   `milSystem.GetNumModelIds() <= modelData.models.GetSize()` (`UI::GetCurrentlyUsedModelIds`). Cause not
   found for certain; it happens when the vehicle is put on a line, only for the converted unit, and the
   old-location route is the suspect (entry 15 under Groundwork replaces that route).
00. **Road names: errors while naming a slice a frame.** The game log of a session shows 148 Lua
   exceptions from the road-names script's sliced naming ("Value is not a string, but a thread", raised
   inside the coroutine), although the naming finished. Not looked at since: with the worker thread
   running (Fixed 18) the sliced path is only the fallback.

1. **Memory growth in the cockpit view deep underground** (about 4 GB per minute seen once). The allocation
   profiler counts commits without frees, so the owner is not proven. (`9410c20`, `d24152d`, `8f0a8e0`)
2. **27 shadow passes for 4 cascades** in the cockpit view: not explained.
3. **Zoomed-out view is limited by the main thread**, mostly drawing and stepping the interface. No fix yet
   beyond the town label one.
4. **Road labels under the game's interface** (resolved; `9bf290a`, `f196172`; seen in the game). The trace of
   a frame on build 40420 shows three of the game's render passes going onto the screen image: a clear at
   the start, one with some 160 small draws late in the frame, and a last one with some 180 small draws
   after three blur passes - the game's windows and panels. The overlay now records its own pass into the
   game's command buffer just before that last pass (found each frame by counting the passes onto a
   swapchain image in the frame before), and the game's own drawing state on the command buffer is put back
   afterwards. Where that cannot be done for a frame the labels are drawn on the finished frame as before.
   `[Overlay] UnderInterface=0` switches it off. Seen in the game: it works and the game's interface is
   undisturbed, but the labels were under the windows only, still over the buttons and bars, which the
   game draws in the pass before. Second step (seen in the game: right): the overlay's draws are put inside
   that earlier pass, right after its first draw - the one that puts the picture of the world on the
   screen - so they lie under everything of the interface. That needs the overlay's pipeline to fit the
   game's pass (one colour attachment, no depth, one sample); where it does not, the first step's place is
   used.
4a. **Labels cannot be clicked while a tool is in use** (`7c44321`; built; not yet seen in the game): with anything other
    than the game's default look-around tool active, a click on a label opens nothing.
4b. **Clicks on road labels also reach the game**, and a label behind a game window can still be clicked.
   Needs the game's input to be intercepted.
5. **Road labels are not hidden by terrain or buildings** in front of them: the overlay draws on the
   finished frame without depth.
6. **Whether an upgrade replaces a road segment** (which is how a change is noticed) is assumed, not
   confirmed.
7. **Saving road names with the game is untested in the game**, including whether such a save loads
   without the mod.
8. **Build 40420.** Development moves to it. Every signature resolves on its executable; the functions
   the fixed structure offsets were read from are 97-98% byte-identical between the two builds.
   From the first sessions on 40420 (build number read from the game's log): all signatures resolved in
   the running game, hooks installed, the converter ran and converted stations and vehicles were used. A
   feature-by-feature check of the rest is still to do.
