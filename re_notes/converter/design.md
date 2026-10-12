# Converter: what it has to do, and how it is being built

Status: the rules (`converter/convert.lua`) and the launch-time host (`native/src/mod_converter.cpp`) are
built and pass their tests outside the game. Nothing has run on a real old mod or in the game yet.

## The requirement

Convert older mods (Train Fever, Transport Fever 1, Transport Fever 2) so they work in Transport Fever 3,
doing what EAT1963's "TPF1 --> TPF2 Konverter" (v0.17) does and carrying the result on to Transport Fever 3.
And one thing the reference does not do: **convert at launch, without any steps in the game**, so that a
converted mod is already in the mod list by the time the player reaches "load game".

The reference converter is used as a description of behaviour only. None of its code or data is used here.

## How the reference is used (its "how to" document)

1. The converter and the mod to convert both go into the game's `mods` folder.
2. The mod's own `mod.lua` is renamed out of the way and replaced by a small `mod.lua` from the converter
   whose only job is to call the converter when the mod is activated.
3. In the game: free play -> custom settings -> switch on the converter, then the mod. The conversion runs
   inside the game's mod loading; the game usually minimises when it is done.
4. Switch both off again (mod first), quit, delete the helper `mod.lua`, rename the original back.

It works **in place**: the mod's own files are rewritten (optionally with `_backup` copies), and a
`transfer_log.lua` is left in the mod's folder. It relies on the mod script environment of Transport Fever 2
having Lua's `io` library and being able to run shell commands (`mkdir`, `dir`, `del`).

## What the reference converts (read from its script and changelog)

Source: models with no `version` (Train Fever / Transport Fever 1 layout). Result: `version = 1`.

- **Model structure.** An old model's levels of detail are groups: `children` entries of type `MESH` or
  `GROUP` referring to `.msh` and `.grp` files by id, with `events`, `animations` and `matConfigs` on groups
  and meshes. The result is one node tree per level of detail (`node` with `children`, each node with `name`,
  `transf`, and for a mesh `mesh` and `materials`).
- **Materials move from the mesh to the model.** Each sub-mesh in an old `.msh` lists its materials, and
  `matConfigs` (zero-based) picks one per sub-mesh; the model's own `matConfigs` picks a configuration per
  child. The chosen material per sub-mesh is written on the node; `materials`, `matConfigs` and
  `animations` are removed from the `.msh`.
- **Names.** Every node gets a unique name made from its file name and a counter.
- **Animations.** Group `events` map an event name to an animation and direction per child; the result is
  an `animations` table per node, keyed by event. Key-frame rotations can be split into steps of at most N
  degrees (default 5). Optionally each animation is written to an `.ani` file (times + matrices), in a
  forward and a backward version, and referenced by `FILE_REF`.
- **Load indicators.** Meshes that a `capacities` load indicator refers to are left out of the tree, and
  the load indicator entries are dropped.
- **Capacities.** `transportVehicle.capacities` becomes `compartmentsList` with one load configuration per
  cargo; cargo types outside the stock list are dropped.
- **Seats.** `transportVehicle.seats` becomes `seatProvider` (driving licence by carrier, `animation` from
  `standing`, defaults for `crew` and `forward`, a 0.15 m sideways nudge for sitting seats, tiny matrix
  values rounded to zero).
- **Other metadata.** Emission entries added; `maintenance.lifespan` in years x 730.5; running costs and
  price set to automatic (-1); `topSpeed` km/h -> m/s for rail and road; empty lists added for the
  per-kind parts (`backBackwardParts`, `blinkLightsLeft`, `beaconLights`, ...); ship and plane `type` from
  weight / wing area; `multipleUnitOnly` and `reversible` defaulted; a `MESH` collider added.
- **Text kept as written.** `description`, `cameraConfig` and `local x = require "..."` lines are carried
  over as source text, so `_("...")` translation calls survive.
- **Materials.** Types that no longer exist are mapped: `REFLECTIVE*` -> `PHYSICAL*`, `TRANSPARENT*` and
  `PHYSICAL_ALPHA_NRML_MAP*` -> `PHYS_TRANSPARENT*`, taking the old colour map as albedo. `EMISSIVE` gets an
  emissive scale (45, or 12 for `.hdr`). Missing normal and metal/gloss/AO maps get small default textures.
  `redGreen` on a normal map is set by reading the DDS header (`ATI2` / `BC5U`). Transparent materials get
  `alpha_test` with cutout.
- **Train Fever mods.** `info.lua` is turned into a `mod.lua`.
- **Repaints.** A helper makes repaint models from a master by swapping material names.
- **Log.** `transfer_log.lua`: files found, files used, files with errors.

