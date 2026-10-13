// Checks the station plan painter (native/src/plan_picture.cpp): a scene is read, and its parts come out where
// the view puts them, in their colours.
//
//   plan_picture_test.exe
#include "plan_picture.h"

#include <cstdio>
#include <vector>

int main() {
    int failed = 0;
    const char* text =
        "B -60.0 20.0 60.0 20.0 60.0 40.0 -60.0 40.0\n"
        "P -100.0 4.0 100.0 4.0 100.0 12.0 -100.0 12.0\n"
        "S -3.0 5.0 3.0 5.0 3.0 11.0 -3.0 11.0\n"
        "T 0 -120.0 0.0 0.0 0.0 120.0 0.0\n"
        "T 2 -100.0 -6.0 100.0 -6.0\n"
        "M 40.0 8.0 d 1\n"
        "M -40.0 8.0 a 0\n"
        "H 2\n"
        "nonsense line\n";
    tf3api::plan::Scene scene;
    if (!tf3api::plan::ParseScene(text, &scene) || scene.quads.size() != 3 || scene.tracks.size() != 2 || scene.markers.size() != 2 ||
        scene.served.size() != 1 || scene.x0 != -120.0 || scene.x1 != 120.0 || scene.y1 != 40.0) {
        printf("FAILED: reading the scene (%zu quads, %zu tracks, %zu markers)\n", scene.quads.size(), scene.tracks.size(), scene.markers.size());
        ++failed;
    }
    tf3api::plan::Scene nothing;
    if (tf3api::plan::ParseScene("", &nothing) || tf3api::plan::ParseScene(nullptr, &nothing)) {
        printf("FAILED: an empty scene counts as something\n");
        ++failed;
    }
    const int w = 480, h = 300;
    std::vector<uint8_t> picture;
    tf3api::plan::Render(scene, 0, 0, 0.5, false, nullptr, w, h, &picture);   // 0.5 m to a point: 240 x 150 m
    const auto at = [&](double x, double y) {   // metres -> the point's blue, green, red
        const int px = static_cast<int>(w / 2 + x / 0.5), py = static_cast<int>(h / 2 - y / 0.5);
        return picture.data() + (static_cast<size_t>(py) * w + px) * 4;
    };
    const auto is = [&](double x, double y, int r, int g, int b) {
        const uint8_t* p = at(x, y);
        return p[2] == r && p[1] == g && p[0] == b && p[3] == 255;
    };
    if (picture.size() != static_cast<size_t>(w) * h * 4 || !is(-110, -60, 24, 29, 37)) {
        printf("FAILED: the ground\n");
        ++failed;
    }
    if (!is(0, 30, 46, 52, 62) || !is(60, 8, 132, 130, 124) || !is(0, 8, 60, 205, 90)) {
        printf("FAILED: building, platform or the stairs' dot (building %d %d %d)\n", at(0, 30)[2], at(0, 30)[1], at(0, 30)[0]);
        ++failed;
    }
    // a track is ballast, sleepers and rails mixed at this size: not the ground's blue-grey; the track of a
    // platform the board serves is the warmer one
    const uint8_t* plain = at(50, 0.3);
    const uint8_t* served = at(50, -6.3);
    if (!(plain[2] > plain[0] && plain[2] > 40) || !(served[2] - served[0] > plain[2] - plain[0] + 10)) {
        printf("FAILED: the tracks (plain %d %d %d, served %d %d %d)\n", plain[2], plain[1], plain[0], served[2], served[1], served[0]);
        ++failed;
    }
    // the overview shows the boards and the main view's frame
    std::vector<uint8_t> overview;
    const double box[4] = {-50, 30, 50, -30};
    tf3api::plan::Render(scene, 0, 10, 1.0, true, box, 330, 206, &overview);
    const uint8_t* board = overview.data() + (static_cast<size_t>(206 / 2 - (8 - 10)) * 330 + (330 / 2 + 40)) * 4;
    if (!(board[2] > 200 && board[1] > 150 && board[0] < 80)) {
        printf("FAILED: the selected board on the overview (%d %d %d)\n", board[2], board[1], board[0]);
        ++failed;
    }
    std::vector<uint8_t> all;
    std::vector<size_t> offsets;
    tf3api::plan::Levels(picture, w, h, &all, &offsets);
    if (offsets.size() != 9 || all.size() <= picture.size() || all[0] != picture[0]) {
        printf("FAILED: the smaller levels (%zu)\n", offsets.size());
        ++failed;
    }
    printf("plan picture test: %s\n", failed == 0 ? "ALL OK" : "FAILED");
    return failed == 0 ? 0 : 1;
}
