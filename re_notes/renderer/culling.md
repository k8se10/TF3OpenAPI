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

## Occlusion culling — design decided (user: "yes", CPU approach), 2026-10-10
- Library: Intel Masked Occlusion Culling (Apache-2.0), vendored at `native/third_party/moc/` (AVX2/AVX512 files need
  `/arch:AVX2`; runtime CPU dispatch). Clip space input (x right, y up, w = forward distance); we transform vertices
  ourselves (modelToClip = nullptr, layout stride 16 / y 4 / w 12).
- Only the eye position matters for occlusion correctness; our own camera from render camera `cam+0x24` eye, `+0x30`
  target, `+0x3c` up, `+0x10` FOV (radians, full angle), slightly widened. Out-of-buffer boxes ⇒ treat as visible.
- Hook points (unique signatures, build 40408):
  - `CRenderer::NewUpdate` `0x1402ffc80`: `48 89 5C 24 10 48 89 74 24 18 57 41 54 41 55 41 56 41 57 B8 80 14 00 00`
    (renderer = arg0; render camera = `*(renderer+0x78)`) — rebuild the occlusion buffer at entry (triple-buffered).
  - Frustum test `0x142bc87a0`: `48 83 EC 18 33 C0 C5 F8 29 34 24 48 83 C2 08 C5 E0 57 DB` (box `[min xyz, max xyz]`,
    planes ptr). Only when planes == `cam+0x188` (not cascades) and the original returns true: TestRect ⇒ cull if OCCLUDED.
  - Terrain height `0x140388660(terrain, &vec2) -> float`. Terrain pointer: inside NewUpdate the code uses
    `*(ctx+0x10)` where ctx = a stack-held object (`&stack+0x330`) — still to resolve to a stable path from the
    renderer (open item). Water level `0x140388d30(terrain)`.
- Safety: terrain occluder lowered by ~15 m (tunnel portals have no heightmap hole), skipped within ~30 m of the eye,
  disabled in underground view mode, config toggle + debug hotkey, stats logging.
- Open: stable terrain pointer path; underground-view-mode flag; then implementation (`native/src/occlusion.*`).

## Occlusion culling — implemented (2026-10-10), awaiting live test
`native/src/occlusion.{h,cpp}`; `tf3api.ini [Occlusion]` (default off in code; on in the development install for testing).
- **Resolved RE items:** terrain = `*(*(*(renderer+0x10)+0x1e0)+0x10)`; the height function clamps to the map bounds
  and tolerates NaN (`0x140494b10`), so sampling outside the map is safe. `NewUpdate` takes >4 args (5th on the stack);
  the hook forwards 8 register-width args.
- **Frustum-test callers (24 total).** Occlusion applies only to an allow-list resolved by signature and matched by
  return address: static models (`NewUpdate::<lambda_4>` `0x1402f30b0`), model instances (`<lambda_6>` `0x1402f4c20`,
  `0x1402f5ea0`), grass (`0x14033e2f0`), vegetation (`0x14049e830`), buildings (`BuildingRenderable` `0x1407c4410`),
  terrain tiles (`0x14037a9d0`). Unidentified callers (`0x1402f015b`, `0x1402f01c3`, `0x1402f06a0`, `0x1407db230`,
  `0x1407dd9fb`, `0x1407f3890`, `0x140844c10`, `0x1408e5f30`, `0x141048e50`, `0x1428a08d0`, `0x142c55055`) keep
  vanilla behaviour. Shadow-cascade tests are never touched (planes pointer != `cam+0x188`).
- **Per frame** (hook on `NewUpdate`, main thread): scrolling terrain height cache (grid 96x96 cells @ 80 m, new strips
  only + one refresh row per frame), lowered by `TerrainMargin`, cells within `MinDistance` of the eye skipped,
  rasterized double-sided into a 384x216 Masked Occlusion Culling buffer; 4-buffer ring published atomically.
- **Per box:** stage 1 `TestRect` at the nearest depth; stage 2 `TestTriangles` on the box's 12 faces (needed for
  grazing occluders — the ground seen from inside a tunnel). Boxes touching the near plane are kept.
- **View coverage check:** each frame the game's own frustum planes are used to verify our buffer's field of view
  contains the game's (four corner directions inside our NDC). Only then may a box sticking out of the buffer be
  judged on its in-buffer part; otherwise such boxes are kept.
- **Self-test** (`SelfTest=1`, runs without the game): synthetic ridge + underground cases, 10/10 pass in the harness
  (`dlltest`), including "house/city block on the surface culled from below" and "train/station in the tunnel kept".
- **Known limits / to verify live:** only terrain occludes (no building occluders yet); far objects near the horizon
  from underground are not culled (buffer resolution at grazing angles); world-cell boxes that dip below the lowered
  terrain count as visible; the underground overlay view is not special-cased (user decision) — use the toggle key if
  outlines disappear; buffer build runs on the main thread (cost is logged; move to a worker if it matters).
- **Not yet measured in-game.** Needs: `occlusion: active` + stats lines in `tf3api.log`, FPS with the toggle key
  on/off in a tunnel and at the surface, visual check for pop-in or missing objects/shadows.

### First live run (2026-10-10): hooks did not install — fixed
`occlusion: hook install failed (8)` = `MH_ERROR_UNSUPPORTED_FUNCTION` on the frustum test. Cause: MinHook's
trampoline loop decodes one instruction past the bytes it copies, and its disassembler (HDE64) cannot decode VEX/AVX
instructions; the frustum test's third instruction is `vmovaps [rsp], xmm6`. The game is compiled with AVX throughout,
so this affects many hook targets. Fix (local change in `native/third_party/minhook/src/trampoline.c`, commented in
place): a decode failure is only fatal while fewer than 5 bytes have been copied. Verified outside the game: a copy of
the real function bytes (0x9a bytes, position-independent) hooked with the patched MinHook returns identical results
through the hook (inside box 1, outside box 0, straddling box 1) — which also confirms the plane convention
(inside is `n.p + d <= 0`). **Limit that remains:** a target whose first 5 bytes themselves contain a VEX instruction
still cannot be hooked with MinHook.