Stated limits: bridges and stations are not converted; mods that break the material conventions fail.

## What Transport Fever 3 adds on top (from `tf3_formats.md`)

A `version = 1` model is where the reference stops. From there to Transport Fever 3:

- **Layout.** `res/models/model/...` and friends -> `content/...`, with every reference rewritten.
- **Materials are nested differently.** Each parameter holds `fragmentProperties = { { ... } }`,
  `fragmentSamplers = { <name> = { fileName, ... } }` or `vertexProperties`. The sampler and property names
  per parameter are defined by the game (47 parameters; e.g. `map_albedo` -> sampler `albedoTex`,
  `map_normal` -> `normalTex`, `map_metal_gloss_ao` -> `metalGlossAoTex`, `two_sided` -> properties
  `flipNormal`, `twoSided`). Old textures need `light_receiver.isLegacyMaterial = true`.
- **Metadata.** The game upgrades most old vehicle metadata itself when it loads a model. The converter
  writes what the game cannot guess and leaves the rest to that upgrade.
- **Mod definition.** `mod.lua` -> `mod.json`; `strings.lua` -> `strings.json`.

## Decisions

1. **Runs at launch, in the native layer.** The game lists its mods in the first moments of start-up, so the
   conversion has to be finished before that. The DLL does it while it is being loaded, before the game's
   own start-up code runs; nothing is done when there is nothing new to convert. As built it only does file
   work there (no threads, no windows), so a large mod delays the game's window with nothing on screen: a
   progress window needs the work moved to the game's entry point, which is not built.
