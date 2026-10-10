#pragma once

// Shadow map resolution control.
//
// The engine sizes its cascaded shadow maps from the screen, not from a quality table: it takes 1.5x the
// larger viewport dimension, rounds up to a power of two, multiplies by the shadow-quality factor, applies
// an optional maximum held in the shadow map object (unused by the game: 0), and finally clamps to 4096.
// At 2560x1440 on High that is 4096x4096 per cascade pass. RE trail: re_notes/renderer/shadows.md.
//
// This module hooks that sizing function and fills in the engine's own maximum-size field, so the game
// itself allocates and renders smaller shadow maps. Everything else about shadows (cascades, filtering,
// quality setting) is left as the game set it. Rendering only.
//
// tf3opt.ini [Shadows]:
//   MaxResolution=0    largest shadow map edge in pixels (e.g. 2048, 1024, 768). 0 = vanilla.
//   ToggleKey=0        virtual-key code that switches the limit off/on while playing, for A/B comparison
//                      (118 = F7, 0 = none). The game re-creates the shadow maps on the next frame.

namespace tf3opt::shadow_tuning {

// Requires MinHook to be initialised.
void Install();
void Uninstall();

} // namespace tf3opt::shadow_tuning
