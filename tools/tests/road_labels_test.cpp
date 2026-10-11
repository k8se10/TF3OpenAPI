// Offline test for native/src/road_labels.cpp: stubs the overlay, the camera and the config, feeds the module
// a small road set and checks what it draws and where.
//
// Build (from a Visual Studio x64 prompt):
//   cl /nologo /EHsc /O2 /std:c++20 /I native\src tools\tests\road_labels_test.cpp native\src\road_labels.cpp
#include "config.h"
#include "log.h"
#include "occlusion.h"
#include "overlay.h"
#include "road_labels.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Drawn {
    std::string text;
    float x, y, angle;
    bool rotated;
};
std::vector<Drawn> g_drawn;
int g_rects = 0;
tf3api::overlay::FrameCallback g_callback = nullptr;
tf3api::occlusion::CameraView g_camera;
int g_failures = 0;

void Check(bool ok, const char* what) {
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) ++g_failures;
}

} // namespace

namespace tf3api::log {
void Write(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::printf("  log: ");
    std::vprintf(fmt, args);
    std::printf("\n");
    va_end(args);
}
} // namespace tf3api::log

namespace tf3api::config {
bool GetBool(const char*, const char*, bool defaultValue) { return defaultValue; }
int GetInt(const char*, const char*, int defaultValue) { return defaultValue; }
float GetFloat(const char*, const char*, float defaultValue) { return defaultValue; }
} // namespace tf3api::config

namespace tf3api::overlay {
void Rect(float, float, float, float, uint32_t) { ++g_rects; }
float TextWidth(float size, const char* text) { return size * 0.5f * static_cast<float>(std::strlen(text)); }
float Text(float x, float y, float size, uint32_t, const char* text) {
    g_drawn.push_back({text, x, y, 0.0f, false});
    return TextWidth(size, text);
}
void TextRotated(float x, float y, float, float angle, uint32_t, const char* text) { g_drawn.push_back({text, x, y, angle, true}); }
void SetFrameCallback(FrameCallback callback) { g_callback = callback; }
} // namespace tf3api::overlay

namespace tf3api::occlusion {
bool LatestCamera(CameraView* out) {
    *out = g_camera;
    return true;
}
} // namespace tf3api::occlusion

#include <windows.h>

namespace {

// A camera `height` metres above the origin looking straight down, with north (+y) at the top of the screen.
// The frustum planes are built the way the engine stores them: outward normals, inside is n.p + d <= 0.
void LookDown(float height, float fovY, float aspect) {
    g_camera = {};
    g_camera.eye[2] = height;
    g_camera.up[1] = 1.0f;  // target stays at the origin
    g_camera.fov = 0.3f;    // deliberately not the real angle: the planes must be what is used
    g_camera.viewW = 1920;
    g_camera.viewH = 1080;
    g_camera.heightAboveTerrain = height;
    g_camera.haveHeight = true;
    g_camera.tick = GetTickCount64();
    const float halfY = fovY * 0.5f, halfX = std::atan(std::tan(halfY) * aspect);
    // forward = -z, right = +x, up = +y
    const float planes[6][3] = {
        {std::cos(halfX), 0, std::sin(halfX)},   // right:  cos*right - sin*forward
        {-std::cos(halfX), 0, std::sin(halfX)},  // left
        {0, std::cos(halfY), std::sin(halfY)},   // top
        {0, -std::cos(halfY), std::sin(halfY)},  // bottom
        {0, 0, 1},                               // near (behind the eye is outside)
        {0, 0, -1},                              // far
    };
    for (int i = 0; i < 6; ++i) {
        for (int k = 0; k < 3; ++k) g_camera.planes[i * 4 + k] = planes[i][k];
        g_camera.planes[i * 4 + 3] = -planes[i][2] * height;  // all side planes pass through the eye
    }
}

const Drawn* Find(const char* text, bool rotated) {
    for (const Drawn& d : g_drawn) {
        if (d.text == text && d.rotated == rotated) return &d;
    }
    return nullptr;
}

} // namespace

