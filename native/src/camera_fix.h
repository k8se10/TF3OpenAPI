#pragma once

// Cockpit camera depth fix.
//
// The cockpit / follow camera (UI::FollowAction) converts its camera state into a final eye position in
// one function (build 40408: 0x1405326d0), which ends with an absolute world-height clamp:
//     eyeZ = clamp(eyeZ, -100.0, 6000.0)
// Vanilla lets players build tunnels deeper than -100, so the cockpit view jumps up to -100 and shows the
// world from above. The fix removes only the -100 floor (one conditional jump -> two NOPs); the 6000
// ceiling and everything else stay vanilla. Full RE trail: re_notes/camera/camera_pipeline.md.

namespace tf3api::camera_fix {

void Install();
void Uninstall();

} // namespace tf3api::camera_fix
