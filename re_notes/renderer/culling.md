# Culling / streaming / LOD — RE notes

**Build:** 40408 (development install). Addresses are build-specific; anything shipped must be signature-scanned.
**Goal (user, 2026-10-10):** replace the engine's radius/box-based "what's around the camera" selection with real
viewport-space (frustum) culling — "not radius based but based on is this in the viewport space". This is core
performance work (scope item 1), and also the fix for the cockpit-depth memory runaway.

## Why: the cockpit-depth runaway (measured, 2026-10-10)
With the cockpit eye allowed below world height -100 (`CockpitDepthFix=1`), private bytes went 9.6 GB → 18.5 GB in
~2.5 min until the system commit limit was exhausted. The in-DLL allocation profiler (`native/src/alloc_profiler.cpp`,
cumulative committed bytes per call stack, diffed between reports) shows three families growing during the ramp,
everything else flat:

| Family | Growth (03:34 → 03:36) | Code |
|---|---|---|
| Texture loading | 1.0 → 5.4 GB | `0x1403a3ff0` → `0x142cb4aa0` → `0x142cb4c90` → `0x142cbb7d0` → `0x142cb6670` (`tex_load.cpp` `LoadDDSTexture`) → `0x142cb90c0` (`tex_load::GetMipMapBaseLevel`) |
| Material boxes | 0.9 → 7.0 GB (two twin stacks) | worker job `0x14014a6e0` → `0x14035c370` (`MaterialIndexManager::UpdateBox`) → `0x14035b901` |
| Lighting / render queues | 1.8 → 7.0 GB | `0x1400c8d20` (`engine::LightingHelper::Update`) → `0x1402f93d0` (queues: `renderables`, `dynamicOpaque/Sorted/Transp`, `shadowDynamicOpaque/Transp`, `envMap`, `atmosphere`, `marker`) → `0x1406aeda0` (`CRendererComponent::DoRender`) |

Also seen active at OOM: the model mesh streamer (`ModelMeshManager::UpdateStreamingEnabled` `0x140808b70`, worker
loading mesh `.blob` files via `0x142bfd090`). User also observed broken shadows in the deep tunnel; the shadow-cascade
settings code (`0x140756400`) uses -100 as a world bound ("Extends terrain view towards light source").

Interpretation: these gathers select by camera position/height with an assumed world vertical range [-100, 6000]
(the same range the cockpit clamp enforces). Outside it, the selection stops being bounded.

## Renderer structure found so far
- `CRenderer::NewUpdate` — `0x1402ffc80` (~11.6 KB), per-frame update. Reads the render camera (`renderer+0x78`):
  eye at `cam+0x24..0x2c`, `cam+0x18`, `cam[0],[1],[4],[7],[8]` passed to `0x142bc76e0`. Builds a per-frame view
  context from the object at `renderer+0x110` via `0x1400e16f0` / `0x1400e1520` (fills a list sized to ≥4 entries —
  candidate: frustum planes or shadow cascades; to confirm) and `0x1401ebd60`. Also reads the water level.
- `CRenderer::Render` — `0x140303ff0` (~11.8 KB).
- `CRenderer::Prepare2(UI::OctreeSkipManager const&, RenderSettings const&)` — lambdas found via RTTI; octree
  traversal for visibility/LOD. `UI::OctreeSkipManager::GetLodRangeIndex` `0x1402da5f0` is bookkeeping (hash-map
  counts of LOD ranges), not the selection itself.
- `ecs::OctreeSystem` (`::Update` assert at `0x140ae4e70`) — the ECS spatial octree.
- Render camera object (`renderer+0x78`): `+0x10` FOV, `+0x24` eye, `+0x30` target, `+0x3c` up. Setters:
  `0x1403077c0` (eye/target), `0x1403078f0` (up), `0x1403078c0` (FOV).
- `0x1402fe040(boxes, cam)` — distance from the eye to the nearest of a set of AABBs (near-plane/fade helper; not a leak source).

## Findings, pass 2 (2026-10-10)
- `renderer+0x110` is the **shadow system**, not a view frustum: 5 cascade entries of 0x108 bytes (`+0x154` … `+0x5d4`),
  enumerated by `0x1400e1520`; `0x1400e16f0` returns one cascade (`+0x188`) depending on a mode flag at `+0x2c`.
  Relevant to the tunnel shadow bug (cascade fitting vs. a camera outside the assumed world range).
- `MaterialIndexManager::UpdateBox` (`0x14035c370`): reads a view/camera-like object at `this+0x160` (`+0x18` xy,
  `+0x28` z), builds a query with half-extents `4.0, 4.0` (`0x143677b5c`) and that z, and runs a spatial query
  (`0x140346470`) through a worker job (`0x14014a6e0`). Exact meaning of the 4.0 extents (tiles? metres?) still open.
