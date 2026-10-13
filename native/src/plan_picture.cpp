#include "plan_picture.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

// The station plan in a departure board's window: a top-down drawing of a station, made from a scene the
// script describes in the station's own frame (metres; x along the tracks, y across them). Kept apart from the
// Vulkan side so that it can be tested by itself.

namespace tf3api::plan {
namespace {

struct Colour {
    uint8_t r, g, b;
};

// The look: dark ground, neutral buildings and platforms with yellow edges, tracks on ballast.
constexpr Colour kGround = {24, 29, 37};
constexpr Colour kBuilding = {46, 52, 62};
constexpr Colour kBuildingEdge = {82, 90, 104};
constexpr Colour kPlatform = {132, 130, 124};
constexpr Colour kPlatformEdge = {222, 178, 40};
constexpr Colour kStairs = {70, 75, 84};
constexpr Colour kEntrance = {60, 205, 90};
constexpr Colour kBallast = {54, 50, 46};
constexpr Colour kSleeper = {84, 72, 60};
constexpr Colour kRail = {150, 156, 164};
constexpr Colour kServed = {255, 176, 40};
constexpr Colour kBoardDeparture = {250, 196, 30};
constexpr Colour kBoardArrival = {70, 140, 255};
constexpr Colour kWhite = {240, 242, 246};

constexpr int kSuper = 2;   // drawn at twice the size and halved: smooth edges

struct Canvas {
    int w = 0, h = 0;
    std::vector<uint8_t> rgb;   // kSuper times the size, red green blue

