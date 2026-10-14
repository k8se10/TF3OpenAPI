#pragma once

// Night lighting: lights per screen bucket.
//
// The game lights the scene through a grid of screen buckets (32 x 32 across, 24 slices into the distance) and
// gives each bucket at most 64 lights (CRenderer's constructor, build 40420: 0x1402e6560, the field at +0xa4;
// filled by the light-list job 0x14030c3e0, which skips a light for a bucket that already has the maximum).
// Seen from above at night over a town, a bucket covers more street lamps than that, and the skipped lamps'
// glow stops at the bucket's edge: dark rectangles that move with the screen. This raises the cap. Full trail:
// re_notes/renderer/lighting.md.

namespace tf3api::lighting_fix {

void Install();
void Uninstall();

} // namespace tf3api::lighting_fix