int main() {
    using namespace tf3api;
    road_labels::Install();
    Check(g_callback != nullptr, "the module registers its frame callback");

    // an A road running east-west through the origin and a motorway 300 m to the north, plus junk lines
    const std::string text =
        "S\tA\t2\tA2\tFarley Road\n"
        "G -200.0 0.0 0.0 -100.0 0.0 0.0\n"
        "G -100.0 0.0 0.0 100.0 0.0 0.0\n"
        "G 100.0 0.0 0.0 300.0 0.0 0.0\n"
        "S\tM\t3\tM3\t\n"
        "G -300.0 300.0 0.0 300.0 300.0 0.0\n"
        "S\t-\t1\t\tElm Close\n"
        "G 0.0 -200.0 0.0 0.0 -150.0 0.0\n"
        // a slip road: a tight loop of 50 m radius in three pieces of about 53 m, to the south-east. Each
        // piece is long enough to carry the name by the length rule, but the text would run off the bend.
        "S\tM\t3\tM7\tLoop Slip Road\n"
        "G 400.0 -300.0 0.0 444.9 -328.1 0.0\n"
        "G 444.9 -328.1 0.0 439.4 -380.8 0.0\n"
        "G 439.4 -380.8 0.0 389.6 -398.9 0.0\n"
        "S\t-\t1\t\t\n"
        "G 0 0 0 1 1 1\n"
        "G not numbers\n"
        "nonsense\n";
    Check(road_labels::SetData(text.data(), text.size()) == 4, "four roads read; the nameless one and the junk are dropped");

    const float width = 1920, height = 1080, fovY = 1.0f;
    LookDown(1000.0f, fovY, width / height);
    g_drawn.clear();
    g_callback(width, height);
    const Drawn* m3 = Find("M3", false);
    const Drawn* a2 = Find("A2", false);
    const Drawn* farley = Find("Farley Road", true);
    const Drawn* elm = Find("Elm Close", true);
    Check(m3 && a2 && farley && elm, "from 1000 m: both shields and both names are drawn");
    Check(Find("M7", false) != nullptr && Find("Loop Slip Road", true) == nullptr,
          "a tightly curved slip road shows its shield but not a name that would leave the road");
    if (m3 && a2 && farley) {
        const float pixelsPerMetre = (height * 0.5f) / (1000.0f * std::tan(fovY * 0.5f));
        Check(std::fabs((m3->y + 7.0f) - (height * 0.5f - 300.0f * pixelsPerMetre)) < 2.0f, "the motorway shield sits 300 m north of centre (field of view taken from the planes)");
        Check(std::fabs(a2->y + 7.0f - height * 0.5f) < 2.0f, "the A road shield sits on the road through the centre");
        Check(std::fabs(farley->angle) < 0.01f && std::fabs(farley->y - height * 0.5f) < 2.0f, "the A road's name runs along the road, level");
        Check(std::fabs(a2->x - farley->x) > 40.0f, "shield and name are on different pieces of the road");
    }
    if (elm) Check(std::fabs(std::fabs(elm->angle) - 1.5708f) < 0.01f, "a north-south street's name is turned to run along it");

    LookDown(40.0f, fovY, width / height);
    g_drawn.clear();
    g_callback(width, height);
    Check(g_drawn.empty(), "from 40 m (zoomed in past 70%): nothing is drawn");

    LookDown(1000.0f, fovY, width / height);
    g_camera.tick -= 5000;
    g_drawn.clear();
    g_callback(width, height);
    Check(g_drawn.empty(), "a stale camera (menu, loading): nothing is drawn");

    LookDown(1000.0f, fovY, width / height);
    Check(road_labels::SetData("", 0) == 0, "empty data clears the roads");
    g_drawn.clear();
    g_callback(width, height);
    Check(g_drawn.empty(), "no roads: nothing is drawn");

    road_labels::Uninstall();
    std::printf(g_failures == 0 ? "ALL OK\n" : "%d FAILED\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