    void Fill(Colour c) {
        for (size_t i = 0; i + 2 < rgb.size(); i += 3) {
            rgb[i] = c.r;
            rgb[i + 1] = c.g;
            rgb[i + 2] = c.b;
        }
    }
    void Span(int y, double x0, double x1, Colour c, float alpha) {
        if (y < 0 || y >= h) return;
        int a = static_cast<int>(std::ceil(x0 - 0.5)), b = static_cast<int>(std::floor(x1 - 0.5));
        a = (std::max)(a, 0);
        b = (std::min)(b, w - 1);
        uint8_t* row = rgb.data() + static_cast<size_t>(y) * w * 3;
        for (int x = a; x <= b; ++x) {
            uint8_t* p = row + x * 3;
            if (alpha >= 1.0f) {
                p[0] = c.r;
                p[1] = c.g;
                p[2] = c.b;
            } else {
                p[0] = static_cast<uint8_t>(p[0] + (c.r - p[0]) * alpha);
                p[1] = static_cast<uint8_t>(p[1] + (c.g - p[1]) * alpha);
                p[2] = static_cast<uint8_t>(p[2] + (c.b - p[2]) * alpha);
            }
        }
    }
    // a filled polygon (pixel corners), even-odd
    void Polygon(const std::vector<double>& xs, const std::vector<double>& ys, Colour c, float alpha = 1.0f) {
        const size_t n = xs.size();
        if (n < 3) return;
        double top = ys[0], bottom = ys[0];
        for (double y : ys) {
            top = (std::min)(top, y);
            bottom = (std::max)(bottom, y);
        }
        const int y0 = (std::max)(0, static_cast<int>(std::floor(top))), y1 = (std::min)(h - 1, static_cast<int>(std::ceil(bottom)));
        std::vector<double> cross;
        for (int y = y0; y <= y1; ++y) {
            const double sy = y + 0.5;
            cross.clear();
            for (size_t i = 0; i < n; ++i) {
                const size_t j = (i + 1) % n;
                const double ya = ys[i], yb = ys[j];
                if ((ya <= sy && yb > sy) || (yb <= sy && ya > sy)) cross.push_back(xs[i] + (sy - ya) / (yb - ya) * (xs[j] - xs[i]));
            }
            std::sort(cross.begin(), cross.end());
            for (size_t k = 0; k + 1 < cross.size(); k += 2) Span(y, cross[k], cross[k + 1], c, alpha);
        }
    }
    // a line of the given width (pixels) between two points, with square ends
    void Line(double ax, double ay, double bx, double by, double width, Colour c, float alpha = 1.0f) {
        const double dx = bx - ax, dy = by - ay, length = std::sqrt(dx * dx + dy * dy);
        if (length < 1e-6) return;
        const double nx = -dy / length * width / 2, ny = dx / length * width / 2;
        Polygon({ax + nx, bx + nx, bx - nx, ax - nx}, {ay + ny, by + ny, by - ny, ay - ny}, c, alpha);
    }
    void Disc(double cx, double cy, double radius, Colour c) {
        const int y0 = static_cast<int>(std::floor(cy - radius)), y1 = static_cast<int>(std::ceil(cy + radius));
        for (int y = y0; y <= y1; ++y) {
            const double d = (y + 0.5) - cy;
            if (std::fabs(d) > radius) continue;
            const double half = std::sqrt(radius * radius - d * d);
            Span(y, cx - half, cx + half, c, 1.0f);
        }
    }
};

struct View {
    double cx, cy, scale;   // centre in metres; drawn points per metre
    int w, h;
    double X(double x) const { return (x - cx) * scale + w / 2.0; }
    double Y(double y) const { return h / 2.0 - (y - cy) * scale; }
};

bool ReadNumbers(std::istringstream& in, double* out, int count) {
    for (int i = 0; i < count; ++i) {
        if (!(in >> out[i]) || !std::isfinite(out[i])) return false;
    }
    return true;
}

}  // namespace

bool ParseScene(const char* text, Scene* scene) {
    *scene = Scene();
    if (text == nullptr) return false;
    std::istringstream lines(text);
    std::string line;
    bool any = false;
    while (std::getline(lines, line)) {
        std::istringstream in(line);
        std::string kind;
        if (!(in >> kind)) continue;
        if (kind == "P" || kind == "B" || kind == "S") {   // platform, building, stairs: four corners
            Quad q;
            q.kind = kind[0];
            double v[8];
            if (!ReadNumbers(in, v, 8)) continue;
            for (int i = 0; i < 4; ++i) {
                q.x[i] = v[i * 2];
                q.y[i] = v[i * 2 + 1];
            }
            scene->quads.push_back(q);
            any = true;
        } else if (kind == "T") {   // track: platform number (0 none), then points
            Track t;
            double n = 0;
            if (!(in >> n)) continue;
            t.platform = static_cast<int>(n);
            double x, y;
            while (in >> x >> y) {
                if (!std::isfinite(x) || !std::isfinite(y)) break;
                t.x.push_back(x);
                t.y.push_back(y);
            }
            if (t.x.size() >= 2) {
                scene->tracks.push_back(t);
                any = true;
            }
        } else if (kind == "M") {   // a board: x y kind(d|a) selected(0|1)
            Marker m;
            std::string what;
            int selected = 0;
            if (!(in >> m.x >> m.y >> what >> selected)) continue;
            m.arrivals = what == "a";
            m.selected = selected != 0;
            scene->markers.push_back(m);
        } else if (kind == "H") {   // platforms the selected board serves
            int n;
            while (in >> n) scene->served.push_back(n);
        }
    }
    // the bounds of everything drawn
    bool first = true;
    auto take = [&](double x, double y) {
        if (first) {
            scene->x0 = scene->x1 = x;
            scene->y0 = scene->y1 = y;
            first = false;
        }
        scene->x0 = (std::min)(scene->x0, x);
        scene->x1 = (std::max)(scene->x1, x);
        scene->y0 = (std::min)(scene->y0, y);
        scene->y1 = (std::max)(scene->y1, y);
    };
    for (const Quad& q : scene->quads) for (int i = 0; i < 4; ++i) take(q.x[i], q.y[i]);
    for (const Track& t : scene->tracks) for (size_t i = 0; i < t.x.size(); ++i) take(t.x[i], t.y[i]);
    for (const Marker& m : scene->markers) take(m.x, m.y);
    return any;
}

void Render(const Scene& scene, double cx, double cy, double metresPerPoint, bool overview, const double* viewBox, int width, int height,
            std::vector<uint8_t>* bgra) {
    Canvas canvas;
    canvas.w = width * kSuper;
    canvas.h = height * kSuper;
    canvas.rgb.assign(static_cast<size_t>(canvas.w) * canvas.h * 3, 0);
    canvas.Fill(kGround);
    View view{cx, cy, kSuper / (std::max)(metresPerPoint, 1e-4), canvas.w, canvas.h};
    const double px = view.scale;   // drawn points per metre
    const double minLine = 1.2;     // the thinnest line, in drawn points

    auto quad = [&](const Quad& q, Colour c, double grow) {
        // grow (metres) outwards from the middle, for outlines
        double mx = 0, my = 0;
        for (int i = 0; i < 4; ++i) {
            mx += q.x[i] / 4;
            my += q.y[i] / 4;
        }
        std::vector<double> xs(4), ys(4);
        for (int i = 0; i < 4; ++i) {
            double dx = q.x[i] - mx, dy = q.y[i] - my;
            const double d = std::sqrt(dx * dx + dy * dy);
            if (d > 1e-6 && grow != 0) {
                dx += dx / d * grow;
                dy += dy / d * grow;
            }
            xs[i] = view.X(mx + dx);
            ys[i] = view.Y(my + dy);
        }
        canvas.Polygon(xs, ys, c);
    };

    // buildings, with an edge
    const double edge = (std::max)(0.35, minLine / px);
    for (const Quad& q : scene.quads) {
        if (q.kind != 'B') continue;
        quad(q, kBuildingEdge, edge);
        quad(q, kBuilding, 0);
    }
    // tracks: ballast, sleepers when close enough, two rails; the ones the selected board serves glow
    auto served = [&](int n) { return n > 0 && std::find(scene.served.begin(), scene.served.end(), n) != scene.served.end(); };
    for (const Track& t : scene.tracks) {
        const bool on = served(t.platform);
        for (size_t i = 0; i + 1 < t.x.size(); ++i) {
            const double ax = view.X(t.x[i]), ay = view.Y(t.y[i]), bx = view.X(t.x[i + 1]), by = view.Y(t.y[i + 1]);
            canvas.Line(ax, ay, bx, by, (std::max)(3.2 * px, minLine * 2), on ? Colour{96, 70, 30} : kBallast);
        }
        if (!overview && px >= 2.0) {   // sleepers every 0.65 m
            double carry = 0;   // how far into the next piece the next sleeper lies
            for (size_t i = 0; i + 1 < t.x.size(); ++i) {
                const double dx = t.x[i + 1] - t.x[i], dy = t.y[i + 1] - t.y[i], length = std::sqrt(dx * dx + dy * dy);
                if (length < 1e-6) continue;
                const double ux = dx / length, uy = dy / length;
                double s = carry;
                for (; s < length; s += 0.65) {
                    const double sx = t.x[i] + ux * s, sy = t.y[i] + uy * s;
                    canvas.Line(view.X(sx - uy * 1.3), view.Y(sy + ux * 1.3), view.X(sx + uy * 1.3), view.Y(sy - ux * 1.3), 0.22 * px, kSleeper);
                }
                carry = s - length;
            }
        }
        for (int side = -1; side <= 1; side += 2) {
            for (size_t i = 0; i + 1 < t.x.size(); ++i) {
                const double dx = t.x[i + 1] - t.x[i], dy = t.y[i + 1] - t.y[i], length = std::sqrt(dx * dx + dy * dy);
                if (length < 1e-6) continue;
                const double ox = -dy / length * 0.72 * side, oy = dx / length * 0.72 * side;
                if (px * 1.44 < 3.0) {   // too small for two rails: one line
                    if (side > 0) break;
                    canvas.Line(view.X(t.x[i]), view.Y(t.y[i]), view.X(t.x[i + 1]), view.Y(t.y[i + 1]), (std::max)(minLine, 0.5 * px),
                                on ? kServed : kRail);
                    continue;
                }
                canvas.Line(view.X(t.x[i] + ox), view.Y(t.y[i] + oy), view.X(t.x[i + 1] + ox), view.Y(t.y[i + 1] + oy),
                            (std::max)(minLine, 0.14 * px), on ? kServed : kRail);
            }
        }
    }
    // platforms, with yellow lines along their long edges
    for (const Quad& q : scene.quads) {
        if (q.kind != 'P') continue;
        quad(q, kPlatform, 0);
        double mx = 0, my = 0;
        for (int i = 0; i < 4; ++i) {
            mx += q.x[i] / 4;
            my += q.y[i] / 4;
        }
        double longest = 0;
        for (int i = 0; i < 4; ++i) {
            const int j = (i + 1) % 4;
            longest = (std::max)(longest, std::hypot(q.x[j] - q.x[i], q.y[j] - q.y[i]));
        }
        for (int i = 0; i < 4; ++i) {
            const int j = (i + 1) % 4;
            const double length = std::hypot(q.x[j] - q.x[i], q.y[j] - q.y[i]);
            if (length < longest * 0.6 || length < 3.0) continue;
            // half a metre in from the edge, towards the middle
            double ex = (q.x[i] + q.x[j]) / 2 - mx, ey = (q.y[i] + q.y[j]) / 2 - my;
            const double d = std::sqrt(ex * ex + ey * ey);
            if (d < 1e-6) continue;
            const double inx = -ex / d * 0.5, iny = -ey / d * 0.5;
            canvas.Line(view.X(q.x[i] + inx), view.Y(q.y[i] + iny), view.X(q.x[j] + inx), view.Y(q.y[j] + iny),
                        (std::max)(minLine, 0.18 * px), kPlatformEdge);
        }
    }
    // stairs and underpasses: a darker block with a green dot (a way on to the platform)
    for (const Quad& q : scene.quads) {
        if (q.kind != 'S') continue;
        quad(q, kStairs, 0);
        double mx = 0, my = 0;
        for (int i = 0; i < 4; ++i) {
            mx += q.x[i] / 4;
            my += q.y[i] / 4;
        }
        canvas.Disc(view.X(mx), view.Y(my), (std::max)(0.7 * px, 2.5 * kSuper), kEntrance);
    }
    // boards: dots on the overview; on the main plan a square under the window's own, clickable marker (so a
    // board shows where it stands even where the marker cannot be laid)
    for (const Marker& m : scene.markers) {
        const Colour c = m.arrivals ? kBoardArrival : kBoardDeparture;
        if (overview) {
            const double r = m.selected ? 3.5 * kSuper : 2.5 * kSuper;
            if (m.selected) canvas.Disc(view.X(m.x), view.Y(m.y), r + kSuper, kWhite);
            canvas.Disc(view.X(m.x), view.Y(m.y), r, c);
        } else {
            const double x = view.X(m.x), y = view.Y(m.y), half = 7.0 * kSuper;
            if (m.selected) {
                canvas.Polygon({x - half - 3, x + half + 3, x + half + 3, x - half - 3}, {y - half - 3, y - half - 3, y + half + 3, y + half + 3}, kWhite);
            }
            canvas.Polygon({x - half, x + half, x + half, x - half}, {y - half, y - half, y + half, y + half}, c);
        }
    }
    if (overview) {
        if (viewBox != nullptr) {   // the part the main plan shows
            const double x0 = view.X(viewBox[0]), y0 = view.Y(viewBox[1]), x1 = view.X(viewBox[2]), y1 = view.Y(viewBox[3]);
            const double t = 1.0 * kSuper;
            canvas.Line(x0, y0, x1, y0, t, kWhite);
            canvas.Line(x1, y0, x1, y1, t, kWhite);
            canvas.Line(x1, y1, x0, y1, t, kWhite);
            canvas.Line(x0, y1, x0, y0, t, kWhite);
        }
    }

    // halve: blue, green, red, opacity
    bgra->assign(static_cast<size_t>(width) * height * 4, 255);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            int sum[3] = {0, 0, 0};
            for (int dy = 0; dy < kSuper; ++dy) {
                for (int dx = 0; dx < kSuper; ++dx) {
                    const uint8_t* p = canvas.rgb.data() + (static_cast<size_t>(y * kSuper + dy) * canvas.w + x * kSuper + dx) * 3;
                    for (int k = 0; k < 3; ++k) sum[k] += p[k];
                }
            }
            uint8_t* out = bgra->data() + (static_cast<size_t>(y) * width + x) * 4;
            const int n = kSuper * kSuper;
            out[0] = static_cast<uint8_t>((sum[2] + n / 2) / n);
            out[1] = static_cast<uint8_t>((sum[1] + n / 2) / n);
            out[2] = static_cast<uint8_t>((sum[0] + n / 2) / n);
            out[3] = 255;
        }
    }
}

