# TF3 asset formats: what a converted mod has to produce

First pass for the TF1 / TF2 -> TF3 asset converter. Everything under "What the game's own files show" was
read from the game's content archives on build 40408 (4,473 models, 6,806 materials, by script). Nothing in
this note has been tried in the game, and no Train Fever, Transport Fever 1 or Transport Fever 2 mod has been
examined yet: the section on what has to change is a hypothesis to check against real source mods.

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

## What this suggests for conversion (to be checked against real source mods)

The names and shapes above are familiar from Transport Fever 2's mod format: the material type names, the
split-index mesh with a blob, `compartments` with `loadConfigs`, `transformatorConfig`, `FILE_REF`
animations. So the working assumption is that a TF2 asset needs translating rather than rebuilding, and the
questions are where TF3 differs:

1. **Folder layout.** TF2 mods keep models, meshes, materials and textures in separate trees under `res/`;
   TF3 keeps one folder per asset with relative paths. Every reference inside a model has to be rewritten.
2. **Model version and metadata.** All TF3 models are `version = 2` with the key set in the tables above.
   What a TF2 model has that TF3 lacks or renames is not known until a TF2 model is laid beside these.
3. **Load indicators** exist in TF3 as cargo bays; a converter can keep cargo display where the reference
   converter had to drop it.
4. **Materials.** Whether a TF2 material file loads as it is, and what `isLegacyMaterial` does, decides how
   much material rewriting is needed.
5. **Meshes.** If the blob layout is the same as TF2's, meshes can be copied byte for byte. TF1 and Train
   Fever meshes are a separate question.
6. **Animations.** TF3 has only file references: inline animations in a source model have to be written out
   as `.ani` files.
7. **Texts.** TF3 descriptions are translation keys; a source mod's literal names need a strings file.

## Next steps

1. Get one Transport Fever 2 mod and one Transport Fever 1 or Train Fever mod (a simple wagon each) from
   the user, and lay their `.mdl`, `.mtl` and `.msh` beside the TF3 boxcar's, field by field.
2. Read the official modding pages on models, materials and the model editor for anything the files do not
   show, and check whether Urban Games already provide an import path for older assets.
3. Hand-convert one wagon and load it in the game. Only then design the converter.
