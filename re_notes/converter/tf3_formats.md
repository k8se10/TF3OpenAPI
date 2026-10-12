# TF3 asset formats: what a converted mod has to produce

First pass for the TF1 / TF2 -> TF3 asset converter. Everything under "What the game's own files show" was
read from the game's content archives on build 40408 (4,473 models, 6,806 materials, by script). Nothing in
this note has been tried in the game, and no Train Fever, Transport Fever 1 or Transport Fever 2 mod has been
examined yet.

**The main finding (2026-10-12): Urban Games already cover most of Transport Fever 2 -> 3.** The Model Editor
has a Convert tool for TF2 models, and the base game upgrades old-style model metadata every time a model
loads. See "What the game already does for older content" below; it decides what is left for our converter.

## What the game's own files show

### Layout

One archive per asset, one folder inside it:

```
boxcar_4_alu/
  boxcar_4_alu.mdl
  mat/boxcar_1945.mtl
  mat/tex/boxcar_1945_albo.dds   _cdr.dds   _mga.dds   _nrm.dds
  msh/body_lod0.msh              body_lod0.msh.blob
  ani/open_all_doors/d1_lft.ani
  icons/...
```

Paths inside a model are relative to its own folder (`mat/boxcar_1945.mtl`, `msh/body_lod0.msh`,
`ani/...`). A leading slash refers to the content root (`/vehicle/shared/mat/tex/dirt_albedo.dds`), and
`::/` to the base game from a mod. Vehicles are grouped by kind: `vehicle/train`, `waggon`, `tram`, `bus`,
`truck`, `car`, `ship`, `plane`, `helicopter`, `zeppelin`.

### Model (`.mdl`)

A Lua file, `function data() return { ... } end`. Every model has exactly these top-level keys:

| Key | Contents |
|---|---|
| `boundingInfo` | `bbMin`, `bbMax` |
| `collider` | `type` (`"BOX"`), `params.halfExtents`, `transf` |
| `lods` | list of `{ node = <tree>, visibleFrom, visibleTo }` |
| `metadata` | see below |
| `version` | `2` in all 4,473 models |

The geometry is a **node tree**: a node has `name`, `transf` (16 numbers), and either `children` or a `mesh`
with its `materials` list (one material per sub-mesh). A node can carry `animations`: a table from animation
name to `{ type = "FILE_REF", params = { id = "ani/open_all_doors/d1_lft.ani" } }`. `FILE_REF` is the only
animation type in the whole game (42,017 uses): **animations are always in `.ani` files, never inline.**
Animation names seen most: `idle`, `walk`, `driving`, `sitting`, `open_all_doors`, `close_all_doors`,
`open_doors_left` / `_right`, `close_doors_left` / `_right`.

### Metadata, by kind of model

Keys present in a vehicle's `metadata` (counts are models of that kind having the key):

| Kind | Always | Often |
|---|---|---|
| train (70) | availability, cost, description, emissions, extent, landVehicle, lightSourceList, maintenance, railVehicle, seatProvider, soundConfig, transformatorConfig, transportVehicle | versioning (53), labelList (28), particleSystem (26) |
| waggon (41) | availability, cost, description, emissions, extent, landVehicle, maintenance, railVehicle, soundConfig, transformatorConfig, transportVehicle | loadIndicator (26), lightSourceList (14), seatProvider (14) |
| tram (55) | as train without seatProvider | seatProvider (41), loadIndicator (23) |
| bus (24) / truck (48) | availability, cost, description, emissions, extent, landVehicle, maintenance, roadVehicle, seatProvider, soundConfig, transformatorConfig, transportVehicle | lightSourceList, particleSystem, loadIndicator (trucks 37) |
| ship (27) | ... waterVehicle, seatProvider, transportVehicle | loadIndicator (12) |
| plane (30) / helicopter (11) | ... airVehicle, seatProvider, transportVehicle | loadIndicator |

From the boxcar:
- `transportVehicle`: `carrier = "RAIL"`, `transportModes`, `loadSpeed`, `compartments` (each a list of
  `loadConfigs`, each with a `cargoEntry`: `capacity`, `cargoTypeSet` with included / excluded classes and
  types, `loadIndicator = "bay_0"`, `seats`) and `toHide`.
