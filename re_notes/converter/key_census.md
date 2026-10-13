# What of an old mod the newer game does not know: the key census

2026-10-13, build 40420. The converter's aim is that any old mod converts. That needs to be measurable, so
`tools/key_census.py` reads every model or material file of the older game and of old mods as a Lua table
(without running it), takes every key with its path, and asks of each: do the newer game's own files use
it; is it named in the newer game's load-time scripts (which upgrade old metadata), in its executable, or
in the converter's rules? What is named nowhere is what a conversion would lose. Rerun it with any new
old mod in the "old" list to see what of that mod is not covered:

    python -I tools/key_census.py --kind mdl --old <older game's model.zip> <legacy_mods> \
        --new <newer game's content folders> --new-exe <TransportFever3.exe> \
        --new-scripts <base.zip> <scripts.zip> --converter converter/convert.lua --out census.md

## Models (4,837 old files: every model of Transport Fever 2 and of the old mods at hand)

389 distinct key paths. 139 are used the same by the newer game's own models, 192 are named in its
load-time scripts, 50 in its executable, 1 only in the converter. **Seven are named nowhere:**

| Key | Files | What it is | State |
| --- | --- | --- | --- |
| `metadata.roadVehicle.configs[].headLights` | 416 | parts of a road vehicle shown when its lights are on | not converted: the parts are always shown |
| `metadata.cameraConfig.positions[].noTransf` | 278 | a flag on a cockpit camera position | carried over as it is; meaning to be read |
| `metadata.airVehicle.maxTakeOffWeight` | 30 | an aircraft's weight limit | not converted (the newer game has `maxPayload`) |
| `metadata.labelList.labels[].alphaTest` | 10 | a label's cut-off | not converted (labels are blended in the newer game) |
| `metadata.vehicleDepot` | 7 | a depot described on a model | the older form of depots; depots are not converted yet |
| `metadata.terrainAlignmentProvider` | 2 | terrain shaping described on a model | not converted |
| `lods[].children[].id` | 1 | the Train Fever form of a level of detail | converted (the old-form path) |

**Values** the old files use that the newer game does not know:

| Value | Files | State |
| --- | --- | --- |
| events `doors_open`, `doors_close` | 438 | converted to `open_all_doors` / `close_all_doors` |
| events `open_door_left`, `open_door_right` (a slip for `open_doors_...`) | 5 | converted to that side's event |
| cargo `LOGS`, `IRON_ORE` | 63 | converted by the cargo table (`C.cargoTypes`) |
| label type `LINE_DESTINATION` | 2 | converted to `NEXT_STOP` |
| events of people and animals (`walk`, `idle`, `driving`, `sitting`, ...) and of industries (`productionHalf`, `productionFull`, `pump`) | about 150 | not vehicle or asset content; left as they are |

## Materials (the older game's 9,395 materials and those of the old mods)

210 distinct key paths; all but four are used by the newer game's materials or named in its property
definitions. The four: `ambient_occlusion_scale` (2 files) and `alpha_test.preferAlphaToCoverage`
(2 files), which the newer game has no property for; `map_logo`, which it has (as a property file).

**Every one of the older game's 25 material kinds exists in the newer game** (it defines 51; the kind's
name is the name of a `.mat.lua` file under `rendering`), `PHYSICAL_NRML_MAP_OP_UV1_AO` - the kind of
5,890 of the older game's building materials - included. A material's parameters are the 47 properties of
`rendering/properties.zip`.

## What this does not measure

- Keys an old mod computes in a script instead of writing out (constructions, modules, sound sets, mod
  scripts): those are code and are converted by running them (`re_notes/converter/stations.md`).
- Whether a key that both games know means the same in both. That is what the comparison of the two
  executables is for: the older game's assertions give full function signatures
  (the list made from the older game, see `re_notes/engine/README.md`), the newer game's give names, and the same reader can be laid
  side by side in both.
- Files of other kinds: meshes and animations (binary data described by a small table), street and track
  types, bridges, tunnels, cargo and economy definitions. The census can read any of them (`--kind`);
  only models and materials have been counted so far.
