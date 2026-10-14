#include "occlusion.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <intrin.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#include "MaskedOcclusionCulling.h"
#include "MinHook.h"

namespace tf3api::occlusion {
namespace {

// ---- Engine layout (build 40408; see re_notes/renderer/culling.md) ------------------------------------
// CRenderer::NewUpdate(renderer, ...)             per-frame renderer update, runs before the visibility jobs
//   render camera   = *(renderer + 0x78)          +0x00/+0x04 viewport ints, +0x10 FOV (radians),
//                                                 +0x24 eye, +0x30 target, +0x3c up, +0x188 six planes
//   terrain         = *(*(*(renderer + 0x10) + 0x1e0) + 0x10)
// frustum test(box[min xyz, max xyz], planes)     returns non-zero in AL when the box is inside / intersecting
// terrain height(terrain, &xy) -> float           clamps to the map bounds, tolerates NaN
constexpr char kSigNewUpdate[] = "48 89 5C 24 10 48 89 74 24 18 57 41 54 41 55 41 56 41 57 B8 80 14 00 00";
constexpr char kSigFrustumTest[] = "48 83 EC 18 33 C0 C5 F8 29 34 24 48 83 C2 08 C5 E0 57 DB";
constexpr char kSigTerrainHeight[] =
    "48 83 EC 58 48 8D 05 ?? ?? ?? ?? 48 89 44 24 20 48 89 4C 24 28 C5 F9 EF C0 C5 FA 7F 44 24 30 C6 44 24 40 00";

// Scene-rendering callers of the frustum test that may be occlusion-culled. Every other caller (UI, HUD
// icons, picking, unidentified code) keeps vanilla behaviour.
// `text`: the function's own name as its assertions carry it in the executable. When the byte pattern no
// longer matches after a game update, the function is looked for as the one that refers to that text
// (sigscan::FindByTexts); null where the function has no assertion of its own.
struct CallerSig {
    const char* name;
    const char* pattern;
    const char* text;
};
constexpr char kTextNewUpdate[] = "CRenderer::NewUpdate";
constexpr CallerSig kAllowedCallers[] = {
    {"static models (NewUpdate lambda_4)", "4C 8B DC 49 89 5B 18 49 89 73 20 57 41 54 41 55 41 56 41 57 48 81 EC C0 03 00 00",
     "CRenderer::NewUpdate::<lambda_4>::operator ()"},
    {"model instances (NewUpdate lambda_6)",
     "48 8B C4 48 89 58 20 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 18 FC FF FF 48 81 EC B0 04 00 00 C5 F8 29 70 B8 "
     "C5 F8 29 78 A8 C5 78 29 40 98 C5 78 29 48 88 C5 78 29 90 78 FF FF FF C5 78 29 98 68 FF FF FF C5 78 29 A0 58 FF FF FF",
     "CRenderer::NewUpdate::<lambda_6>::operator ()"},
    {"model instances (render list)", "48 8B C4 53 56 57 41 54 41 55 41 56 41 57 48 81 EC 50 07 00 00", nullptr},
    {"grass patches",
     "48 8B C4 48 89 58 20 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 48 FE FF FF 48 81 EC 80 02 00 00 C5 F8 29 70 B8 "
     "C5 F8 29 78 A8 C5 78 29 40 98 C5 78 29 48 88 C5 78 29 90 78 FF FF FF",
     "terrain::ComputePatches::<lambda_1>::operator ()"},
    {"vegetation", "48 8B C4 53 56 57 41 54 41 55 41 56 41 57 48 81 EC 70 05 00 00", "terrain::RenderVegetation"},
    {"buildings", "48 8B C4 48 89 58 18 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 88 FC FF FF", nullptr},
    {"terrain tiles",
     // the two stack-frame sizes differ between builds 40408 and 40420, so they are left open
     "48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 ?? ?? FF FF 48 81 EC ?? ?? "
     "00 00 C5 F8 29 70 C8 C5 F8 29 78 B8 C5 78 29 40 A8 C5 78 29 48 98 C5 78 29 50 88 C5 78 29 98 78 FF FF FF "
     "C5 78 29 A0 68 FF FF FF C5 78 29 A8 58 FF FF FF C5 78 29 B0 48 FF FF FF C5 78 29 B8 38 FF FF FF "
     "48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 ?? ?? 00 00 4C 8B E9 48 89",
     "terrain::RenderDataManager::Update"},
};
constexpr int kMaxCallers = static_cast<int>(sizeof(kAllowedCallers) / sizeof(kAllowedCallers[0]));

constexpr unsigned kBufferWidth = 384;   // multiple of 8
constexpr unsigned kBufferHeight = 216;  // multiple of 4
constexpr float kNearW = 0.5f;
constexpr int kFrameCount = 4;  // ring of occlusion buffers: readers may still hold an older one

using NewUpdateFn = uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);
using FrustumTestFn = uint64_t (*)(const float*, const void*);
using TerrainHeightFn = float (*)(void*, const float*);

struct Vec3 {
    float x, y, z;
};

struct Frame {
    MaskedOcclusionCulling* moc = nullptr;
    Vec3 eye{}, right{}, up{}, forward{};
    float sx = 1.0f, sy = 1.0f;
    // True when this buffer's field of view is verified to contain the game's whole view (from the game's
    // own frustum planes). Only then may a box that sticks out of the buffer be judged on its in-buffer part.
    bool coversView = false;
};

struct Settings {
    float terrainMargin = 15.0f;
    float minDistance = 30.0f;
    float gridSpacing = 80.0f;
    int gridCells = 96;
    int toggleKey = VK_F10;
    int benchKey = VK_F9;
    bool logStats = true;
};

struct CameraState {
    void* camera;
    void* terrain;
    Vec3 eye, target, up;
    float fov;
    int viewW, viewH;
    float planes[24];     // the game's six frustum planes (nx, ny, nz, d); inside is n.p + d <= 0
    bool havePlanes;
    bool assumeCovered;   // self-test only: no engine planes to verify against
};

Settings g_settings;
NewUpdateFn g_origNewUpdate = nullptr;
FrustumTestFn g_origFrustumTest = nullptr;
TerrainHeightFn g_terrainHeight = nullptr;
void* g_targetNewUpdate = nullptr;
void* g_targetFrustumTest = nullptr;

struct Range {
    uintptr_t begin, end;
};
Range g_callers[kMaxCallers];
int g_callerCount = 0;

Frame g_frames[kFrameCount];
int g_writeIndex = 0;
std::atomic<Frame*> g_current{nullptr};
std::atomic<const void*> g_cameraPlanes{nullptr};
std::atomic<bool> g_runtimeEnabled{true};

// Terrain height cache (main thread only): a scrolling grid of heights centred on the camera.
std::vector<float> g_heights;
int g_gridN = 0;  // vertices per side = gridCells + 1
int g_originX = 0, g_originY = 0;
void* g_cachedTerrain = nullptr;
bool g_cacheValid = false;
int g_refreshRow = 0;
std::vector<float> g_clipVerts;
std::vector<unsigned int> g_indices;
std::vector<uint8_t> g_vertNear;

// Stats.
std::atomic<uint64_t> g_callerTests[kMaxCallers], g_callerCulled[kMaxCallers];
std::atomic<uint64_t> g_otherCameraTests{0};  // camera-frustum tests from callers outside the allow-list
const char* g_callerNames[kMaxCallers] = {};
uint64_t g_frameCounter = 0, g_builtFrames = 0, g_coveredFrames = 0;
double g_buildMsTotal = 0.0;
uint64_t g_lastStatsTick = 0;
bool g_keyWasDown = false, g_benchKeyWasDown = false;

// Frame time, measured between consecutive NewUpdate calls, split by whether culling was on.
LONGLONG g_lastFrameQpc = 0;
double g_msOn = 0.0, g_msOff = 0.0;
uint64_t g_framesOn = 0, g_framesOff = 0;

// Built-in A/B benchmark (BenchKey): alternating off/on phases, each with a settle period that is not counted.
constexpr int kBenchPhases = 8;  // off, on, off, on, ...
constexpr double kBenchPhaseMs = 5000.0;
constexpr double kBenchSettleMs = 1000.0;
bool g_benchRunning = false;
int g_benchPhase = 0;
double g_benchPhaseElapsedMs = 0.0, g_benchPhaseMs = 0.0;
uint64_t g_benchPhaseFrames = 0;
double g_benchTotalMs[2] = {0.0, 0.0};  // [0] = off, [1] = on
uint64_t g_benchTotalFrames[2] = {0, 0};
bool g_benchSavedEnabled = true;
LARGE_INTEGER g_qpcFreq{};

inline Vec3 Sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline float Dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 Cross(const Vec3& a, const Vec3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline bool Normalize(Vec3& v) {
    float len = std::sqrt(Dot(v, v));
    if (!(len > 1e-6f) || !std::isfinite(len)) return false;
    v = {v.x / len, v.y / len, v.z / len};
    return true;
}
inline bool Finite(const Vec3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) && std::fabs(v.x) < 1e7f &&
           std::fabs(v.y) < 1e7f && std::fabs(v.z) < 1e7f;
}

// Reads the camera and terrain out of the renderer. No C++ objects here: SEH-guarded.
bool ReadCameraState(uintptr_t renderer, CameraState* out) {
    __try {
        auto* cam = *reinterpret_cast<uint8_t**>(renderer + 0x78);
        if (cam == nullptr) return false;
        out->camera = cam;
        std::memcpy(&out->viewW, cam + 0x00, sizeof(int));
        std::memcpy(&out->viewH, cam + 0x04, sizeof(int));
        std::memcpy(&out->fov, cam + 0x10, sizeof(float));
        std::memcpy(&out->eye, cam + 0x24, sizeof(Vec3));
        std::memcpy(&out->target, cam + 0x30, sizeof(Vec3));
        std::memcpy(&out->up, cam + 0x3c, sizeof(Vec3));
        std::memcpy(out->planes, cam + 0x188, sizeof(out->planes));
        out->havePlanes = true;

        auto* a = *reinterpret_cast<uint8_t**>(renderer + 0x10);
        if (a == nullptr) return false;
        auto* b = *reinterpret_cast<uint8_t**>(a + 0x1e0);
        if (b == nullptr) return false;
        out->terrain = *reinterpret_cast<void**>(b + 0x10);
        return out->terrain != nullptr;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Camera statistics for the profiler report (written once per frame on the render path, read rarely).
std::mutex g_cameraMutex;
struct CameraAccumulator {
    unsigned long long frames = 0;
    double heightSum = 0, travelled = 0, fovSum = 0;
    float heightMin = 0, heightMax = 0;
    Vec3 lastEye{};
    bool haveLast = false;
} g_cameraStats;

bool SampleHeight(void* terrain, float x, float y, float* out);

// The latest camera, for LatestCamera(). Written once per frame on the render path.
std::mutex g_viewMutex;
CameraView g_view;
bool g_haveView = false;

void PublishCamera(const CameraState& cs) {
    CameraView view;
    std::memcpy(view.eye, &cs.eye, sizeof(view.eye));
    std::memcpy(view.target, &cs.target, sizeof(view.target));
    std::memcpy(view.up, &cs.up, sizeof(view.up));
    view.fov = cs.fov;
    view.viewW = cs.viewW;
    view.viewH = cs.viewH;
    std::memcpy(view.planes, cs.planes, sizeof(view.planes));
    float ground = 0.0f;
    if (SampleHeight(cs.terrain, cs.eye.x, cs.eye.y, &ground) && std::isfinite(ground)) {
        view.heightAboveTerrain = cs.eye.z - ground;
        view.haveHeight = true;
    }
    view.tick = GetTickCount64();
    std::lock_guard<std::mutex> lock(g_viewMutex);
    g_view = view;
    g_haveView = true;
}

void NoteCamera(const CameraState& cs) {
    float ground = 0.0f;
    if (!SampleHeight(cs.terrain, cs.eye.x, cs.eye.y, &ground) || !std::isfinite(ground)) return;
    const float height = cs.eye.z - ground;
    std::lock_guard<std::mutex> lock(g_cameraMutex);
    CameraAccumulator& c = g_cameraStats;
    if (c.frames == 0) {
        c.heightMin = c.heightMax = height;
    } else {
        c.heightMin = height < c.heightMin ? height : c.heightMin;
        c.heightMax = height > c.heightMax ? height : c.heightMax;
    }
    if (c.haveLast) {
        const Vec3 d = Sub(cs.eye, c.lastEye);
        c.travelled += std::sqrt(static_cast<double>(d.x) * d.x + static_cast<double>(d.y) * d.y + static_cast<double>(d.z) * d.z);
    }
    c.lastEye = cs.eye;
    c.haveLast = true;
    c.heightSum += height;
    c.fovSum += cs.fov;
    ++c.frames;
}

bool SampleHeight(void* terrain, float x, float y, float* out) {
    __try {
        const float xy[2] = {x, y};
        *out = g_terrainHeight(terrain, xy);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool SampleCell(void* terrain, int ix, int iy) {
    float h = 0.0f;
    const float s = g_settings.gridSpacing;
    if (!SampleHeight(terrain, static_cast<float>(g_originX + ix) * s, static_cast<float>(g_originY + iy) * s, &h)) {
        return false;
    }
    g_heights[static_cast<size_t>(iy) * g_gridN + ix] = std::isfinite(h) ? h : 0.0f;
    return true;
}

// Keeps the height grid centred on the eye: full sample the first time, otherwise scroll and sample only
// the newly exposed strips, plus one row per frame so terrain edits are picked up.
bool UpdateHeightCache(void* terrain, const Vec3& eye) {
    const int n = g_gridN;
    const float s = g_settings.gridSpacing;
    const int wantX = static_cast<int>(std::floor(eye.x / s)) - g_settings.gridCells / 2;
    const int wantY = static_cast<int>(std::floor(eye.y / s)) - g_settings.gridCells / 2;

    const int dx = wantX - g_originX, dy = wantY - g_originY;
    const bool full = !g_cacheValid || terrain != g_cachedTerrain || std::abs(dx) >= n || std::abs(dy) >= n;
    if (full) {
        g_originX = wantX;
        g_originY = wantY;
        g_cachedTerrain = terrain;
        for (int iy = 0; iy < n; ++iy) {
            for (int ix = 0; ix < n; ++ix) {
                if (!SampleCell(terrain, ix, iy)) {
                    g_cacheValid = false;
                    return false;
                }
            }
        }
        g_cacheValid = true;
        return true;
    }

    if (dx != 0 || dy != 0) {
        // Scroll existing samples into place (row order chosen so nothing is overwritten before it is read).
        std::vector<float>& h = g_heights;
        if (dy >= 0) {
            for (int iy = 0; iy + dy < n; ++iy) {
                std::memmove(&h[static_cast<size_t>(iy) * n + (dx < 0 ? -dx : 0)],
                             &h[static_cast<size_t>(iy + dy) * n + (dx > 0 ? dx : 0)],
                             sizeof(float) * static_cast<size_t>(n - std::abs(dx)));
            }
        } else {
            for (int iy = n - 1; iy + dy >= 0; --iy) {
                std::memmove(&h[static_cast<size_t>(iy) * n + (dx < 0 ? -dx : 0)],
                             &h[static_cast<size_t>(iy + dy) * n + (dx > 0 ? dx : 0)],
                             sizeof(float) * static_cast<size_t>(n - std::abs(dx)));
            }
        }
        g_originX = wantX;
        g_originY = wantY;
        for (int iy = 0; iy < n; ++iy) {
            const bool newRow = (dy > 0) ? (iy >= n - dy) : (dy < 0 ? iy < -dy : false);
            for (int ix = 0; ix < n; ++ix) {
                const bool newCol = (dx > 0) ? (ix >= n - dx) : (dx < 0 ? ix < -dx : false);
                if ((newRow || newCol) && !SampleCell(terrain, ix, iy)) {
                    g_cacheValid = false;
                    return false;
                }
            }
        }
    }

    g_refreshRow = (g_refreshRow + 1) % n;
    for (int ix = 0; ix < n; ++ix) {
        if (!SampleCell(terrain, ix, g_refreshRow)) {
            g_cacheValid = false;
            return false;
        }
    }
    return true;
}

// Checks that our buffer's field of view contains the game's: the four corner directions of the game's
// frustum (intersections of its side planes) must project inside our NDC square.
bool BufferCoversGameView(const CameraState& cs, const Vec3& right, const Vec3& up, const Vec3& forward, float sx,
                          float sy) {
    if (!cs.havePlanes) return false;
    Vec3 side[6];
    int sideCount = 0;
    for (int i = 0; i < 6; ++i) {
        Vec3 n = {cs.planes[i * 4], cs.planes[i * 4 + 1], cs.planes[i * 4 + 2]};
        if (!Finite(n) || !Normalize(n)) return false;
        if (std::fabs(Dot(n, forward)) < 0.95f) side[sideCount++] = n;  // skip the near and far planes
    }
    if (sideCount != 4) return false;

    int corners = 0;
    for (int a = 0; a < 4; ++a) {
        for (int b = a + 1; b < 4; ++b) {
            Vec3 dir = Cross(side[a], side[b]);
            if (!Normalize(dir)) continue;  // opposite planes: (nearly) parallel
            if (Dot(dir, forward) < 0.0f) dir = {-dir.x, -dir.y, -dir.z};
            bool inside = true;
            for (int k = 0; k < 4; ++k) {
                if (Dot(side[k], dir) > 1e-3f) inside = false;
            }
            if (!inside) continue;  // an intersection line that is not an edge of the frustum
            const float w = Dot(dir, forward);
            if (!(w > 1e-4f)) return false;
            const float x = Dot(dir, right) * sx / w, y = Dot(dir, up) * sy / w;
            if (!(std::fabs(x) <= 0.98f && std::fabs(y) <= 0.98f)) return false;
            ++corners;
        }
    }
    return corners == 4;
}

void BuildFrame(const CameraState& cs, bool heightsReady = false) {
    Vec3 forward = Sub(cs.target, cs.eye);
    if (!Finite(cs.eye) || !Finite(cs.target) || !Normalize(forward)) {
        g_current.store(nullptr, std::memory_order_release);
        return;
    }
    Vec3 worldUp = cs.up;
    if (!Finite(worldUp) || !Normalize(worldUp)) worldUp = {0.0f, 0.0f, 1.0f};
    Vec3 right = Cross(forward, worldUp);
    if (!Normalize(right)) {
        right = Cross(forward, Vec3{0.0f, 1.0f, 0.0f});
        if (!Normalize(right)) {
            g_current.store(nullptr, std::memory_order_release);
            return;
        }
    }
    const Vec3 up = Cross(right, forward);

    if (!heightsReady && !UpdateHeightCache(cs.terrain, cs.eye)) {
        g_current.store(nullptr, std::memory_order_release);
        return;
    }

    // Our own projection from the real eye. Occlusion only depends on the eye position, so the field of
    // view just has to cover at least what the game shows; it is widened for safety.
    float fov = (std::isfinite(cs.fov) && cs.fov > 0.1f && cs.fov < 3.0f) ? cs.fov : 1.0f;
    fov = fov * 1.2f;
    if (fov > 2.6f) fov = 2.6f;
    float aspect = 16.0f / 9.0f;
    if (cs.viewW >= 16 && cs.viewW <= 16384 && cs.viewH >= 16 && cs.viewH <= 16384) {
        const float a = static_cast<float>(cs.viewW) / static_cast<float>(cs.viewH);
        aspect = a >= 1.0f ? a : 1.0f / a;
    }
    const float sy = 1.0f / std::tan(fov * 0.5f);
    const float sx = sy / aspect;

    if (!heightsReady) NoteCamera(cs);  // heightsReady = synthetic self-test camera

    g_writeIndex = (g_writeIndex + 1) % kFrameCount;
    Frame& frame = g_frames[g_writeIndex];
    frame.eye = cs.eye;
    frame.right = right;
    frame.up = up;
    frame.forward = forward;
    frame.sx = sx;
    frame.sy = sy;
    frame.coversView = cs.assumeCovered || BufferCoversGameView(cs, right, up, forward, sx, sy);

    const int n = g_gridN;
    const float s = g_settings.gridSpacing;
    const float margin = g_settings.terrainMargin;
    const float minDistSq = g_settings.minDistance * g_settings.minDistance;
    for (int iy = 0; iy < n; ++iy) {
        for (int ix = 0; ix < n; ++ix) {
            const size_t v = static_cast<size_t>(iy) * n + ix;
            const Vec3 d = {static_cast<float>(g_originX + ix) * s - cs.eye.x,
                            static_cast<float>(g_originY + iy) * s - cs.eye.y, g_heights[v] - margin - cs.eye.z};
            g_vertNear[v] = Dot(d, d) < minDistSq ? 1 : 0;
            float* out = &g_clipVerts[v * 4];
            out[0] = Dot(d, right) * sx;
            out[1] = Dot(d, up) * sy;
            out[2] = 0.0f;
            out[3] = Dot(d, forward);
        }
    }

    size_t indexCount = 0;
    for (int iy = 0; iy + 1 < n; ++iy) {
        for (int ix = 0; ix + 1 < n; ++ix) {
            const unsigned v00 = static_cast<unsigned>(iy * n + ix), v10 = v00 + 1;
            const unsigned v01 = v00 + static_cast<unsigned>(n), v11 = v01 + 1;
            if (g_vertNear[v00] | g_vertNear[v10] | g_vertNear[v01] | g_vertNear[v11]) continue;
            unsigned* idx = &g_indices[indexCount];
            idx[0] = v00, idx[1] = v10, idx[2] = v11;
            idx[3] = v00, idx[4] = v11, idx[5] = v01;
            indexCount += 6;
        }
    }

    frame.moc->ClearBuffer();
    if (indexCount > 0) {
        // Double-sided: from underground the terrain surface is seen from below and must still occlude.
        frame.moc->RenderTriangles(g_clipVerts.data(), g_indices.data(), static_cast<int>(indexCount / 3), nullptr,
                                   MaskedOcclusionCulling::BACKFACE_NONE, MaskedOcclusionCulling::CLIP_PLANE_ALL,
                                   MaskedOcclusionCulling::VertexLayout(16, 4, 12));
    }
    g_current.store(&frame, std::memory_order_release);
}

void LogStats(uint64_t now) {
    if (!g_settings.logStats || now - g_lastStatsTick < 10000) return;
    uint64_t tests = 0, culled = 0, perTests[kMaxCallers] = {}, perCulled[kMaxCallers] = {};
    for (int i = 0; i < g_callerCount; ++i) {
        perTests[i] = g_callerTests[i].exchange(0);
        perCulled[i] = g_callerCulled[i].exchange(0);
        tests += perTests[i];
        culled += perCulled[i];
    }
    const uint64_t other = g_otherCameraTests.exchange(0);
    const double avgMs = g_frameCounter ? g_buildMsTotal / static_cast<double>(g_frameCounter) : 0.0;
    const double frames = g_frameCounter ? static_cast<double>(g_frameCounter) : 1.0;
    TF3_LOG("occlusion: %s | frame time on %.2f ms (%llu frames), off %.2f ms (%llu frames) | buffer build %.2f ms | "
            "%llu/%llu frames view-coverage verified",
            g_runtimeEnabled.load() ? "on" : "off", g_framesOn ? g_msOn / static_cast<double>(g_framesOn) : 0.0,
            static_cast<unsigned long long>(g_framesOn), g_framesOff ? g_msOff / static_cast<double>(g_framesOff) : 0.0,
            static_cast<unsigned long long>(g_framesOff), avgMs, static_cast<unsigned long long>(g_coveredFrames),
            static_cast<unsigned long long>(g_builtFrames));
    if (g_frameCounter > 0) {
        TF3_LOG("occlusion:   per frame: %.0f boxes tested, %.0f culled (%.1f%%); %.0f camera tests from other callers",
                static_cast<double>(tests) / frames, static_cast<double>(culled) / frames,
                tests ? 100.0 * static_cast<double>(culled) / static_cast<double>(tests) : 0.0,
                static_cast<double>(other) / frames);
        for (int i = 0; i < g_callerCount; ++i) {
            if (perTests[i] == 0) continue;
            TF3_LOG("occlusion:     %-38s %7.0f tested, %7.0f culled (%.1f%%)", g_callerNames[i],
                    static_cast<double>(perTests[i]) / frames, static_cast<double>(perCulled[i]) / frames,
                    100.0 * static_cast<double>(perCulled[i]) / static_cast<double>(perTests[i]));
        }
    }
    g_builtFrames = 0;
    g_coveredFrames = 0;
    g_frameCounter = 0;
    g_buildMsTotal = 0.0;
    g_msOn = g_msOff = 0.0;
    g_framesOn = g_framesOff = 0;
    g_lastStatsTick = now;
}

bool GameWindowFocused() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

// Advances the A/B benchmark by one frame of the given length; switches phases and logs results.
void StepBenchmark(double frameMs) {
    if (!g_benchRunning) return;
    g_benchPhaseElapsedMs += frameMs;
    if (g_benchPhaseElapsedMs > kBenchSettleMs) {
        g_benchPhaseMs += frameMs;
        ++g_benchPhaseFrames;
    }
    if (g_benchPhaseElapsedMs < kBenchPhaseMs) return;

    const int state = g_benchPhase & 1;  // even phases = off, odd = on
    const double avg = g_benchPhaseFrames ? g_benchPhaseMs / static_cast<double>(g_benchPhaseFrames) : 0.0;
    TF3_LOG("occlusion benchmark: phase %d/%d culling %-3s  %.2f ms/frame (%.1f fps, %llu frames)", g_benchPhase + 1,
            kBenchPhases, state ? "ON" : "OFF", avg, avg > 0.0 ? 1000.0 / avg : 0.0,
            static_cast<unsigned long long>(g_benchPhaseFrames));
    g_benchTotalMs[state] += g_benchPhaseMs;
    g_benchTotalFrames[state] += g_benchPhaseFrames;

    ++g_benchPhase;
    g_benchPhaseElapsedMs = g_benchPhaseMs = 0.0;
    g_benchPhaseFrames = 0;
    if (g_benchPhase < kBenchPhases) {
        g_runtimeEnabled.store((g_benchPhase & 1) != 0);
        return;
    }
    const double off = g_benchTotalFrames[0] ? g_benchTotalMs[0] / static_cast<double>(g_benchTotalFrames[0]) : 0.0;
    const double on = g_benchTotalFrames[1] ? g_benchTotalMs[1] / static_cast<double>(g_benchTotalFrames[1]) : 0.0;
    TF3_LOG("occlusion benchmark: RESULT  off %.2f ms (%.1f fps)  on %.2f ms (%.1f fps)  change %+.1f%% frame time",
            off, off > 0.0 ? 1000.0 / off : 0.0, on, on > 0.0 ? 1000.0 / on : 0.0,
            off > 0.0 ? 100.0 * (on - off) / off : 0.0);
    g_benchRunning = false;
    g_runtimeEnabled.store(g_benchSavedEnabled);
}

void PollKeys() {
    if (g_settings.toggleKey > 0) {
        const bool down = (GetAsyncKeyState(g_settings.toggleKey) & 0x8000) != 0;
        if (down && !g_keyWasDown && !g_benchRunning && GameWindowFocused()) {
            const bool enabled = !g_runtimeEnabled.load();
            g_runtimeEnabled.store(enabled);
            TF3_LOG("occlusion: toggled %s", enabled ? "ON" : "OFF");
        }
        g_keyWasDown = down;
    }
    if (g_settings.benchKey > 0) {
        const bool down = (GetAsyncKeyState(g_settings.benchKey) & 0x8000) != 0;
        if (down && !g_benchKeyWasDown && !g_benchRunning && GameWindowFocused()) {
            g_benchSavedEnabled = g_runtimeEnabled.load();
            g_benchRunning = true;
            g_benchPhase = 0;
            g_benchPhaseElapsedMs = g_benchPhaseMs = 0.0;
            g_benchPhaseFrames = 0;
            g_benchTotalMs[0] = g_benchTotalMs[1] = 0.0;
            g_benchTotalFrames[0] = g_benchTotalFrames[1] = 0;
            g_runtimeEnabled.store(false);  // phase 1 = off
            TF3_LOG("occlusion benchmark: started - %d phases of %.0f s alternating off/on; keep the view steady",
                    kBenchPhases, kBenchPhaseMs / 1000.0);
        }
        g_benchKeyWasDown = down;
    }
}

void OnFrame(uintptr_t renderer) {
    // Frame time since the previous NewUpdate, attributed to the state that frame ran in.
    LARGE_INTEGER nowQpc;
    QueryPerformanceCounter(&nowQpc);
    if (g_lastFrameQpc != 0) {
        const double frameMs =
            1000.0 * static_cast<double>(nowQpc.QuadPart - g_lastFrameQpc) / static_cast<double>(g_qpcFreq.QuadPart);
        if (frameMs < 2000.0) {  // ignore loading screens / pauses
            if (g_runtimeEnabled.load(std::memory_order_relaxed)) {
                g_msOn += frameMs;
                ++g_framesOn;
            } else {
                g_msOff += frameMs;
                ++g_framesOff;
            }
            StepBenchmark(frameMs);
        }
    }
    g_lastFrameQpc = nowQpc.QuadPart;

    PollKeys();
    const uint64_t now = GetTickCount64();
    {
        // published whether or not culling is switched on: other modules draw with this camera
        CameraState view{};
        if (ReadCameraState(renderer, &view) && Finite(view.eye) && Finite(view.target)) PublishCamera(view);
    }
    if (!g_runtimeEnabled.load(std::memory_order_relaxed)) {
        g_current.store(nullptr, std::memory_order_release);
        LogStats(now);
        return;
    }

    CameraState cs{};
    if (!ReadCameraState(renderer, &cs)) {
        g_current.store(nullptr, std::memory_order_release);
        return;
    }
    g_cameraPlanes.store(static_cast<uint8_t*>(cs.camera) + 0x188, std::memory_order_release);

    LARGE_INTEGER t0, t1;
    QueryPerformanceCounter(&t0);
    BuildFrame(cs);
    QueryPerformanceCounter(&t1);
    g_buildMsTotal += 1000.0 * static_cast<double>(t1.QuadPart - t0.QuadPart) / static_cast<double>(g_qpcFreq.QuadPart);
    ++g_frameCounter;
    if (const Frame* built = g_current.load(std::memory_order_relaxed)) {
        ++g_builtFrames;
        if (built->coversView) ++g_coveredFrames;
    }
    LogStats(now);
}

uintptr_t HookNewUpdate(uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6, uintptr_t a7,
                        uintptr_t a8) {
    OnFrame(a1);
    return g_origNewUpdate(a1, a2, a3, a4, a5, a6, a7, a8);
}

// Box faces as triangles; corner index bit 0 = x (min/max), bit 1 = y, bit 2 = z.
constexpr unsigned int kBoxTriangles[36] = {
    0, 1, 3, 0, 3, 2,  // z min
    4, 6, 7, 4, 7, 5,  // z max
    0, 4, 5, 0, 5, 1,  // y min
    2, 3, 7, 2, 7, 6,  // y max
    0, 2, 6, 0, 6, 4,  // x min
    1, 5, 7, 1, 7, 3,  // x max
};

// True when the box is certainly hidden behind the rasterized terrain.
bool IsOccluded(const Frame& f, const float* box) {
    float clip[8 * 4];
    float xmin = 1e30f, ymin = 1e30f, xmax = -1e30f, ymax = -1e30f, wmin = 1e30f;
    for (int corner = 0; corner < 8; ++corner) {
        const Vec3 d = {box[(corner & 1) ? 3 : 0] - f.eye.x, box[(corner & 2) ? 4 : 1] - f.eye.y,
                        box[(corner & 4) ? 5 : 2] - f.eye.z};
        const float w = Dot(d, f.forward);
        if (!(w > kNearW)) return false;  // touches or crosses the near plane (or NaN): treat as visible
        float* c = &clip[corner * 4];
        c[0] = Dot(d, f.right) * f.sx;
        c[1] = Dot(d, f.up) * f.sy;
        c[2] = 0.0f;
        c[3] = w;
        const float x = c[0] / w, y = c[1] / w;
        if (x < xmin) xmin = x;
        if (x > xmax) xmax = x;
        if (y < ymin) ymin = y;
        if (y > ymax) ymax = y;
        if (w < wmin) wmin = w;
    }
    // Outside our buffer: not our call - the engine's own frustum test already accepted it.
    if (xmax < -1.0f || xmin > 1.0f || ymax < -1.0f || ymin > 1.0f) return false;
    // Partly outside the buffer. If the buffer is verified to contain the game's whole view, the part that
    // sticks out is off-screen in the game too and only the in-buffer part matters; otherwise the
    // off-buffer part can't be proven hidden.
    if (xmin < -1.0f || xmax > 1.0f || ymin < -1.0f || ymax > 1.0f) {
        if (!f.coversView) return false;
        if (xmin < -1.0f) xmin = -1.0f;
        if (ymin < -1.0f) ymin = -1.0f;
        if (xmax > 1.0f) xmax = 1.0f;
        if (ymax > 1.0f) ymax = 1.0f;
    }

    // Stage 1: screen rectangle at the nearest depth - cheap, and enough for most boxes behind a hill.
    if (f.moc->TestRect(xmin, ymin, xmax, ymax, wmin) == MaskedOcclusionCulling::OCCLUDED) return true;
    // Stage 2: the box's real faces, depth-tested per pixel. Needed when the occluder is at a grazing
    // angle (e.g. the ground seen from inside a tunnel), where one depth for the whole rectangle is too crude.
    return f.moc->TestTriangles(clip, kBoxTriangles, 12, nullptr, MaskedOcclusionCulling::BACKFACE_NONE,
                                MaskedOcclusionCulling::CLIP_PLANE_ALL,
                                MaskedOcclusionCulling::VertexLayout(16, 4, 12)) == MaskedOcclusionCulling::OCCLUDED;
}

uint64_t HookFrustumTest(const float* box, const void* planes) {
    const uint64_t result = g_origFrustumTest(box, planes);
    if ((result & 0xff) == 0) return result;
    const Frame* frame = g_current.load(std::memory_order_acquire);
    if (frame == nullptr || planes != g_cameraPlanes.load(std::memory_order_relaxed)) return result;

    const auto caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
    int index = -1;
    for (int i = 0; i < g_callerCount; ++i) {
        if (caller >= g_callers[i].begin && caller < g_callers[i].end) {
            index = i;
            break;
        }
    }
    if (index < 0) {
        g_otherCameraTests.fetch_add(1, std::memory_order_relaxed);
        return result;
    }

    g_callerTests[index].fetch_add(1, std::memory_order_relaxed);
    if (!IsOccluded(*frame, box)) return result;
    g_callerCulled[index].fetch_add(1, std::memory_order_relaxed);
    return result & ~static_cast<uint64_t>(0xff);
}

// Self-test on synthetic terrain (tf3api.ini [Occlusion] SelfTest=1): flat ground at z=0 with a 200 m high
// ridge across the view 1 km ahead. Checks the projection conventions and the conservative tests end to end
// without the game: a box behind the ridge must be culled; boxes in front of it, above it, and off to the
// side past the ridge's end must not be.
bool SelfTest() {
    const int n = g_gridN;
    const float s = g_settings.gridSpacing;
    const int half = g_settings.gridCells / 2;
    g_originX = -half;
    g_originY = -half;
    for (int iy = 0; iy < n; ++iy) {
        for (int ix = 0; ix < n; ++ix) {
            const float x = static_cast<float>(g_originX + ix) * s, y = static_cast<float>(g_originY + iy) * s;
            // Ridge: x in [900, 1100], y in [-1500, 500] (it ends at y = 500 so one side stays open).
            const bool ridge = x >= 900.0f && x <= 1100.0f && y >= -1500.0f && y <= 500.0f;
            g_heights[static_cast<size_t>(iy) * n + ix] = ridge ? 200.0f : 0.0f;
        }
    }

    CameraState cs{};
    cs.eye = {0.0f, 0.0f, 10.0f};
    cs.target = {100.0f, 0.0f, 10.0f};
    cs.up = {0.0f, 0.0f, 1.0f};
    cs.fov = 1.0f;
    cs.viewW = 1920;
    cs.viewH = 1080;
    cs.assumeCovered = true;
    BuildFrame(cs, true);
    const Frame* frame = g_current.load();
    g_current.store(nullptr);
    if (frame == nullptr) {
        TF3_LOG("occlusion self-test: FAILED (no surface frame built)");
        return false;
    }

    struct Case {
        const char* name;
        float box[6];
        bool expectOccluded;
    };
    const Case cases[] = {
        {"house behind the ridge", {1500.0f, -20.0f, 0.0f, 1540.0f, 20.0f, 30.0f}, true},
        {"house in front of the ridge", {500.0f, -20.0f, 0.0f, 540.0f, 20.0f, 30.0f}, false},
        {"tower behind the ridge, taller than it", {1500.0f, -20.0f, 0.0f, 1540.0f, 20.0f, 600.0f}, false},
        {"house behind the ridge line but past its end", {1500.0f, 1200.0f, 0.0f, 1540.0f, 1240.0f, 30.0f}, false},
        {"box around the camera", {-5.0f, -5.0f, 5.0f, 5.0f, 5.0f, 15.0f}, false},
        {"box behind the camera", {-600.0f, -20.0f, 0.0f, -560.0f, 20.0f, 30.0f}, false},
    };
    bool ok = true;
    for (const Case& c : cases) {
        const bool occluded = IsOccluded(*frame, c.box);
        const bool pass = occluded == c.expectOccluded;
        ok = ok && pass;
        TF3_LOG("occlusion self-test: %-46s %s (%s)", c.name, pass ? "ok" : "WRONG", occluded ? "culled" : "kept");
    }

    // Underground: the eye is 100 m below flat ground, looking along a tunnel. Things on the surface are
    // behind the ground seen from below (the terrain is rasterized double-sided); things down in the tunnel
    // are not.
    for (float& h : g_heights) h = 0.0f;
    cs.eye = {0.0f, 0.0f, -100.0f};
    cs.target = {100.0f, 0.0f, -100.0f};
    BuildFrame(cs, true);
    frame = g_current.load();
    g_current.store(nullptr);
    if (frame == nullptr) {
        TF3_LOG("occlusion self-test: FAILED (no underground frame built)");
        return false;
    }
    const Case underground[] = {
        {"underground: house on the surface ahead", {300.0f, -20.0f, 0.0f, 340.0f, 20.0f, 30.0f}, true},
        {"underground: city block on the surface", {150.0f, -100.0f, 0.0f, 350.0f, 100.0f, 40.0f}, true},
        {"underground: train further down the tunnel", {400.0f, -3.0f, -104.0f, 430.0f, 3.0f, -98.0f}, false},
        {"underground: station box below the surface", {600.0f, -40.0f, -110.0f, 700.0f, 40.0f, -60.0f}, false},
    };
    for (const Case& c : underground) {
        const bool occluded = IsOccluded(*frame, c.box);
        const bool pass = occluded == c.expectOccluded;
        ok = ok && pass;
        TF3_LOG("occlusion self-test: %-46s %s (%s)", c.name, pass ? "ok" : "WRONG", occluded ? "culled" : "kept");
    }

    TF3_LOG("occlusion self-test: %s", ok ? "PASSED" : "FAILED");
    g_cacheValid = false;  // the synthetic heights must not survive into real use
    return ok;
}

bool ResolveCallers() {
    g_callerCount = 0;
    for (const CallerSig& sig : kAllowedCallers) {
        const uintptr_t begin = sigscan::FindUniqueOrByTexts(sig.name, sig.pattern, sig.text ? &sig.text : nullptr, sig.text ? 1 : 0);
        if (begin == 0) continue;
        DWORD64 imageBase = 0;
        const RUNTIME_FUNCTION* entry = RtlLookupFunctionEntry(begin, &imageBase, nullptr);
        if (entry == nullptr || imageBase + entry->BeginAddress != begin) {
            TF3_LOG("occlusion: no unwind entry for caller '%s' - skipped", sig.name);
            continue;
        }
        g_callerNames[g_callerCount] = sig.name;
        g_callers[g_callerCount++] = {begin, static_cast<uintptr_t>(imageBase + entry->EndAddress)};
    }
    return g_callerCount > 0;
}

} // namespace

CameraWindow TakeCameraWindow() {
    std::lock_guard<std::mutex> lock(g_cameraMutex);
    CameraAccumulator& c = g_cameraStats;
    CameraWindow w;
    w.frames = c.frames;
    if (c.frames > 0) {
        w.heightAvg = static_cast<float>(c.heightSum / static_cast<double>(c.frames));
        w.heightMin = c.heightMin;
        w.heightMax = c.heightMax;
        w.travelled = static_cast<float>(c.travelled);
        w.fovDegrees = static_cast<float>(c.fovSum / static_cast<double>(c.frames) * 57.29577951);
    }
    c.frames = 0;
    c.heightSum = c.travelled = c.fovSum = 0;
    return w;
}

bool LatestCamera(CameraView* out) {
    std::lock_guard<std::mutex> lock(g_viewMutex);
    if (!g_haveView) return false;
    *out = g_view;
    return true;
}

void Install() {
    if (!config::GetBool("Occlusion", "Enabled", false)) return;

    g_settings.terrainMargin = config::GetFloat("Occlusion", "TerrainMargin", 15.0f);
    g_settings.minDistance = config::GetFloat("Occlusion", "MinDistance", 30.0f);
    g_settings.gridSpacing = config::GetFloat("Occlusion", "GridSpacing", 80.0f);
    g_settings.gridCells = config::GetInt("Occlusion", "GridCells", 96);
    g_settings.toggleKey = config::GetInt("Occlusion", "ToggleKey", VK_F10);
    g_settings.benchKey = config::GetInt("Occlusion", "BenchKey", VK_F9);
    g_settings.logStats = config::GetBool("Occlusion", "LogStats", true);
    if (!(g_settings.gridSpacing >= 8.0f && g_settings.gridSpacing <= 1024.0f)) g_settings.gridSpacing = 80.0f;
    if (g_settings.gridCells < 16 || g_settings.gridCells > 256) g_settings.gridCells = 96;
    if (!(g_settings.terrainMargin >= 0.0f && g_settings.terrainMargin <= 500.0f)) g_settings.terrainMargin = 15.0f;
    if (!(g_settings.minDistance >= 0.0f && g_settings.minDistance <= 2000.0f)) g_settings.minDistance = 30.0f;

    g_gridN = g_settings.gridCells + 1;
    const size_t verts = static_cast<size_t>(g_gridN) * g_gridN;
    g_heights.assign(verts, 0.0f);
    g_clipVerts.assign(verts * 4, 0.0f);
    g_vertNear.assign(verts, 0);
    g_indices.assign(static_cast<size_t>(g_settings.gridCells) * g_settings.gridCells * 6, 0);

    for (Frame& frame : g_frames) {
        frame.moc = MaskedOcclusionCulling::Create();
        if (frame.moc == nullptr) {
            TF3_LOG("occlusion: not installed (could not create the occlusion buffer)");
            return;
        }
        frame.moc->SetResolution(kBufferWidth, kBufferHeight);
        frame.moc->SetNearClipPlane(kNearW);
        frame.moc->ClearBuffer();
    }
    // Enabled installs the hooks (the camera they read is also what the road names are drawn with); Cull says
    // whether hidden things are actually skipped. Culling gained nothing measurable, so it can stay off while the
    // camera keeps being published.
    g_runtimeEnabled.store(config::GetBool("Occlusion", "Cull", true));
    QueryPerformanceFrequency(&g_qpcFreq);
    g_lastStatsTick = GetTickCount64();

    if (config::GetBool("Occlusion", "SelfTest", false) && !SelfTest()) {
        TF3_LOG("occlusion: not installed (self-test failed)");
        return;
    }

    const char* const newUpdateText = kTextNewUpdate;
    const uintptr_t newUpdate = sigscan::FindUniqueOrByTexts("CRenderer::NewUpdate", kSigNewUpdate, &newUpdateText, 1);
    const uintptr_t frustumTest = sigscan::FindUnique("frustum test", kSigFrustumTest);
    const uintptr_t terrainHeight = sigscan::FindUnique("terrain height", kSigTerrainHeight);
    if (newUpdate == 0 || frustumTest == 0 || terrainHeight == 0 || !ResolveCallers()) {
        TF3_LOG("occlusion: not installed (signatures missing - different game build?)");
        return;
    }
    g_terrainHeight = reinterpret_cast<TerrainHeightFn>(terrainHeight);

    g_targetNewUpdate = reinterpret_cast<void*>(newUpdate);
    g_targetFrustumTest = reinterpret_cast<void*>(frustumTest);
    const char* step = "create NewUpdate hook";
    MH_STATUS status = MH_CreateHook(g_targetNewUpdate, reinterpret_cast<void*>(&HookNewUpdate),
                                     reinterpret_cast<void**>(&g_origNewUpdate));
    if (status == MH_OK) {
        step = "create frustum-test hook";
        status = MH_CreateHook(g_targetFrustumTest, reinterpret_cast<void*>(&HookFrustumTest),
                               reinterpret_cast<void**>(&g_origFrustumTest));
    }
    if (status == MH_OK) {
        step = "enable frustum-test hook";
        status = MH_EnableHook(g_targetFrustumTest);
    }
    if (status == MH_OK) {
        step = "enable NewUpdate hook";
        status = MH_EnableHook(g_targetNewUpdate);
    }
    if (status != MH_OK) {
        TF3_LOG("occlusion: hook install failed at '%s': %s", step, MH_StatusToString(status));
        MH_RemoveHook(g_targetNewUpdate);
        MH_RemoveHook(g_targetFrustumTest);
        g_targetNewUpdate = g_targetFrustumTest = nullptr;
        return;
    }

    const char* simd = "SSE2";
    switch (g_frames[0].moc->GetImplementation()) {
    case MaskedOcclusionCulling::AVX512: simd = "AVX-512"; break;
    case MaskedOcclusionCulling::AVX2: simd = "AVX2"; break;
    case MaskedOcclusionCulling::SSE41: simd = "SSE4.1"; break;
    default: break;
    }
    TF3_LOG("occlusion: active (%s, %ux%u buffer, grid %dx%d @ %.0f m, margin %.0f m, min distance %.0f m, %d callers)",
            simd, kBufferWidth, kBufferHeight, g_settings.gridCells, g_settings.gridCells, g_settings.gridSpacing,
            g_settings.terrainMargin, g_settings.minDistance, g_callerCount);
}

void Uninstall() {
    g_current.store(nullptr, std::memory_order_release);
    if (g_targetNewUpdate) {
        MH_DisableHook(g_targetNewUpdate);
        MH_RemoveHook(g_targetNewUpdate);
        g_targetNewUpdate = nullptr;
    }
    if (g_targetFrustumTest) {
        MH_DisableHook(g_targetFrustumTest);
        MH_RemoveHook(g_targetFrustumTest);
        g_targetFrustumTest = nullptr;
    }
    // The occlusion buffers are intentionally not destroyed: a worker thread may still be inside a test
    // during process teardown, and the process is exiting anyway.
}

} // namespace tf3api::occlusion
