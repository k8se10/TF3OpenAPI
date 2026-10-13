# Assets and the asset pipeline

**Status: in progress (first pass, 2026-10-13).** Build 40420, static analysis; names are the engine's own
(`local/assert_names_40420.tsv`). This pass maps the pipeline from names, asserted conditions and what earlier
work on the converter confirmed in the game (`re_notes/converter/`); the functions marked "to read" have
not been gone through yet.

## From a file on disk to something drawn

```
files                framework/filesystem
  mods and archives    CachedBaseFileSystem: AddArchive, AddModToFileCache, BuildModCache
                       DirectBaseFileSystem / DefaultBaseFileSystem: AddModDir, GetPhysicalPath
                       ModFilterBaseFileSystem: a view limited to the mods a save uses
  names                res_util::ParseResUri  ("<modId>::/path"; a bare "/path" inside a mod is the mod's own)
mods                 framework/mod
                       ModRep::RefreshModList, UpdateModDescs (mod.json), UpdateModSizes
resources            framework/res + Game/GameRes.cpp
                       ResTypeRep<T,int>::Add - one repository per kind (models, street types, cargo ...)
                       GameRes::Load 0x14013b5f0 (8 KB) - loads every repository for a game
                       resource::Fixer (game_res_util.cpp) - mends references of a save to resources
                       that are gone: Fixer::Model, GetPlaceholderModelAssetName
models               Lib/model + Lib/model/io
                       Importer::SearchAndImportAllModels 0x142bf4030 (10 KB), ImportModel 0x142bf2530
                       RemoveModelWithFailedResources, ThrowMissingFilesException
                       ModelRep (ImportAllModelAssetsV2, GetModelId)
                       serialization_util: ReadMesh, ReadGroup, ReadProperty, ReadModelMetadata2/3,
                                           ReadModelBoundingInfo, ValidateColliderBox/Cylinder
                       Model::Model (lods must be in order of visibleTo - asserted), GetNodeIndex
                       model_util: CalcBoundingBox, CreateModelBoundingInfo, CreateTangentVertexAttr
                       MeshConstructor, Mesh::CreateVertexAttr, MeshGroup::CreateIndices
materials            Lib/model: Material::GetProperty, model::MakeFields, model::GetRenderPassData
                       (material types are data: .prop / .tec / .prog files)
constructions        Lib/model_construction
                       ConstructionRep::LoadFunctions (the script functions of a construction),
                       Converter<ConstructionTemplate>, modules_util (Tag2SlotId, auto-fill slots)
textures             Lib/renderer + framework/renderer
                       tex_load: LoadDDSTexture 0x142cbd010 (7 KB), LoadTGATexture, LoadPNGTexture,
                                 GetMipMapBaseLevel, LoadTextureAsync, ResolveWithSuffix
                       tex_load_util: Get{DDS,TGA,PNG}TextureMetadata (the texture_metadata_cache)
                       TextureManager: IncrRef / RemoveRef, Touch (requested level of detail),
                                       StartStreaming (its own thread), Step, FinalizeTextureLod
                       VramBudgetManager: GetConfigFromSettings, Step (main thread only - asserted)
on the graphics card Lib/renderer/model
                       MeshVBOManager: EnsureAdded, MeasureSizeToUpload, Create, Remove
                       ModelDescriptorManager, MaterialUboManager, VaoManager, StandardTechnique
in the world         ecs::ModelInstanceListSystem (counts instances per model id), transformators
                       (Game/model: RoadVehicle, RailVehicle, Tram, Ship, Aircraft, Bridge, TownBuilding)
checking and packing Game/mod_validator: ModValidator::Validate, ValidateGameRes,
                       cooking::CookFullMod, CreateStrippingContext; framework/cooking/handlers/MipMapHandler
```

## What is established

- **Model import** (confirmed in the game during converter work): a model whose file fails to load is
  skipped ("Skipped loading model", `ModelRep.cpp`); a model that names a mesh, material, texture or
  animation that does not exist is removed after import with a warning that lists the missing files
  (`RemoveModelWithFailedResources`). A model's metadata is first passed through the base game's Lua
  modifiers (29 of them); a Lua error there also skips the model.
- **Model location and version** (`ImportAllModelAssetsV2`, asserted): `legacyLocation || version >= 2`
  - a model below `res/models/model/` is "legacy"; anything else must be version 2.
- **Levels of detail** must be in ascending order of `visibleTo` (`Model::Model`, asserted).
- **Node names per level of detail** are kept in a map (`m_lodIndex2NodeName2NodeIndex`); metadata that
  names a part (axles, wheels, labels, lights) is resolved against it per level.
- **Textures are streamed**: each texture has a requested level set by `Touch`, a streaming thread
  (`StartStreaming`) that loads mip levels from `mipmapBaseLevel` upward, and a budget
  (`VramBudgetManager`). A texture without mip levels cannot take part (the game's log says so). The
  earlier memory-growth finding (`re_notes/camera/camera_pipeline.md`) is this part of the code.
- **A save refers to resources by name** (`io::Serializer<ResName>`), and `resource::Fixer` replaces what
  is missing with placeholders on load - which is why removing a mod leaves a save loadable.

## To read next

1. `Importer::SearchAndImportAllModels` and `ImportModel`: the order of work, what runs in parallel, what
   a model costs at load. (Old-mod conversion adds hundreds of models; load time is the first cost.)
2. `serialization_util::ReadMesh` / `ReadGroup`: the mesh and blob format from the reader's side, to check
   the converter's writer against it.
3. `TextureManager::StartStreaming` and `Touch`: how the wanted level is decided from the camera, and what
   holds memory - the open question behind the cockpit memory growth.
4. `MeshVBOManager::EnsureAdded`: when mesh data goes to the graphics card and whether it is ever released.
5. `ConstructionRep::LoadFunctions` and the proposal code: from a construction script's result to
   entities - needed for left-hand traffic's "act on the finished result".
6. `cooking::CookFullMod`: what the game itself does to a mod before publishing (stripping, mip levels) -
   a model for what the converter should write, including compressed textures.
