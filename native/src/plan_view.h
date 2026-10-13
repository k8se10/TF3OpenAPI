#pragma once

// A view from straight above in the game's small live views.
//
// The game's entity windows show a small live picture of the thing they are about
// (builtin.EntityRendererComponent in its interface scripts). For a thing without camera positions of its
// own - a building, a station - that picture slowly circles it from an angle: one function
// (build 40420: 0x1405329c0) works out, every step, where the camera stands and where it looks.
//
// For entities a script has named, this puts the camera straight above a given point instead, looking down,
// with a given direction pointing up the picture. Because the script chooses the camera, it knows how the
// ground maps onto the picture and can lay a diagram of its own over it (the departure boards' station plan).
//
// tf3api.ini [Boards] PlanView=1 (default 0 until it has been seen working).

namespace tf3api::plan_view {

void Install();
void Uninstall();

// Whether the hook is in.
bool Available();
// From now on the live view of `entity` looks straight down at (x, y, z) from `height` above it, with the
// direction (upX, upY) pointing up the picture. Returns false when there is no room left (8 entities).
bool Set(int entity, float x, float y, float z, float height, float upX, float upY);
// The live view of `entity` is the game's own again.
void Clear(int entity);

} // namespace tf3api::plan_view