- No engine-side frustum-plane set has been found yet in `NewUpdate`; the frustum for our culling will likely have to
  be built by us from the real view-projection (camera eye/target/up/FOV + near/far from `geometryQualityOptions`).

## Findings, pass 3 (2026-10-10) — the engine DOES frustum-cull; map of the selection points
- **Frustum planes exist**: render camera `cam+0x188..0x1e8` = 6 planes (Vec4) — copied by `CRenderer::Prepare2`
  (`0x140302a70`) together with 4 shadow-cascade plane sets. Box-vs-planes test: `0x142bc87a0(box[6 floats], planes)`.
- **Static models** — `CRenderer::NewUpdate::<lambda_4>` (`0x1402f30b0`), run as a parallel-for over world cells
  (`renderer+0xd8..0xe0`) by `0x1402da3b0`/`0x1402d9ac0`: per cell, frustum test vs camera planes; if outside, test vs
  each shadow-cascade frustum (keeps shadow casters); then eye→box distance vs max view distance (`ctx+0x50..0x5c`);
  then per-model LOD by distance (`visibleFrom/To`, scaled), producing `StaticLodRange` lists.
- **Instances / generators** — `<lambda_5>::<lambda_1>` `0x1402f0ab0` (model instances, `transf0`), `<lambda_6>`
  `0x1402f4c20` (`RenderModelInstance`, fat instances), `<lambda_8>` `0x1402f7590` (`ShapeModelInstance`, `lightSourceList`).
- **Model LOD → texture mips** — `Prepare2` walks the visible list `(renderer+0xa28)+0x1a0` (entries {modelId, lod, …,
  distance}) and calls `0x14080e650` per model: for each texture of that LOD, `requestedMip = 0x14254b810(bias,
  screenScale, distance, texLodBase) = log2(max(1, distance / (2^-bias · screenScale · …)))` → `TextureManager::Touch`
  (`0x142c514e0`, asserts requestedLod in [-200, 200]). `screenScale = 0x14254b7a0(cam)` from FOV and resolution.
  Distance-based only — whatever is in the visible list gets textures by distance.
- **Vegetation** — `terrain::RenderVegetation` `0x14049e830` (gets the camera frustum + cascades from `Prepare2`).
- **Terrain tiles** — `terrain::RenderDataManager::Update` `0x14037a9d0`: per tile, 3D box (tile min/max height from
  the grid) vs each view: eye→box distance ≤ `view+0x18` (range) ⇒ "in range"; frustum test `view+0x188` ⇒ "visible".
  Sane; a deeper eye selects fewer tiles, not more. Tessellation LOD: `UpdateLodTess` `0x14037d5d0`.
- **Terrain materials** — `terrain::MaterialIndexManager` (`BeginMaterialIndex(ViewTerrain*, Grid<TileData>,
  vector<CVec2i> tiles)`, `BeginBox`, `UpdateBoxAsync`, `UploadMaterialTex`, `GroundTextures`): per-tile terrain
  material textures for the tiles the terrain view needs. `UpdateBox` (`0x14035c370`) is job orchestration only.
- **Shadows** — `engine::ShadowMap` (`ShadowMap.cpp`): `Update` `0x1400e2100`, `UpdateFrustumCorners` `0x1400e2430`
  (cascade corners from the view's eye/dir/up/FOV and split distances — purely view-based, no world-height clipping),
  `PrepareLightView` `0x1400e1ab0` (light-space box per cascade, extended toward the light by a range). The -100 in
  `0x140756400` is only a debug-slider minimum (shadow tuning UI), not runtime logic.

## Correction: what the allocation profiler can and can't show
The profiler totals **commits** per call stack but does not subtract **frees**. Allocations over ~512 KB are committed
and released on every use, so a function that churns large per-frame buffers is indistinguishable from one that
leaks. The three "growing" families (lighting/render queues, terrain material boxes, texture loading) may be bigger
per-frame churn underground rather than the retained 9 GB. To attribute the real growth, the profiler must also hook
`NtFreeVirtualMemory` and keep outstanding (not cumulative) bytes per stack.

## Next
1. Finish `NewUpdate`: identify what `renderer+0x110` / `0x1400e1520` produce (frustum planes vs cascades) and where
   the octree traversal (`Prepare2`) gets its query (radius? box? planes?).
2. `MaterialIndexManager::UpdateBox` (`0x14035c370`): what box, built from what camera data.
3. `tex_load::GetMipMapBaseLevel` (`0x142cb90c0`) and its caller chain: how the requested mip is derived (distance
   from camera? camera height?).
4. `LightingHelper::Update` (`0x1400c8d20`): light/shadow-caster gather region.
5. Design: one shared per-frame frustum (from the real view-projection), plus a light-space extension for shadow
   casters; swap it in at each selection point. Measure object/draw counts, frame time and memory, fix on vs off.
