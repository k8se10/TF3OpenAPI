#pragma once

// Placing objects in two steps, with rotation by the right mouse button.
//
// As the game ships, an object (a station, a depot, an asset) is built the moment it is clicked. For roads
// and track the game has an option - Settings > Advanced > "Enable Drag-and-Confirm Construction Mode" -
// that puts a step between laying out and building. This gives objects the same step, and only while that
// option of the game is on:
//
//   * the first click pins the object where it is; it no longer follows the mouse;
//   * while it is pinned, holding the right mouse button and moving the mouse turns it, in the game's own
//     steps of 10 degrees;
//   * a second click builds it; a right click without movement lets go of it again (it follows the mouse
//     as before).
//
// How: one hook, on the mouse handler of the game's object placement tool (UI::ConstructionBuilder). The
// tool itself is untouched: pinning is not passing mouse movement on to it, turning writes the tool's own
// rotation value and calls the tool's own "rotation changed" callback (which moves the rotation setting in
// the bottom bar), and building is the tool's own click, passed on at the second click.
//
// tf3api.ini [Placement] ConfirmObjects=1 (default 0 until seen working), and a script has to say that the
// game's option is on (tf3api.placementMode, see mod/tf3api_placement).

namespace tf3api::placement {

void Install();
void Uninstall();

// Whether the game's own drag-and-confirm option is on (told by script, which can read the game's settings).
void SetGameOption(bool on);
// Puts the filter on the game's input in (once): also used to keep a click on one of our clickable spots
// (road_labels) from the game, so that a departure board in front of a station is what gets clicked.
void EnsureInputFilter();
// The player's raise and lower keys by name (as the game's settings store them): a middle-button drag on a pinned
// object presses them. Returns false when SDL does not know the names.
bool SetHeightKeys(const char* raise, const char* lower);
// 0 = unavailable or off, 1 = on and nothing pinned, 2 = an object is pinned.
int State();

} // namespace tf3api::placement