2. **Never in place.** Old mods go in a `legacy_mods` folder in the game's directory, one sub-folder each;
   the layer creates that folder at launch if it is missing. A new mod folder is written for each. The source
   is not touched (the reference's in-place rewrite is the one behaviour deliberately not copied).
3. **The conversion rules are Lua, run by an interpreter built into the DLL**, not by the game's own Lua:
   the game's is not usable that early, and old model files are Lua programs (`function data()`), so a Lua
   interpreter is the right reader for them. The same rules run from the command line for testing.
4. **A report per mod**, in the output folder, in the manner of `transfer_log.lua`: what was found, what was
   converted, what was not, what needs a hand fix.
5. **Done once.** A converted mod is remembered (`legacy_mods/tf3api_converted.txt`: number of files, total
   size and newest change of the old folder), so later launches skip it until the old mod changes.
6. **Output layout (superseded, see "Third run" below): the old one, below `content/`.** The game reads `content/res/models/...` and
   `content/res/textures/...` as old content and only there accepts models older than its own version
   (found by running into its assertion; see `tf3_formats.md`). So the result is the old mod's own `res`
   tree under `content/`, with old group-form models turned into node trees (`version = 1`), materials in
   the old flat form with the dropped types mapped, references unchanged, and everything else under `res`
   (sounds, sound sets) carried over as it is. The first attempt wrote Transport Fever 3's own layout and
   nested material form; that code is kept (`C.layout = "content"`) but is not what a mod is converted to,
   because models there must be version 2, which the converter does not write.
7. **Parts keep their place.** Old metadata refers to parts by position in the tree, and the game turns
   those positions into names when it loads the model. So the converter drops nothing from the tree: a
   cargo-level mesh of an old load indicator stays as an empty node.
8. **Least interference with metadata.** The converter fixes units that changed after Transport Fever 1
   (speed, lifespan) and sets prices to automatic; the rest is left in the old form for the game's own
   upgrade on load.

## First real mod (2026-10-12): a Transport Fever 1 multiple unit

- Its model builds seats and door animations with scripts of its own, using the older games' `vec3` and
  `transf` and `math.pow`: the converter now runs those and writes plain data.
- Loaded from `content/res/` the unit was registered and could be found in the vehicle list by searching.
- **Open:** buying it stopped the game with `milSystem.GetNumModelIds() <= modelData.models.GetSize()`
  (`game_ui_util.cpp:321`, `UI::GetCurrentlyUsedModelIds`): the interface saw more model ids in use than it
  has models. Cause not found yet. Not known either whether the same happens with a hand-made Transport
  Fever 2 mod in that location, or only with this conversion.
- It was not in the multiple-unit menu. Transport Fever 3 defines a multiple unit by a `.mu.lua` file beside
  the models (`vehicles = { { name = "x.mdl", forward = true } }, name, desc, filterTags`; 13 in the base
  game), and the cars carry `multipleUnitOnly` so they stay out of the single-vehicle lists. The converter
  now writes one for a powered, carrying rail or tram model, at `content/<the model's old path>.mu.lua`.
  **Unconfirmed:** that a model in the old location is found by that relative name.

## Third run: the old location lists a vehicle but cannot run it

With cargo translated and the unit file written, the game showed the right capacity and listed the unit as
a multiple unit. Putting it on a line still stopped the game: `UI::GetCurrentlyUsedModelIds`
(`FUN_14078a8d0`, called each frame from the render side, `FUN_140654ed0`) compares the model-instance
system's per-model list with `modelData.models` and found the unit's model id beyond the end. Stock
vehicles were fine with the mod enabled. `Importer::SearchAndImportAllModels` logs a warning when it drops
models ("The following N models were removed because they reference an invalid resource"); the session's
log has no such line. So the model was not dropped for a bad resource: a model in the old location is in
the model list (metadata, menus) and not in the renderer's model data. Reading: the old location is there
for the Model Editor's Convert tool to open old models, not for playing with them.

Hence the layout now used: `content/` in the newer game's own form. Models are written as `version = 2`,
which needs what the game only does on load for older versions: levels of detail in rising order of
`visibleTo` (the per-level `configs` entries moved with them) and a `transformatorConfig` (the game's own
default driver per kind of vehicle, `skipFromLod = 1`). Materials are nested and carry
`isLegacyMaterial = true`. A `texture_metadata_cache.lua` is written (per texture: channels, size, mip
levels; every mod of the newer game has one, 4 channels for every `.dds`). Old sound sets are dropped for
now. Everything else in the metadata is still left for the game's upgrade on load, which runs for every
model whatever its version.

## What was added after the first vehicle ran (2026-10-12)

Each of these came from putting a real mod through the converter and looking at it in the game. The rule in
every case is general: it applies to every mod of that kind. Nothing is ever changed in the old mod.

### What version 2 leaves undone

Writing `version = 2` skips every step the game keeps for older models. Found so far, all in the game's own
scripts: sorting the levels of detail, the default `transformatorConfig`, and the whole of
`metadataanimationutil`, which turns the old lists of parts shown by state (front going forward, back going
backward, brake lights) into "on" / "off" animations. The converter does these itself for rail and road
vehicles, with the game's shared animations (`::/vehicle/shared/ani/<event>_on|_off.ani`). Ships and
aircraft (rudder, propeller, beacon) are not done.

### Lamps

- In the older games a mod does not bring its lamps: it names lamp meshes, a lamp material and lamp
  pictures of the game itself. The newer game has none of them, and what lights the scene there is a
  `lightSourceList` on the model, which the older formats lack.
- A part whose mesh is one of the older game's lamps gets a disc of the converter's own, and a light
  source tied to it by the part's name (so every lamp part needs a name of its own).
- Read from the older game's files: its round lamp meshes are 17.5 cm across, lie in the plane across the
  vehicle's length, and point at fixed spots of one picture that holds five lamps - red in two opposite
  corners, white in the other two and in the middle. A mod that puts its own material on those meshes has
  laid its picture out the same way, so the converter's disc shows the same spot, not the whole picture.
- Whether a lamp is a rear lamp is told from the material's glow colour (red), not from the mesh's name.
- The newer game cannot use a Radiance `.hdr` picture on a model (its log names the format). Such a
  picture is rewritten as an ordinary one with its brightest value as white, and the brightness goes into
  the material's glow strength.
- The newer game's own lamp materials are lit round the clock (`fromTime = 0`, `toTime = 24`); without
  those two a glowing material is lit at night only. Lamps switched by direction get them; the beams stay
  for the night (`fromTime = 18`, `toTime = 7`), as on the game's own trains.
- The game turns a whole train round to reverse it, so which end leads never changes for a train. The
  switching the converter writes is the game's own: which end of a vehicle is the head or the tail of the
  train by its place in it.

### Text on models

- The newer game draws a label's text at the label's `size` taken as picture points and scales it into
  place: its own labels are like 161 x 9 with a transform that scales by 0.01. The older game's give
  metres. Converted labels get a hundred times the size and a hundredth of the scale.
- A label's axes: the first is the direction of the text, the second is up, the third the way it faces;
  its origin is its bottom left corner.
- Every label on the older game's own vehicles asks for hard-edged text; the newer game's never do.
  Converted labels are blended. That did not cure text breaking up at a distance: the newer game draws all
  such text with its `label_text` shader, one reading of the glyph picture per screen point.
- A label of type `CUSTOM` takes its text from the construction that places the model
  (`result.labelText[<model index>] = { text of its first custom label, second, ... }`).

### Materials that are part see-through

- The older game's transparent shaders throw away what is at or below the material's threshold, and
  "cut-out" there means drawn solid (it is what leaves, benches and aerials use). The newer game throws
  away only at or below `a2CThreshold`, which is nothing unless given, and passes the rest on with its
  opacity, drawn as a pattern of dots.
- So a material the mod marks as cut-out gets `a2CThreshold` from its threshold, and its opacity scaled a
  little so that paint which is nine tenths opaque or more is solid.
- A body side with its windows painted into the same picture as glass (about two thirds opaque) cannot be
  one material in the newer game. The converter reads how opaque the picture is, from a small mip level,
  without unpacking it. Where most of it is solid and a real share lies between the threshold and 0.85, the
  material is written twice: the body throws the glass away and draws the paint solid; a twin draws the
  same picture blended (`cutout = false`, `sorted = true`, `disableDepthAndNormalWrite = true`, the form
  the game's own glass has). Each part with such a material is added to the model a second time with the
  twin, in a copy of the tree that keeps the same places and animations, so a door's glass moves with the
  door. The copies go last in the model: seats and the like name parts by their number in the tree, and
  nothing that was there may change its number.

### Mods that build on other mods

A file a mod names and does not have is looked for in the other old mods in the inbox and named as that
mod's (`<its id>::/...`); the converted mod lists the other as a dependency. Which mods are in the inbox is
part of what decides whether a mod is converted again.

### Constructions that are not modular stations

A sign, a billboard or a prop keeps its parameters and its own update function; its choices are counted
from 1 where the older game counted from 0, what it builds goes into a part of the construction, and it is
offered under the game's asset menus. Kinds of track, street, bridge and tunnel a construction lays are
turned into ones the newer game has: a kind it does not know stops the game when the construction is
placed. A whole rail station built by one construction has its stops and walking lanes, which the older
game kept on the models, turned into the newer game's station form. Depots and road, water and air
stations are not written at all until they are converted properly.

### Kinds of track

The older games describe a kind of track in one file. The newer game has the same description in two
parts: a street style (shape, models, materials; almost the same fields, with the overhead wire's and the
materials' in tables of their own, and the bed as a material with the size its picture is laid at) and one
template for each form that can be built, without and with overhead wire (speed, years, cost, menu entry,
and which other template adds or removes the wire). Models and materials the old file names from the older
game itself are replaced by the newer game's. Cost is scaled by the ratio between the two games' own
tracks. A converted station that lays such a track names the converted kind.

### Remasters

Beside the general rules there is a list of changes for particular mods (`converter/remasters.lua`). A
remaster applies when the files it names are in the old mod, and is made to the converted copy: an engine
type, text labels added to a model, part of a texture painted over with its own background. The painting
copies one packed block of the picture over the blocks inside a rectangle, in every mip level, so nothing
is unpacked. The old mod is not touched, and the list holds nothing of it - only what to change.

### A converted mod needs its old mod

A converted mod gets a run script (`content/mod.script.lua`, named in `mod.json` as
`<mod id>::/mod.script@runFn`). It asks the native layer `tf3api.legacySource("<the old mod's folder>")`.
Where the answer is not yes - no native layer, or the old mod not in `legacy_mods` - it registers
load-time modifiers (`addModifier("loadModel" | "loadConstruction" | "loadStreetTemplate", fn)`; a
modifier is given the file's name, which begins with the owning mod's id and `::`) that set the
availability of the mod's own vehicles, constructions and tracks to years that do not come. Nothing is
taken out: a vehicle already running in a saved game keeps running. The reason: a converted mod is the
old mod's author's work, and one passed on alone should be of no use to anyone who has not got the
original.

### What the host gives the rules

The rules cannot read or write files themselves. The host (the DLL, or the test programs) gives them:
`list`, `read`, `readHead` and `copy` on the old mod; `write` to the new one; `makeMips` (a `.tga` or
`.hdr` written as a `.dds` with mip levels); `alphaBands` (how opaque a picture is, in sixteen bands);
`paint` (the block copy above); `siblings` (the file names of the other old mods); `resource` (the station
adapter and the remasters, which are built into the host).

## Not built yet

Animation files (`.ani`) and rotation splitting (inline key-frame animations are kept as they are); the
reference's seat adjustments; the state animations of ships and aircraft; repaint helper; zipped mods in
the inbox; compressed textures; a rendered shop picture; a progress window; bridge and tunnel kinds; depots;
road, water and air stations; cargo stations; mods that are scripts.

## Open

- Text on models at a distance (above).
- Telling marker lamps from head lamps: all the front lamps of an old vehicle light together.
- How long a launch takes when everything is converted again: about half a minute with a dozen mods, with
  nothing on screen.
