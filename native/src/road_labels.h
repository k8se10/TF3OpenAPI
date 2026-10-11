#pragma once

#include <cstddef>

// Road names drawn in the world.
//
// The road-names script mod groups the map's street segments into named roads and hands the result to this
// module through the bridge (tf3api.setRoadLabels). Each frame the module projects the segments with the
// game's render camera and draws each road's number shield and name along the road, through the overlay
// renderer. Which text a road shows (number and name, number only, name only) is decided by the script: it
// simply leaves out what should not be shown.
//
// Names are shown from a distance and hidden close up: zoom runs from 0 % (camera at MaxHeight above the
// ground or higher) to 100 % (at MinHeight or lower) on a logarithmic scale, and names are hidden beyond
// kHideAboveZoomPercent. The cockpit view sits a few metres above the ground, so the same rule hides them
// there.
//
// Clicking a shield or a name (press and release the left button on it without dragging) is reported to
// scripts through TakeClick / tf3api.takeRoadClick. The click is not taken away from the game: whatever is
// under the label is clicked as well.
//
// Needs the overlay ([Overlay]) and the frame hook of the occlusion module ([Occlusion] Enabled=1) for the
// camera. Draws over the finished frame: names are not hidden by buildings or hills in front of them.
//
// Text format for SetData, one record per line:
//   S <tab> shield <tab> class <tab> number <tab> name <tab> id <tab> flags
//                                                          starts a road; shield is M, A, B, X (a grey
//                                                          badge, e.g. "Abandoned") or -; id is the script's
//                                                          own number for the road and flags a short string
//                                                          of its own that comes back with a click (both
//                                                          optional)
//   G x0 y0 z0 x1 y1 z1                                    one segment of the road started last (metres)
//
// tf3api.ini [RoadNames]:
//   Enabled=1        0 = never draw road names
//   MinHeight=10     camera height above ground that counts as fully zoomed in (metres)
//   MaxHeight=6000   camera height that counts as fully zoomed out (metres)
//   LogStats=1       log camera height, zoom and label counts every 10 s while names are being drawn

namespace tf3api::road_labels {

// Names are hidden when the view is zoomed in further than this (0 = fully out, 100 = fully in).
constexpr float kHideAboveZoomPercent = 70.0f;

// Replaces the roads to draw. Returns the number of roads read (0 clears the names).
// May be called from any thread.
int SetData(const char* text, size_t length);

// The road whose label was clicked since the last call, if any. May be called from any thread.
struct Click {
    int id = 0;
    char name[68] = {};
    char ref[68] = {};
    int cls = 1;
    float length = 0;  // metres
    int segments = 0;
    char flags[12] = {};  // as the script sent them
};
bool TakeClick(Click* out);

// Requires the overlay to be installed.
void Install();
void Uninstall();

} // namespace tf3api::road_labels
