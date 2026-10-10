#pragma once

// Terrain occlusion culling.
//
// The engine frustum-culls world cells, model instances, buildings, grass, vegetation and terrain tiles
// against the camera's six planes, but has no occlusion culling: everything inside the view cone is
// processed even when a hill - or the ground itself, from inside a tunnel - hides it.
//
// Each frame (hook on CRenderer::NewUpdate) this module rasterizes the terrain surface around the camera
// into a small software depth buffer (Intel Masked Occlusion Culling). A hook on the engine's own
// box-vs-frustum test then rejects boxes that pass the camera frustum but are completely hidden behind
// that terrain. Only calls that test against the camera's planes, from an allow-list of scene-rendering
// callers, are affected; shadow-cascade tests and every other caller behave exactly as vanilla.
//
// Rendering only: nothing here touches simulation state. RE trail: re_notes/renderer/culling.md.
//
// tf3opt.ini [Occlusion]:
//   Enabled=0            master switch (default off until measured and verified in-game)
//   TerrainMargin=15     metres the occluder terrain is lowered (tunnel portals have no hole in the heightmap)
//   MinDistance=30       terrain closer than this to the eye is not used as an occluder (metres)
//   GridSpacing=80       occluder terrain sample spacing (metres)
//   GridCells=96         occluder grid size in cells per side (coverage = GridCells * GridSpacing)
//   ToggleKey=121        virtual-key code that toggles culling at runtime for A/B checks (121 = F10, 0 = none)
//   BenchKey=120         virtual-key code that runs the built-in A/B benchmark (120 = F9, 0 = none): 8 phases
//                        of 5 s alternating culling off/on; frame time per phase and overall in tf3opt.log
//   LogStats=1           log tests / culled / build time every 10 s
//   SelfTest=0           1 = run a synthetic-terrain self-test at startup and log the result (refuses to
//                        install if it fails)

namespace tf3opt::occlusion {

// Requires MinHook to be initialised.
void Install();
void Uninstall();

} // namespace tf3opt::occlusion
