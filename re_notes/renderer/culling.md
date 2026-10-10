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

## Next
1. Finish `NewUpdate`: identify what `renderer+0x110` / `0x1400e1520` produce (frustum planes vs cascades) and where
   the octree traversal (`Prepare2`) gets its query (radius? box? planes?).
2. `MaterialIndexManager::UpdateBox` (`0x14035c370`): what box, built from what camera data.
3. `tex_load::GetMipMapBaseLevel` (`0x142cb90c0`) and its caller chain: how the requested mip is derived (distance
   from camera? camera height?).
4. `LightingHelper::Update` (`0x1400c8d20`): light/shadow-caster gather region.
5. Design: one shared per-frame frustum (from the real view-projection), plus a light-space extension for shadow
   casters; swap it in at each selection point. Measure object/draw counts, frame time and memory, fix on vs off.