- `loadIndicator.configs.bay_0.cargoBay`: a box (`bbMin`, `bbMax`), `cargoFormats`, `childId` (a node
  name), `gridSize`, `sizePolicy`, `type = "DISCRETE"`. **TF3 has load indicators as cargo bays**; the TF1 ->
  TF2 converter deleted them, so this is new ground.
- `railVehicle.config`: `axles` (node names), `fakeBogies`.
- `landVehicle`: `topSpeed`, `weightEmpty`, `weightMaxPayload`, `brakeDeceleration`, `friction`, `engines`.
- `transformatorConfig`: `skipFromLod`, `transformator.name` (a `.trf` file shared per vehicle kind).
- `maintenance`, `emissions` (`noise.score`, `pollution.score`), `availability` (`yearFrom`, `yearTo`),
  `cost.price`, `description` (translation keys through `_()`), `soundConfig.soundSet.name` (a `.snd`), `extent`.

Buildings and other assets have their own keys (`transportNetworkProvider` on stations, `lightSourceList`,
`particleSystem`, `seatProvider`, `tree`, `rock`, `autoGroundTex`, `cargoModel`, `person`, `animal`).

### Mesh (`.msh` + `.msh.blob`)

The `.msh` is a Lua description; the numbers are in the `.blob`:

```lua
subMeshes = { { indices = { position = { count, offset }, normal = {..}, tangent = {..}, uv0 = {..} } } },
vertexAttr = { position = { count, numComp = 3, offset }, normal = { numComp = 3 }, tangent = { numComp = 4 },
               uv0 = { numComp = 2 } }
```

Each attribute has **its own index list** (not one shared index buffer). `count` and `offset` are bytes into
the blob. Attributes seen: `position`, `normal`, `tangent`, `uv0` in every mesh; `uv1` in about one in nine;
`jointWeights` in skinned meshes.

### Material (`.mtl`)

A Lua file with `type`, `params`, `order` and `__version`. Each parameter block holds `fragmentProperties`
(numbers) or `fragmentSamplers` (a texture: `fileName`, `type = "TWOD"`, `wrapS`, `wrapT`, and
`redGreen = true` on normal maps).

Material types by use (6,806 materials):

| Type | Uses | Parameters |
|---|---|---|
| `PHYSICAL_NRML_MAP_OP` | 1,458 | map_albedo, map_metal_gloss_ao, map_normal, map_op_1, map_op_2, operation_1, operation_2 |
| `PHYSICAL_NRML_MAP_OP_UV1_AO_LIGHT` | 1,006 | + map_ao, map_id, map_lgt, window_light_color (buildings) |
| `PHYS_TRANSPARENT_NRML_MAP` | 674 | map_albedo_opacity, map_metal_gloss_ao, map_normal, alpha_test |
| `PHYSICAL_NRML_MAP` | 609 | map_albedo, map_metal_gloss_ao, map_normal |
| `PHYSICAL_NRML_MAP_LIGHT` | 582 | + map_id, map_lgt, window_light_color |
| `PHYS_TRANSPARENT_NRML_MAP_LIGHT` | 565 | |
| `PHYS_TRANSPARENT_NRML_MAP_CBLEND_DIRT` | 522 | + color_blend, dirt_rust, map_cblend_dirt_rust, map_dirt, map_rust and their normals |
| `PHYSICAL_NRML_MAP_CBLEND_DIRT` | 279 | the vehicle body material: as above with map_albedo |
| others | | `PHYS_TRANSPARENT_*_SMOOTH_LOD` (vegetation), `EMISSIVE`, `BILLBOARD2`, `LEAF_CARD`, `SKINNING_PHYS_*` (people, animals), `PHYSICAL`, `PHYS_TRANSPARENT_DIFFUSE` |

Every lit material has a `light_receiver` block, and the boxcar's has `isLegacyMaterial = true`: the engine
has a notion of a legacy material, which is worth following up for converted content. Optional blocks:
`two_sided`, `polygon_offset`, `alpha_test`, `alpha_scale`, `albedo_scale`, `normal_scale`, `tex_animation`,
`texcoord_scale`, `fade_out_range`.

