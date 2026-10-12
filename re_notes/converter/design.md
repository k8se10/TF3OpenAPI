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
6. **Output layout: the old one, below `content/`.** The game reads `content/res/models/...` and
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

## Not built yet

Animation files (`.ani`) and rotation splitting (inline key-frame animations are kept as they are); the
reference's seat adjustments; icons; sound sets; repaint helper; Train Fever specifics beyond `info.lua`;
zipped mods in the inbox; a progress window.

## Open

- Whether the game loads a `version = 1` model as it is (then the converter can stop at the reference's
  result and let the game upgrade the metadata), or needs `version = 2`.
- What the Model Editor's own Convert writes for the same input: that is the reference for the layout step.
- Real source mods to test against. None are on the development machine yet.
