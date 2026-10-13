#pragma once

#include <cstdint>
#include <vector>

// The station plan in a departure board's window: a drawing of a station from above, made from a scene the
// boards' script describes, and painted by the boards module into a texture of the window (see boards.h,
// SetPlanScene / SetPlanView).
//
// Scene text, one item per line, in the station's own frame (metres; x along the tracks, y across them):
//   P x0 y0 x1 y1 x2 y2 x3 y3      a platform (four corners)
//   B ...                          a building
//   S ...                          stairs or an underpass (a way on to a platform)
//   T n x y x y ...                a track; n = the platform number it is, 0 for none
//   M x y d|a 0|1                  a board (departures / arrivals; selected)
//   H n n ...                      platforms the selected board serves (their tracks glow)

namespace tf3api::plan {

struct Quad {
    char kind = 'B';
    double x[4] = {}, y[4] = {};
};
struct Track {
    int platform = 0;
    std::vector<double> x, y;
};
struct Marker {
    double x = 0, y = 0;
    bool arrivals = false, selected = false;
};
struct Scene {
    std::vector<Quad> quads;
    std::vector<Track> tracks;
    std::vector<Marker> markers;
    std::vector<int> served;
    double x0 = 0, y0 = 0, x1 = 0, y1 = 0;   // bounds of everything in it
};

// false when the text holds nothing to draw
bool ParseScene(const char* text, Scene* scene);
// The scene seen from above, (cx, cy) in the middle, metresPerPoint metres to a point of the picture: width x
// height points of blue, green, red, opacity. The overview also draws the boards and, when viewBox (x0, y0,
// x1, y1 in metres) is given, the part the main plan shows.
void Render(const Scene& scene, double cx, double cy, double metresPerPoint, bool overview, const double* viewBox, int width, int height,
            std::vector<uint8_t>* bgra);
// that picture followed by every smaller level, each half the size
void Levels(const std::vector<uint8_t>& top, int width, int height, std::vector<uint8_t>* all, std::vector<size_t>* offsets);

}  // namespace tf3api::plan