Textures are `.dds`. A vehicle body has four: albedo (`_albo`), colour-blend / dirt / rust mask (`_cdr`),
metal / gloss / ambient occlusion (`_mga`), normal (`_nrm`).

### Animation (`.ani`)

`{ times = { 0, 100, ... }, transfs = { { 16 numbers }, ... } }`: one transform per time, in milliseconds.

## What the game already does for older content

### The Model Editor's Convert tool (official wiki, `modding:tools:modeleditor`)

Per the wiki: Convert migrates a Transport Fever 2 model to Transport Fever 3. It moves the files from the
`res` layout to the `content` layout ("the result depends on how consistent the old `res` folder structure
is"), adjusts the `.mtl` files and sets the legacy flag in them. It does **not** fully update the model's
metadata: "new values need to be added manually". It works on one model at a time in the editor's window; the
page documents no command line. Separate tools: Copy (a model into another mod), Validate (several models),
bulk import of `.fbx` from a list file. Nothing is said about Transport Fever 1 or Train Fever.

`isLegacyMaterial` (wiki, `modding:general:resourcetypes:mtl`): Transport Fever 2 used a slightly different
physically based standard; the flag makes the engine read a material's textures the old way. "true" only for
old TF2 textures. The editor also has an "Enable Legacy HDR Rendering" view option.

### Old metadata is upgraded at load (`base/base_mod.lua`, `base/model_metadata_util.lua`, build 40408)

The base game registers 29 `loadModel` modifiers that run on every model. Many exist only to turn the
older metadata shape into the current one. Read from the code:

| Old form | Becomes | Function |
|---|---|---|
| `transportVehicle.capacities`, `.loadConfigs`, `.compartmentsList`, or `compartments` as bare lists | `transportVehicle.compartments[].loadConfigs[]` | `toCompartmentList` |
| `cargoEntries` lists, cargo `type` | one `cargoEntry` with a `cargoTypeSet` | `makeCargoEntry`, `makeCargoTypeSet` |
| `roadVehicle` / `railVehicle` holding `engine(s)`, `topSpeed`, `weight`, `soundSet` | `landVehicle` (default brake 5 and friction 0.1 for road, 2.5 and 0.02 for rail) | `turnRoadAndRailToLandVehicle` |
| `landVehicle.weight` (tonnes) | `weightEmpty` (kg, x1000); air and water `weight`, `maxPayload` | `convertWeight` |
| `landVehicle.soundSet` (+ `horn`) | `soundConfig.soundSet` (+ `events.horn`) | `landVehicleSoundSetToSoundConfig` |
| `transportVehicle.seats`, `crewModels` | `seatProvider` with a driving licence by carrier; seat `animation` from `standing` | inline in `base_mod.lua` |
| mesh **indices** in vehicle configs (axles, bogies, lights) | node **names**; unnamed nodes get names | `replaceMeshIdWithNodeName`, `indexToNodeNameMap` |
| `configs = { ... }` per level of detail | one `config` | `squeezeConfigsToOneConfigForVehicles` |
| levels of detail in any order (`version == 1`) | sorted by `visibleTo`, fake bogies reordered to match | `sortLods` |
| no `transformatorConfig` (`version ~= 2`) | the default `.trf` for the vehicle kind | `addTransformatorConfig` |
| no `extent` | the bounding box | `addVehicleExtent` |
| old emission values | `emissions.noise` / `.pollution` | `convertLegacyEmission`, `addEmissionMetadata` |
| old particle system | the emitter list | `convertParticleSystem` |
| `categoryList` entries of the form `cargo#format` | `cargoModel` | `convertCargoModel` |
| `description.smallIcon` | `iconSmall` | `addIconMetadata` |
| missing cost, running cost, load speed, comfort, transport modes, filter tags | calculated or defaulted | `addCostMetadata`, `addMissingVehicleStats`, `addTransportVehicleTransportModes`, `addFilterTags`, `newLoadSpeedsAndMaintenanceFactor` |

`convertCargoType` is an empty hook in this build (it returns the type unchanged), so old cargo type names
are **not** mapped: a vehicle carrying a cargo TF3 does not have keeps a name that matches nothing.

The same file has "legacy handling" modifiers for street templates, streets, ground textures,
constructions, bridges, tunnels and railroad crossings.

**Settled 2026-10-12 (first in-game runs, then the decompiled check):** the engine accepts a model with a
version below 2 only in the *legacy location*. `ModelRep.cpp:101` asserts `legacyLocation || version >= 2`,
and `legacyLocation` is "the model's path below the mod's `content/` folder starts with `res/models/model/`"
(a prefix test on the file path; the executable holds the four prefixes `res/models/model/`,
`res/models/mesh/`, `res/models/animation/`, `res/models/material/`, and `res/textures/`). A version 1 model
at `content/vehicle/...` stops the game with that assertion; the same model at
`content/res/models/model/vehicle/...`, with meshes, materials and textures in the old places beside it and
the old flat material form, was registered by the game and could be found in the vehicle list. A `res`
folder at the mod's root is not looked at. So Transport Fever 3 reads the Transport Fever 2 layout itself,
one folder down.

**Earlier text, kept for the record:** whether the engine accepts a model file with `version = 1` or none. The scripts
plainly expect such models (`sortLods` and `addTransformatorConfig` branch on it), but every one of the
4,639 models in the mods installed here already says `version = 2`.

### What converted content looks like in practice (mods installed here)

- 1,110 materials across a dozen community mods carry `isLegacyMaterial = true`: ported TF2 content is
  common, and it uses the flag rather than repainted textures.
- Urban Games' own "legacy" vehicle mods (`ug_legacy_trams_1850`, `ug_legacy_road_1850`) are TF2 vehicles
  in the new layout, with `isLegacyMaterial = false` and TF2's texture names
  (`ivan_albedo_opacity.dds`, `ivan_metal_gloss_ao.dds`, `ivan_cblend_dirt_rust.dds`): reworked, not
  flag-converted. They show the target shape for a tram: `mat/tex/` relative to the `.mtl` (`tex/...`),
  shared lights and animations referenced from the base game with `::/vehicle/...`.
- A mod is `mod.json` (`modId`, `revision`, `severityAdd`, `severityRemove`, `cosmetic`), optional
  `strings.json` (language -> key -> text), `texture_metadata_cache.lua` (per texture: `channels`,
  `extent`, `numMipmaps`, `numStrippedMipmaps`; presumably written by the game or the editor), and
  `content/`.

## What is left for our converter

Transport Fever 2 -> 3 for one model is an official, supported path. Rebuilding it would be wasted work and
a second source of truth. What the official path does not give, and where a converter earns its place:

1. **Whole mods in one go.** Convert is one model at a time, by hand. A TF2 mod is dozens of models plus
   repaints, sounds, icons, strings and a `mod.lua`.
2. **The parts Convert leaves out:** the mod definition (`mod.lua` -> `mod.json`), texts (`strings.lua` ->
   `strings.json`), icons, sound sets, anything outside `res/models`, references the restructure breaks.
3. **Metadata the load-time upgrade cannot guess:** cargo types that no longer exist, load indicators as
   cargo bays, values the wiki says must be added by hand. A converter can write the upgraded metadata into
   the file as `version = 2` so the result does not depend on the legacy path staying in the game.
4. **Train Fever and Transport Fever 1 sources.** Nothing official. These need the older steps first
   (materials to the physical types, capacities, mesh indices), which is what the reference TF1 -> TF2
   converter does.
5. **A written report per mod:** what was converted, what was not, what needs a hand fix.

Where it runs was decided since: in the native layer, at launch, with rules written in Lua
(`design.md`).

## What became of the next steps

These notes were written before any old mod had been converted. What was open here was settled by doing
it, and is recorded in `design.md` (vehicles, lamps, text, materials, tracks, remasters) and `stations.md`
(station mods): a model older than version 2 is listed by the game but cannot be placed in the world, so
the converter writes version 2 in the newer game's own layout and does the load-time steps itself;
Transport Fever 1 and 2 mods both convert; and Transport Fever 2 has since been installed beside the newer
game, so rules can be checked against the older game's own files.
