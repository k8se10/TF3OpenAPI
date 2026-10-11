#include "road_labels.h"

#include "config.h"
#include "log.h"
#include "occlusion.h"
#include "overlay.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace tf3api::road_labels {

namespace {

// ---- Data ----------------------------------------------------------------------------------------------

struct Segment {
    float a[3], b[3];
};

struct Street {
    std::string name, ref;
    char shield = '-';  // M, A, B, X (grey badge) or - (no shield)
    std::string flags;  // the script's own, handed back with a click
    std::string info;   // likewise, longer
    int id = 0;         // the script's number for the road
    int cls = 1;
    float length = 0;   // metres
    uint32_t firstSegment = 0, segmentCount = 0;
};

struct Data {
    std::vector<Street> streets;  // most important first: class, then length
    std::vector<Segment> segments;
};

constexpr size_t kMaxSegments = 400000;
constexpr size_t kMaxStreets = 100000;
constexpr size_t kMaxTextLength = 64;

std::mutex g_dataMutex;
std::shared_ptr<const Data> g_data;

struct Settings {
    bool enabled = true;
    float minHeight = 10.0f, maxHeight = 6000.0f;
    bool logStats = true;
} g_settings;

// ---- Layout constants (pixels) -------------------------------------------------------------------------

constexpr int kMaxLabelsPerFrame = 120;
constexpr int kMaxShieldsPerStreet = 3;
constexpr int kMaxNamesPerStreet = 2;
constexpr float kShieldSpacing = 380.0f;  // between two shields of the same road
constexpr float kNameSpacing = 420.0f;    // between two names of the same road
constexpr float kNameSize = 15.0f, kMainNameSize = 16.0f, kShieldSize = 14.0f;
constexpr float kNameFit = 0.45f;         // a name needs a segment at least this share of its own width
// A name is a straight line of text; where the road bends away underneath it, it would sit on the grass. The
// text is checked at these points along its length (as shares of its width from the centre) and has to be
// within kNameOffRoad text heights of its own road at each of them, or it is not drawn there. A road that is
// all tight bends (a slip road, a loop) then shows its number shield only.
constexpr float kNameCheckPoints[] = {-0.35f, -0.2f, 0.2f, 0.35f};
constexpr float kNameOffRoad = 0.6f;
constexpr unsigned long long kCameraMaxAgeMs = 500;  // older than this: the game is not rendering the world

constexpr uint32_t kNameColour = 0xFFFFFFFFu;
constexpr uint32_t kNameShadow = 0xD0101010u;

// ---- Small vector helpers --------------------------------------------------------------------------------

struct V3 {
    float x, y, z;
};
inline V3 Sub(const V3& a, const V3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline float Dot(const V3& a, const V3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline V3 Cross(const V3& a, const V3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline bool Normalize(V3& v) {
    const float len = std::sqrt(Dot(v, v));
    if (!(len > 1e-6f) || !std::isfinite(len)) return false;
    v = {v.x / len, v.y / len, v.z / len};
    return true;
}

// The camera turned into what projecting a point needs.
struct Projector {
    V3 eye, right, up, forward;
    float tanX, tanY;  // tangent of half the horizontal / vertical field of view
    float width, height;

    // World point to pixels. False when the point is behind (or too close to) the camera.
    bool Project(const float p[3], float* sx, float* sy) const {
        const V3 d = {p[0] - eye.x, p[1] - eye.y, p[2] - eye.z};
        const float z = Dot(d, forward);
        if (!(z > 1.0f)) return false;
        *sx = (Dot(d, right) / (z * tanX) + 1.0f) * 0.5f * width;
        *sy = (1.0f - Dot(d, up) / (z * tanY)) * 0.5f * height;
        return true;
    }
};

// The field of view is taken from the engine's own frustum planes, so it does not matter how the engine
// stores its FOV value. Falls back to treating that value as the vertical angle.
bool MakeProjector(const occlusion::CameraView& cam, float width, float height, Projector* out) {
    out->eye = {cam.eye[0], cam.eye[1], cam.eye[2]};
    out->forward = Sub({cam.target[0], cam.target[1], cam.target[2]}, out->eye);
    if (!Normalize(out->forward)) return false;
    out->right = Cross(out->forward, {cam.up[0], cam.up[1], cam.up[2]});
    if (!Normalize(out->right)) return false;
    out->up = Cross(out->right, out->forward);
    out->width = width;
    out->height = height;

    float sumX = 0, sumY = 0;
    int countX = 0, countY = 0;
    for (int i = 0; i < 6; ++i) {
        V3 n = {cam.planes[i * 4], cam.planes[i * 4 + 1], cam.planes[i * 4 + 2]};
        if (!Normalize(n)) continue;
        const float a = std::fabs(Dot(n, out->right)), b = std::fabs(Dot(n, out->up)), c = std::fabs(Dot(n, out->forward));
        if (c > 0.995f) continue;  // near or far plane
        if (a > b && a > 1e-3f) {
            sumX += c / a;
            ++countX;
        } else if (b > 1e-3f) {
            sumY += c / b;
            ++countY;
        }
    }
    const auto sane = [](float t) { return std::isfinite(t) && t > 0.05f && t < 5.0f; };
    if (countX == 2 && countY == 2 && sane(sumX * 0.5f) && sane(sumY * 0.5f)) {
        out->tanX = sumX * 0.5f;
        out->tanY = sumY * 0.5f;
        return true;
    }
    const float fov = (std::isfinite(cam.fov) && cam.fov > 0.1f && cam.fov < 3.0f) ? cam.fov : 1.0f;
    out->tanY = std::tan(fov * 0.5f);
    out->tanX = out->tanY * (height > 0 ? width / height : 1.0f);
    return sane(out->tanX) && sane(out->tanY);
}

// 0 = fully zoomed out, 100 = fully zoomed in.
float ZoomPercent(float heightAboveTerrain) {
    const float lo = g_settings.minHeight, hi = g_settings.maxHeight;
    const float h = std::clamp(heightAboveTerrain, lo, hi);
    return 100.0f * std::log(hi / h) / std::log(hi / lo);
}

// ---- Drawing ---------------------------------------------------------------------------------------------

struct Box {
    float x, y, halfW, halfH;  // centre and half size
};

bool Free(const std::vector<Box>& taken, float x, float y, float w, float h) {
    for (const Box& t : taken) {
        if (std::fabs(x - t.x) < w * 0.5f + t.halfW && std::fabs(y - t.y) < h * 0.5f + t.halfH) return false;
    }
    return true;
}

void DrawShield(char kind, const char* ref, float x, float y, float textWidth) {
    // British signs: motorways white on blue, primary A roads yellow on green, the rest black on white
    uint32_t background = 0xFFFFFFFFu, text = 0xFF242120u;
    if (kind == 'M') {
        background = 0xFFC17900u;
        text = 0xFFFFFFFFu;
    } else if (kind == 'J') {
        background = 0xFF181818u;  // a motorway junction number: white on black
        text = 0xFFFFFFFFu;
    } else if (kind == 'X') {
        background = 0xFF6E6E6Eu;  // grey: not a road number (an abandoned road's badge)
        text = 0xFFFFFFFFu;
    } else if (kind == 'A') {
        background = 0xFF3C7000u;
        text = 0xFF00D2FFu;
    }
    const float w = textWidth + 10.0f, h = kShieldSize + 6.0f;
    overlay::Rect(x - w * 0.5f - 1.0f, y - h * 0.5f - 1.0f, w + 2.0f, h + 2.0f, 0xC0202020u);
    overlay::Rect(x - w * 0.5f, y - h * 0.5f, w, h, background);
    overlay::Text(x - textWidth * 0.5f, y - kShieldSize * 0.5f, kShieldSize, text, ref);
}

void DrawName(const char* name, float x, float y, float size, float angle, float textWidth) {
    const float cosA = std::cos(angle), sinA = std::sin(angle);
    const float sx = x - cosA * textWidth * 0.5f, sy = y - sinA * textWidth * 0.5f;
    overlay::TextRotated(sx + 1.0f, sy + 1.0f, size, angle, kNameShadow, name);
    overlay::TextRotated(sx - 1.0f, sy - 1.0f, size, angle, kNameShadow, name);
    overlay::TextRotated(sx, sy, size, angle, kNameColour, name);
}

// ---- Clicks ------------------------------------------------------------------------------------------------

struct HitBox {
    Box box;
    uint32_t street;  // index into Data::streets
    float worldX, worldY;
};
std::vector<HitBox> g_hitBoxes;  // the labels of the frame being built / last drawn (present thread only)
bool g_buttonWasDown = false;
POINT g_pressedAt = {};
constexpr int kClickSlop = 5;  // pixels the cursor may move between press and release

std::mutex g_clickMutex;
Click g_click;
bool g_haveClick = false;

// The cursor in frame pixels, when the game window is in front and the cursor is inside it.
bool CursorInFrame(float width, float height, float* x, float* y) {
    const HWND window = GetForegroundWindow();
    DWORD pid = 0;
    if (window == nullptr || GetWindowThreadProcessId(window, &pid) == 0 || pid != GetCurrentProcessId()) return false;
    POINT p;
    RECT client;
    if (!GetCursorPos(&p) || !ScreenToClient(window, &p) || !GetClientRect(window, &client)) return false;
    if (client.right <= 0 || client.bottom <= 0 || p.x < 0 || p.y < 0 || p.x >= client.right || p.y >= client.bottom) return false;
    *x = static_cast<float>(p.x) * width / static_cast<float>(client.right);
    *y = static_cast<float>(p.y) * height / static_cast<float>(client.bottom);
    return true;
}

// Called once per frame before the labels are rebuilt: a left click that started and ended on the same spot
// is tested against the labels the player was looking at (the previous frame's).
void PollClick(const Data& data, float width, float height) {
    const bool down = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
    POINT screen = {};
    GetCursorPos(&screen);
    if (down && !g_buttonWasDown) g_pressedAt = screen;
    const bool released = !down && g_buttonWasDown;
    g_buttonWasDown = down;
    if (!released || std::abs(screen.x - g_pressedAt.x) > kClickSlop || std::abs(screen.y - g_pressedAt.y) > kClickSlop) return;
    float x = 0, y = 0;
    if (!CursorInFrame(width, height, &x, &y)) return;
    for (const HitBox& hit : g_hitBoxes) {
        if (std::fabs(x - hit.box.x) > hit.box.halfW || std::fabs(y - hit.box.y) > hit.box.halfH) continue;
        if (hit.street >= data.streets.size()) return;
        const Street& street = data.streets[hit.street];
        Click click;
        click.id = street.id;
        strncpy_s(click.name, street.name.c_str(), _TRUNCATE);
        strncpy_s(click.ref, street.ref.c_str(), _TRUNCATE);
        click.cls = street.cls;
        click.length = street.length;
        click.segments = static_cast<int>(street.segmentCount);
        strncpy_s(click.flags, street.flags.c_str(), _TRUNCATE);
        strncpy_s(click.info, street.info.c_str(), _TRUNCATE);
        click.x = hit.worldX;
        click.y = hit.worldY;
        {
            std::lock_guard<std::mutex> lock(g_clickMutex);
            g_click = click;
            g_haveClick = true;
        }
        TF3_LOG("road names: clicked road %d '%.64s' %.64s", click.id, click.name, click.ref);
        return;
    }
}

struct ScreenSegment {
    float ax, ay, bx, by;
    bool visible;  // both ends in front of the camera
};

// Distance in pixels from a point to the nearest piece of a road.
float DistanceToRoad(const std::vector<ScreenSegment>& road, float px, float py) {
    float best = 1e9f;
    for (const ScreenSegment& s : road) {
        if (!s.visible) continue;
        const float dx = s.bx - s.ax, dy = s.by - s.ay;
        const float lengthSquared = dx * dx + dy * dy;
        float t = lengthSquared > 1e-6f ? ((px - s.ax) * dx + (py - s.ay) * dy) / lengthSquared : 0.0f;
        t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
        const float d = std::hypot(px - (s.ax + dx * t), py - (s.ay + dy * t));
        if (d < best) best = d;
    }
    return best;
}

// Whether straight text of this width, centred at (x, y) and turned by `angle`, stays on its road.
bool NameFollowsRoad(const std::vector<ScreenSegment>& road, float x, float y, float angle, float width, float size) {
    const float cosA = std::cos(angle), sinA = std::sin(angle);
    for (const float share : kNameCheckPoints) {
        if (DistanceToRoad(road, x + cosA * width * share, y + sinA * width * share) > size * kNameOffRoad) return false;
    }
    return true;
}

unsigned long long g_lastStatsTick = 0;
bool g_loggedNoCamera = false;
std::vector<ScreenSegment> g_road;  // the street being laid out, in pixels (present thread only)

// Where each street's labels were drawn last frame (segment numbers within the street), so that they stay
// put from frame to frame. Present thread only.
struct Sticky {
    std::vector<uint32_t> shields, names;
};
struct Placed {
    int shields = 0, names = 0;
    float shieldX = 0, shieldY = 0, nameX = 0, nameY = 0;
};
std::vector<Sticky> g_sticky, g_nextSticky;
std::vector<Placed> g_placed;
const void* g_stickyFor = nullptr;  // the data set g_sticky belongs to
constexpr float kKeptEase = 0.7f;   // a label already on screen stays down to this share of the usual limits

void Frame(float width, float height) {
    std::shared_ptr<const Data> data;
    {
        std::lock_guard<std::mutex> lock(g_dataMutex);
        data = g_data;
    }
    if (!data || data->streets.empty()) {
        g_hitBoxes.clear();
        return;
    }
    PollClick(*data, width, height);
    g_hitBoxes.clear();

    occlusion::CameraView cam;
    const unsigned long long now = GetTickCount64();
    if (!occlusion::LatestCamera(&cam)) {
        if (!g_loggedNoCamera) {
            g_loggedNoCamera = true;
            TF3_LOG("road names: no camera yet - names need the frame hook of [Occlusion] Enabled=1");
        }
        return;
    }
    if (now - cam.tick > kCameraMaxAgeMs) return;

    const float zoom = cam.haveHeight ? ZoomPercent(cam.heightAboveTerrain) : 0.0f;
    const bool hidden = zoom > kHideAboveZoomPercent;

    Projector view{};
    int drawn = 0, shields = 0;
    if (!hidden && MakeProjector(cam, width, height, &view)) {
        std::vector<Box> taken;
        taken.reserve(kMaxLabelsPerFrame);
        const size_t streetCount = data->streets.size();
        if (g_stickyFor != data.get() || g_sticky.size() != streetCount) {
            g_sticky.assign(streetCount, {});
            g_stickyFor = data.get();
        }
        g_placed.assign(streetCount, {});
        g_nextSticky.assign(streetCount, {});

        // One label on one segment of a street. `kept` = it was there last frame: it only has to remain
        // possible, on slightly easier terms, so that labels do not hop about as the camera moves.
        const auto place = [&](uint32_t streetIndex, uint32_t i, bool shield, bool kept) -> bool {
            const Street& street = data->streets[streetIndex];
            Placed& state = g_placed[streetIndex];
            const ScreenSegment& seg = g_road[i];
            if (!seg.visible || drawn >= kMaxLabelsPerFrame) return false;
            const float mx = (seg.ax + seg.bx) * 0.5f, my = (seg.ay + seg.by) * 0.5f;
            const float margin = kept ? 24.0f : 0.0f;
            if (mx < -margin || my < -margin || mx > width + margin || my > height + margin) return false;
            const float length = std::hypot(seg.bx - seg.ax, seg.by - seg.ay);
            const float ease = kept ? kKeptEase : 1.0f;
            if (shield) {
                const float refWidth = overlay::TextWidth(kShieldSize, street.ref.c_str());
                if (state.shields >= kMaxShieldsPerStreet || length < 12.0f * ease) return false;
                if (state.shields > 0 && std::hypot(mx - state.shieldX, my - state.shieldY) < kShieldSpacing * ease) return false;
                if (!Free(taken, mx, my, refWidth + 16.0f, kShieldSize + 12.0f)) return false;
                DrawShield(street.shield, street.ref.c_str(), mx, my, refWidth);
                taken.push_back({mx, my, (refWidth + 16.0f) * 0.5f, (kShieldSize + 12.0f) * 0.5f});
                ++state.shields;
                ++shields;
                state.shieldX = mx;
                state.shieldY = my;
                g_nextSticky[streetIndex].shields.push_back(i);
            } else {
                const float nameSize = street.cls >= 2 ? kMainNameSize : kNameSize;
                const float nameWidth = overlay::TextWidth(nameSize, street.name.c_str());
                if (state.names >= kMaxNamesPerStreet || length < nameWidth * kNameFit * ease) return false;
                if (state.names > 0 && std::hypot(mx - state.nameX, my - state.nameY) < kNameSpacing * ease) return false;
                // The text runs along the road in a direction fixed by the road itself (towards the east,
                // or north for a road running exactly north-south), not by where the camera is: it does not
                // flip over as the view turns, and reads upside down from the far side like lettering on the
                // ground.
                const Segment& world = data->segments[street.firstSegment + i];
                const float wx = world.b[0] - world.a[0], wy = world.b[1] - world.a[1];
                const bool forwards = wx > 0.0f || (wx == 0.0f && wy >= 0.0f);
                const float angle = forwards ? std::atan2(seg.by - seg.ay, seg.bx - seg.ax) : std::atan2(seg.ay - seg.by, seg.ax - seg.bx);
                const float boxW = std::fabs(std::cos(angle)) * nameWidth + std::fabs(std::sin(angle)) * nameSize + 8.0f;
                const float boxH = std::fabs(std::sin(angle)) * nameWidth + std::fabs(std::cos(angle)) * nameSize + 8.0f;
                if (!NameFollowsRoad(g_road, mx, my, angle, nameWidth, kept ? nameSize / kKeptEase : nameSize)) return false;
                if (!Free(taken, mx, my, boxW, boxH)) return false;
                DrawName(street.name.c_str(), mx, my, nameSize, angle, nameWidth);
                taken.push_back({mx, my, boxW * 0.5f, boxH * 0.5f});
                ++state.names;
                state.nameX = mx;
                state.nameY = my;
                g_nextSticky[streetIndex].names.push_back(i);
            }
            const Segment& at = data->segments[street.firstSegment + i];
            g_hitBoxes.push_back({taken.back(), streetIndex, (at.a[0] + at.b[0]) * 0.5f, (at.a[1] + at.b[1]) * 0.5f});
            ++drawn;
            return true;
        };
        const auto projectStreet = [&](const Street& street) {
            g_road.resize(street.segmentCount);
            for (uint32_t i = 0; i < street.segmentCount; ++i) {
                const Segment& seg = data->segments[street.firstSegment + i];
                ScreenSegment& out = g_road[i];
                out.visible = view.Project(seg.a, &out.ax, &out.ay) && view.Project(seg.b, &out.bx, &out.by);
            }
        };

        // first the labels that were on screen last frame, where they were
        for (uint32_t streetIndex = 0; streetIndex < streetCount; ++streetIndex) {
            const Sticky& before = g_sticky[streetIndex];
            if (before.shields.empty() && before.names.empty()) continue;
            const Street& street = data->streets[streetIndex];
            projectStreet(street);
            for (const uint32_t i : before.shields) {
                if (i < street.segmentCount) place(streetIndex, i, true, true);
            }
            for (const uint32_t i : before.names) {
                if (i < street.segmentCount) place(streetIndex, i, false, true);
            }
        }
        // then new ones in the room that is left, most important roads first
        for (uint32_t streetIndex = 0; streetIndex < streetCount && drawn < kMaxLabelsPerFrame; ++streetIndex) {
            const Street& street = data->streets[streetIndex];
            const bool hasRef = !street.ref.empty(), hasName = !street.name.empty();
            const Placed& state = g_placed[streetIndex];
            if ((!hasRef || state.shields >= kMaxShieldsPerStreet) && (!hasName || state.names >= kMaxNamesPerStreet)) continue;
            projectStreet(street);
            const Sticky& now_ = g_nextSticky[streetIndex];
            for (uint32_t i = 0; i < street.segmentCount; ++i) {
                if ((!hasRef || state.shields >= kMaxShieldsPerStreet) && (!hasName || state.names >= kMaxNamesPerStreet)) break;
                // a segment carries one label
                if (std::find(now_.shields.begin(), now_.shields.end(), i) != now_.shields.end()) continue;
                if (std::find(now_.names.begin(), now_.names.end(), i) != now_.names.end()) continue;
                if (hasRef && place(streetIndex, i, true, false)) continue;
                if (hasName) place(streetIndex, i, false, false);
            }
        }
        g_sticky.swap(g_nextSticky);
    } else {
        g_stickyFor = nullptr;  // hidden: start afresh when the names come back
    }

    if (g_settings.logStats && now - g_lastStatsTick >= 10000) {
        g_lastStatsTick = now;
        TF3_LOG("road names: camera %.0f m above ground, zoom %.0f%% (%s), %d labels (%d shields), fov tan %.3f x %.3f, frame %.0fx%.0f, view %dx%d",
                cam.heightAboveTerrain, zoom, hidden ? "hidden: closer than the limit" : "shown", drawn, shields,
                view.tanX, view.tanY, width, height, cam.viewW, cam.viewH);
    }
}

// The last field of a road's line: up to 96 printable characters.
std::string InfoField(const char*& p, const char* end) {
    std::string out;
    while (p < end && *p != '\t' && *p != '\n' && *p != '\r') {
        const unsigned char c = static_cast<unsigned char>(*p);
        if (c >= 0x20 && out.size() < 96) out.push_back(static_cast<char>(c));
        ++p;
    }
    if (p < end && *p == '\t') ++p;
    return out;
}

// Copies one tab- or newline-terminated field, dropping control characters and anything over the limit.
std::string Field(const char*& p, const char* end) {
    std::string out;
    while (p < end && *p != '\t' && *p != '\n' && *p != '\r') {
        const unsigned char c = static_cast<unsigned char>(*p);
        if (c >= 0x20 && out.size() < kMaxTextLength) out.push_back(static_cast<char>(c));
        ++p;
    }
    if (p < end && *p == '\t') ++p;
    return out;
}

} // namespace

int SetData(const char* text, size_t length) {
    auto data = std::make_shared<Data>();
    std::vector<Street> streets;
    const char* p = text;
    const char* const end = text + length;
    while (p < end) {
        const char* lineEnd = static_cast<const char*>(std::memchr(p, '\n', static_cast<size_t>(end - p)));
        if (lineEnd == nullptr) lineEnd = end;
        if (lineEnd - p >= 2 && p[0] == 'S' && p[1] == '\t' && streets.size() < kMaxStreets) {
            const char* f = p + 2;
            Street street;
            const std::string shield = Field(f, lineEnd), cls = Field(f, lineEnd);
            street.ref = Field(f, lineEnd);
            street.name = Field(f, lineEnd);
            const std::string id = Field(f, lineEnd);
            street.id = id.empty() ? static_cast<int>(streets.size()) + 1 : std::atoi(id.c_str());
            street.flags = Field(f, lineEnd);
            if (street.flags.size() > 10) street.flags.resize(10);
            street.info = InfoField(f, lineEnd);
            street.shield = (shield == "M" || shield == "A" || shield == "B" || shield == "X" || shield == "J") ? shield[0] : '-';
            street.cls = cls.empty() ? 1 : std::clamp(std::atoi(cls.c_str()), 1, 3);
            street.firstSegment = static_cast<uint32_t>(data->segments.size());
            streets.push_back(std::move(street));
        } else if (lineEnd - p >= 2 && p[0] == 'G' && p[1] == ' ' && !streets.empty() && data->segments.size() < kMaxSegments) {
            char line[200];
            const size_t n = (std::min)(static_cast<size_t>(lineEnd - p - 2), sizeof(line) - 1);
            std::memcpy(line, p + 2, n);
            line[n] = '\0';
            float v[6];
            char* cursor = line;
            bool ok = true;
            for (float& value : v) {
                char* next = nullptr;
                value = std::strtof(cursor, &next);
                if (next == cursor || !std::isfinite(value) || std::fabs(value) > 1e7f) {
                    ok = false;
                    break;
                }
                cursor = next;
            }
            if (ok) {
                Segment seg = {{v[0], v[1], v[2]}, {v[3], v[4], v[5]}};
                Street& street = streets.back();
                street.length += std::sqrt((v[3] - v[0]) * (v[3] - v[0]) + (v[4] - v[1]) * (v[4] - v[1]) + (v[5] - v[2]) * (v[5] - v[2]));
                ++street.segmentCount;
                data->segments.push_back(seg);
            }
        }
        p = lineEnd < end ? lineEnd + 1 : end;
    }
    // roads with nothing to show or nothing to show it on are dropped; the rest go most important first
    for (Street& street : streets) {
        if (street.segmentCount > 0 && (!street.name.empty() || !street.ref.empty())) data->streets.push_back(std::move(street));
    }
    std::stable_sort(data->streets.begin(), data->streets.end(), [](const Street& l, const Street& r) {
        if (l.cls != r.cls) return l.cls > r.cls;
        return l.length > r.length;
    });
    const int count = static_cast<int>(data->streets.size());
    const size_t segments = data->segments.size();
    {
        std::lock_guard<std::mutex> lock(g_dataMutex);
        g_data = std::move(data);
    }
    TF3_LOG("road names: %d roads, %zu segments received from the script", count, segments);
    return count;
}

bool TakeClick(Click* out) {
    std::lock_guard<std::mutex> lock(g_clickMutex);
    if (!g_haveClick) return false;
    *out = g_click;
    g_haveClick = false;
    return true;
}

void Install() {
    g_settings.enabled = config::GetBool("RoadNames", "Enabled", true);
    g_settings.minHeight = config::GetFloat("RoadNames", "MinHeight", 10.0f);
    g_settings.maxHeight = config::GetFloat("RoadNames", "MaxHeight", 6000.0f);
    g_settings.logStats = config::GetBool("RoadNames", "LogStats", true);
    if (!(g_settings.minHeight >= 1.0f && g_settings.minHeight <= 1000.0f)) g_settings.minHeight = 10.0f;
    if (!(g_settings.maxHeight >= g_settings.minHeight * 2.0f && g_settings.maxHeight <= 100000.0f)) g_settings.maxHeight = 6000.0f;
    if (!g_settings.enabled) {
        TF3_LOG("road names: off ([RoadNames] Enabled=0)");
        return;
    }
    overlay::SetFrameCallback(&Frame);
    TF3_LOG("road names: ready (hidden beyond %.0f%% zoom; zoom range %.0f - %.0f m above ground)",
            kHideAboveZoomPercent, g_settings.minHeight, g_settings.maxHeight);
}

void Uninstall() {
    overlay::SetFrameCallback(nullptr);
    std::lock_guard<std::mutex> lock(g_dataMutex);
    g_data.reset();
}

} // namespace tf3api::road_labels