void Levels(const std::vector<uint8_t>& top, int width, int height, std::vector<uint8_t>* all, std::vector<size_t>* offsets) {
    offsets->clear();
    size_t total = 0;
    for (int w = width, h = height;; w = (std::max)(1, w / 2), h = (std::max)(1, h / 2)) {
        offsets->push_back(total);
        total += static_cast<size_t>(w) * h * 4;
        if (w == 1 && h == 1) break;
    }
    all->assign(total, 0);
    std::memcpy(all->data(), top.data(), (std::min)(top.size(), static_cast<size_t>(width) * height * 4));
    int w = width, h = height;
    for (size_t level = 1; level < offsets->size(); ++level) {
        const uint8_t* big = all->data() + (*offsets)[level - 1];
        uint8_t* small = all->data() + (*offsets)[level];
        const int nw = (std::max)(1, w / 2), nh = (std::max)(1, h / 2);
        for (int y = 0; y < nh; ++y) {
            const int y0 = (std::min)(h - 1, y * 2), y1 = (std::min)(h - 1, y * 2 + 1);
            for (int x = 0; x < nw; ++x) {
                const int x0 = (std::min)(w - 1, x * 2), x1 = (std::min)(w - 1, x * 2 + 1);
                for (int k = 0; k < 4; ++k) {
                    const int sum = big[(static_cast<size_t>(y0) * w + x0) * 4 + k] + big[(static_cast<size_t>(y0) * w + x1) * 4 + k] +
                                    big[(static_cast<size_t>(y1) * w + x0) * 4 + k] + big[(static_cast<size_t>(y1) * w + x1) * 4 + k];
                    small[(static_cast<size_t>(y) * nw + x) * 4 + k] = static_cast<uint8_t>((sum + 2) / 4);
                }
            }
        }
        w = nw;
        h = nh;
    }
}

}  // namespace tf3api::plan
