#include "lua_bridge.h"

#include "lua_worker.h"
#include "boards.h"
#include "placement.h"
#include "plan_view.h"
#include "road_labels.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <string>

#include "MinHook.h"

namespace tf3api::lua_bridge {
namespace {

constexpr double kApiVersion = 19.0;   // 19: modOrigin / modProblem, and the "API" badge in the mod list
                                       // 18: the middle-button height queue "tf3api_placement.height"
constexpr size_t kMaxFileBytes = 256u * 1024u * 1024u;
constexpr int kMaxScriptLogLines = 2000;  // per session, then one notice and silence

struct lua_State;
using lua_CFunction = int (*)(lua_State*);
using lua_Reader = const char* (*)(lua_State*, void* data, size_t* size);

// ---- The game's own Lua 5.2.2 API, located by signature (build 40408 addresses in lua_vm.md) -----------

struct Api {
    lua_CFunction luaopen_base = nullptr;
    void (*createtable)(lua_State*, int narr, int nrec) = nullptr;
    int (*gettop)(lua_State*) = nullptr;
    void (*settop)(lua_State*, int index) = nullptr;
    void (*pushboolean)(lua_State*, int value) = nullptr;
    void (*pushcclosure)(lua_State*, lua_CFunction fn, int upvalues) = nullptr;
    const char* (*pushlstring)(lua_State*, const char* text, size_t length) = nullptr;
    void (*pushnumber)(lua_State*, double value) = nullptr;
    void (*setfield)(lua_State*, int index, const char* key) = nullptr;
    void (*setglobal)(lua_State*, const char* name) = nullptr;
    const char* (*tolstring)(lua_State*, int index, size_t* length) = nullptr;
    int (*type)(lua_State*, int index) = nullptr;
    // for the mod list's "API" badge (optional: without them there is no badge)
    int (*load)(lua_State*, lua_Reader, void* data, const char* chunkName, const char* mode) = nullptr;
    int (*pcallk)(lua_State*, int nargs, int nresults, int errfunc, int ctx, lua_CFunction k) = nullptr;
};
Api lua;

constexpr int kLuaTString = 4;  // lua_type() result for a string

struct Signature {
    const char* name;
    const char* pattern;
    void** target;
};

Signature kSignatures[] = {
    {"luaopen_base", "40 53 48 83 EC 20 BA D8 B9 F0 FF 41 B8 02 00 00 00", reinterpret_cast<void**>(&lua.luaopen_base)},
    {"lua_createtable", "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B 41 18 41 8B F8",
     reinterpret_cast<void**>(&lua.createtable)},
    {"lua_gettop", "48 8B 41 20 48 8B 51 10 48 2B 10 48 8D 42 F0 48 C1 F8 04", reinterpret_cast<void**>(&lua.gettop)},
    {"lua_settop", "85 D2 78 ?? 48 8B 41 20 4C 63 CA 49 FF C1 49 C1 E1 04", reinterpret_cast<void**>(&lua.settop)},
    {"lua_pushboolean", "4C 8B 41 10 33 C0 85 D2 0F 95 C0 41 89 00 41 C7 40 08 01 00 00 00",
     reinterpret_cast<void**>(&lua.pushboolean)},
    {"lua_pushcclosure", "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 49 63 F8",
     reinterpret_cast<void**>(&lua.pushcclosure)},
    {"lua_pushlstring",
     "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B 41 18 49 8B F8 48 8B F2 48 8B D9 48 83 78 18 00 7E ?? E8 ?? ?? ?? "
     "?? 4C 8B C7 48 8B D6 48 8B CB E8 ?? ?? ?? ??",
     reinterpret_cast<void**>(&lua.pushlstring)},
    {"lua_pushnumber", "48 8B 41 10 C5 FB 11 08 C7 40 08 03 00 00 00 48 83 41 10 10",
     reinterpret_cast<void**>(&lua.pushnumber)},
    {"lua_setfield", "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 4D 8B D0 48 8B F1 E8 ?? ?? ?? ?? 48 8B 5E 10 48 8B CE",
     reinterpret_cast<void**>(&lua.setfield)},
    {"lua_setglobal",
     "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 48 8B 41 18 48 8B FA 48 8B E9 BA 02 00 00 00 48 8B 48 40 "
     "E8 ?? ?? ?? ?? 48 8B 5D 10 48 8B D7 48 8B CD 48 8B F0 4C 8D 43 10 4C 89 45 10 E8 ?? ?? ?? ?? 48 89 03 48 8B D6 0F B6 "
     "48 08 83 C9 40 89 4B 08 48 8B CD 4C 8B 45 10 4D 8D 48 E0",
     reinterpret_cast<void**>(&lua.setglobal)},
    {"lua_tolstring", "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 49 8B D8 8B F2 48 8B F9 E8 ?? ?? ?? ??",
     reinterpret_cast<void**>(&lua.tolstring)},
    {"lua_type", "48 83 EC 28 E8 ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ?? 48 3B C1 74 ?? 8B 40 08 83 E0 0F 48 83 C4 28",
     reinterpret_cast<void**>(&lua.type)},
};

// Found like the others, but only the badge needs them: when one is missing the bridge still works.
Signature kOptionalSignatures[] = {
    {"lua_load", "48 89 5C 24 10 56 48 83 EC 50 49 8B D9 48 8B F1", reinterpret_cast<void**>(&lua.load)},
    {"lua_pcallk", "48 89 74 24 18 57 48 83 EC 40 33 F6 48 89 6C 24 58", reinterpret_cast<void**>(&lua.pcallk)},
};

lua_CFunction g_originalOpenBase = nullptr;
void* g_hookTarget = nullptr;
std::atomic<int> g_statesSeen{0};
std::atomic<int> g_scriptLogLines{0};

// ---- Helpers -------------------------------------------------------------------------------------------

int ReturnOk(lua_State* L) {
    lua.pushboolean(L, 1);
    return 1;
}

int ReturnFailure(lua_State* L, const char* reason) {
    lua.pushboolean(L, 0);
    lua.pushlstring(L, reason, std::strlen(reason));
    return 2;
}

// Argument `index` as a string, or nullptr when it is not one. (Numbers are not accepted: lua_tolstring would
// convert the value in place, which is surprising for the caller.)
const char* StringArg(lua_State* L, int index, size_t* length) {
    if (lua.gettop(L) < index || lua.type(L, index) != kLuaTString) return nullptr;
    return lua.tolstring(L, index, length);
}

std::wstring OutputDir() {
    wchar_t exePath[MAX_PATH] = {};
    const DWORD len = GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring path(exePath, len);
    const size_t slash = path.find_last_of(L"\\/");
    if (slash != std::wstring::npos) path.resize(slash + 1);
    return path + L"tf3api_out";
}

// A plain file name: letters, digits, '.', '_', '-'; one of the allowed extensions; nothing that could
// leave the output folder or produce something Windows would run.
bool SafeFileName(const char* name, size_t length) {
    if (length == 0 || length > 80 || name[0] == '.') return false;
    for (size_t i = 0; i < length; ++i) {
        const char c = name[i];
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) return false;
        if (c == '.' && i + 1 < length && name[i + 1] == '.') return false;
    }
    static const char* const kExtensions[] = {".html", ".svg", ".json", ".geojson", ".osm", ".txt", ".csv", ".lua", ".md"};
    for (const char* extension : kExtensions) {
        const size_t n = std::strlen(extension);
        if (length > n && _strnicmp(name + length - n, extension, n) == 0) return true;
    }
    return false;
}

// ---- Functions exposed to scripts ------------------------------------------------------------------------

int Script_log(lua_State* L) {
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    if (text == nullptr) return ReturnFailure(L, "log(text): text must be a string");
    const int line = g_scriptLogLines.fetch_add(1, std::memory_order_relaxed);
    if (line < kMaxScriptLogLines) {
        TF3_LOG("[script] %.1500s", text);
    } else if (line == kMaxScriptLogLines) {
        TF3_LOG("[script] log limit of %d lines reached - further script log lines are dropped this session", kMaxScriptLogLines);
    }
    return ReturnOk(L);
}

int Script_writeFile(lua_State* L) {
    size_t nameLength = 0, textLength = 0;
    const char* name = StringArg(L, 1, &nameLength);
    const char* text = StringArg(L, 2, &textLength);
    if (name == nullptr || text == nullptr) return ReturnFailure(L, "writeFile(name, text): both must be strings");
    if (!SafeFileName(name, nameLength)) {
        return ReturnFailure(L, "writeFile: name must be a plain file name (letters, digits, . _ -) ending in "
                                ".html .svg .json .geojson .osm .txt .csv .lua or .md");
    }
    if (textLength > kMaxFileBytes) return ReturnFailure(L, "writeFile: text is larger than 256 MB");

    const std::wstring dir = OutputDir();
    CreateDirectoryW(dir.c_str(), nullptr);
    std::wstring path = dir + L"\\";
    for (size_t i = 0; i < nameLength; ++i) path.push_back(static_cast<wchar_t>(name[i]));

    // Written to a temporary name first, so a half-written file never replaces a good one.
    const std::wstring temporary = path + L".part";
    FILE* file = nullptr;
    if (_wfopen_s(&file, temporary.c_str(), L"wb") != 0 || file == nullptr) return ReturnFailure(L, "writeFile: could not create the file");
    const size_t written = textLength ? fwrite(text, 1, textLength, file) : 0;
    const bool closed = fclose(file) == 0;
    if (written != textLength || !closed) {
        DeleteFileW(temporary.c_str());
        return ReturnFailure(L, "writeFile: write failed (disk full?)");
    }
    if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(temporary.c_str());
        return ReturnFailure(L, "writeFile: could not replace the existing file (is it open in another program?)");
    }
    TF3_LOG("bridge: wrote tf3api_out\\%.80s (%zu bytes)", name, textLength);
    return ReturnOk(L);
}

// boardLines(line1, line2, line3): the text of the departure boards' three lines (each centred; a missing or
// non-text argument is an empty line). Returns true when the picture changes, false when it was the same.
int Script_boardLines(lua_State* L) {
    const char* lines[boards::kTextLines] = {};
    for (int i = 0; i < boards::kTextLines; ++i) {
        size_t length = 0;
        lines[i] = StringArg(L, i + 1, &length);
    }
    lua.pushboolean(L, boards::SetLines(lines, boards::kTextLines) ? 1 : 0);
    return 1;
}

// boardText(screen, line1, line2, line3): the three lines of one of the departure boards' screens. `screen`
// is its number from 0, GIVEN AS TEXT. A line without a tab is centred; a line "time<tab>destination<tab>
// platform<tab>expected" is laid out as a departure. Returns true when the picture changes.
int Script_boardText(lua_State* L) {
    int slot = -1;
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    if (text != nullptr && length > 0 && length < 6) {
        char* end = nullptr;
        const long value = strtol(text, &end, 10);
        if (end != text && value >= 0 && value < boards::kSlots) slot = static_cast<int>(value);
    }
    const char* lines[boards::kTextLines] = {};
    for (int i = 0; i < boards::kTextLines; ++i) lines[i] = StringArg(L, i + 2, &length);
    lua.pushboolean(L, (slot >= 0 && boards::SetSlotLines(slot, lines, boards::kTextLines)) ? 1 : 0);
    return 1;
}

// planView(entity, numbers): makes the game's small live view of an entity (the picture in its window) look
// straight down. `entity` is its number AS TEXT; `numbers` is "x y z height upX upY" as text: the point looked
// at, how far above it the camera stands, and the direction on the ground that points up the picture. An empty
// `numbers` gives the view back to the game. Returns true when it was taken, false when the feature is off,
// the numbers are not six, or eight entities are already set.
int Script_planView(lua_State* L) {
    size_t length = 0;
    const char* entityText = StringArg(L, 1, &length);
    int entity = -1;
    if (entityText != nullptr && length == 3 && std::memcmp(entityText, "any", 3) == 0) {
        entity = -2;   // every circling live view
    } else if (entityText != nullptr && length > 0 && length < 12) {
        char* end = nullptr;
        const long value = strtol(entityText, &end, 10);
        if (end != entityText && value >= 0) entity = static_cast<int>(value);
    }
    const char* numbers = StringArg(L, 2, &length);
    bool ok = false;
    if ((entity >= 0 || entity == -2) && plan_view::Available()) {
        if (numbers == nullptr || length == 0) {
            plan_view::Clear(entity);
            ok = true;
        } else if (length < 200) {
            float v[6];
            int count = 0;
            const char* p = numbers;
            while (count < 6) {
                char* end = nullptr;
                const double value = strtod(p, &end);
                if (end == p) break;
                v[count++] = static_cast<float>(value);
                p = end;
            }
            if (count == 6) ok = plan_view::Set(entity, v[0], v[1], v[2], v[3], v[4], v[5]);
        }
    }
    lua.pushboolean(L, ok ? 1 : 0);
    return 1;
}

// placementMode(on): tells the native layer whether the game's own "Drag-and-Confirm Construction Mode" is on
// ("1") or off (anything else), which a script can read from the game's settings and the native layer cannot.
// Objects are placed in two steps only while it is on. Returns the state: 0 off or unavailable, 1 on,
// 2 an object is pinned.
int Script_placementMode(lua_State* L) {
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    placement::SetGameOption(text != nullptr && length == 1 && text[0] == '1');
    lua.pushnumber(L, static_cast<double>(placement::State()));
    return 1;
}

// boardRows(screen, row1 .. row5): a screen laid out by the script. `screen` is its number from 0, GIVEN AS
// TEXT. A row is fields separated by tabs; a field may begin with "<N " (left edge at column N) or ">N "
// (right edge at column N), otherwise it is centred; the character with code 1 stands for the running
// clock. Returns true when the picture changes.
int Script_boardRows(lua_State* L) {
    int slot = -1;
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    if (text != nullptr && length > 0 && length < 6) {
        char* end = nullptr;
        const long value = strtol(text, &end, 10);
        if (end != text && value >= 0 && value < boards::kSlots) slot = static_cast<int>(value);
    }
    const char* rows[boards::kRowLines] = {};
    for (int i = 0; i < boards::kRowLines; ++i) rows[i] = StringArg(L, i + 2, &length);
    lua.pushboolean(L, (slot >= 0 && boards::SetSlotRows(slot, rows, boards::kRowLines)) ? 1 : 0);
    return 1;
}

// boardColour(screen, colour): the colour of a screen's lit dots, "r g b" (0-255 each) AS TEXT; the dark
// dots are a dim shade of it. Anything unreadable is the boards' amber. Returns true when it changes.
int Script_boardColour(lua_State* L) {
    int slot = -1;
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    if (text != nullptr && length > 0 && length < 6) {
        char* end = nullptr;
        const long value = strtol(text, &end, 10);
        if (end != text && value >= 0 && value < boards::kSlots) slot = static_cast<int>(value);
    }
    int r = 255, g = 150, b = 24;
    const char* colour = StringArg(L, 2, &length);
    if (colour != nullptr && length > 0 && length < 32) {
        int cr = -1, cg = -1, cb = -1;
        char buffer[32] = {};
        std::memcpy(buffer, colour, length);
        char* p = buffer;
        char* end = nullptr;
        cr = static_cast<int>(strtol(p, &end, 10));
        if (end != p) { p = end; cg = static_cast<int>(strtol(p, &end, 10)); }
        if (end != p) { p = end; cb = static_cast<int>(strtol(p, &end, 10)); }
        if (end != p && cr >= 0 && cr <= 255 && cg >= 0 && cg <= 255 && cb >= 0 && cb <= 255) {
            r = cr;
            g = cg;
            b = cb;
        }
    }
    lua.pushboolean(L, (slot >= 0 && boards::SetSlotColour(slot, static_cast<uint8_t>(r), static_cast<uint8_t>(g), static_cast<uint8_t>(b))) ? 1 : 0);
    return 1;
}

// stationPlan(text): the station drawn in a board's window (scene lines, see plan_picture.h); empty clears it.
// Returns true when there is something to draw.
int Script_stationPlan(lua_State* L) {
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    std::string copy = text != nullptr ? std::string(text, (std::min)(length, static_cast<size_t>(4 * 1024 * 1024))) : std::string();
    lua.pushboolean(L, boards::SetPlanScene(copy.c_str()) ? 1 : 0);
    return 1;
}

// stationPlanView(text): "cx cy metresPerPoint" - where the main plan looks and how close, AS TEXT. Returns true when
// it changed.
int Script_stationPlanView(lua_State* L) {
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    double v[3] = {0, 0, 0};
    bool ok = false;
    if (text != nullptr && length > 0 && length < 96) {
        char buffer[96] = {};
        std::memcpy(buffer, text, length);
        char* p = buffer;
        ok = true;
        for (double& value : v) {
            char* end = nullptr;
            value = strtod(p, &end);
            if (end == p) ok = false;
            p = end;
        }
    }
    lua.pushboolean(L, (ok && boards::SetPlanView(v[0], v[1], v[2])) ? 1 : 0);
    return 1;
}

// stationPlanSeen(): whether the window's plan pictures are being drawn into (false: show a stand-in).
int Script_stationPlanSeen(lua_State* L) {
    lua.pushboolean(L, boards::PlanSeen() ? 1 : 0);
    return 1;
}

// boardClock(seconds): the boards' clock, in seconds since midnight of the game's day, GIVEN AS TEXT
// (tostring(seconds)); anything else shows "--:--:--". Returns true when the picture changes.
int Script_boardClock(lua_State* L) {
    int seconds = -1;
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);   // as text: the bridge reads no numbers from the game's Lua
    if (text != nullptr && length > 0 && length < 12) {
        char* end = nullptr;
        const long value = strtol(text, &end, 10);
        if (end != text && value >= 0) seconds = static_cast<int>(value);
    }
    lua.pushboolean(L, boards::SetClock(seconds) ? 1 : 0);
    return 1;
}

// boardsSeen(): how many board screen textures of the game are being written to (0: none is loaded).
int Script_boardsSeen(lua_State* L) {
    lua.pushnumber(L, static_cast<double>(boards::ImagesSeen()));
    return 1;
}

int Script_setRoadLabels(lua_State* L) {
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    if (text == nullptr) return ReturnFailure(L, "setRoadLabels(text): text must be a string");
    if (length > kMaxFileBytes) return ReturnFailure(L, "setRoadLabels: text is larger than 256 MB");
    lua.pushnumber(L, static_cast<double>(road_labels::SetData(text, length)));
    return 1;
}

// boardSpots(text): places that can be clicked although the game does not let them be, one per line
// "id x y z radius" (id an entity number; world metres). Returns how many were taken.
int Script_boardSpots(lua_State* L) {
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    const int count = (text != nullptr && length < 64 * 1024) ? road_labels::SetSpots(text, length) : 0;
    lua.pushnumber(L, static_cast<double>(count));
    return 1;
}

// boardClicks(on): "1" = a click on a clickable spot is kept from the game (the spot wins over what stands
// behind it); anything else = the game gets it too. A script says "1" only while the player is just looking
// round: not with a tool in hand, and not with a window of its own over the view.
int Script_boardClicks(lua_State* L) {
    size_t length = 0;
    const char* text = StringArg(L, 1, &length);
    road_labels::SetSpotsOwnClicks(text != nullptr && length == 1 && text[0] == '1');
    lua.pushboolean(L, 1);
    return 1;
}

// takeBoardClick() -> the id of the spot clicked (as text), or false.
int Script_takeBoardClick(lua_State* L) {
    long long id = 0;
    if (!road_labels::TakeSpotClick(&id)) {
        lua.pushboolean(L, 0);
        return 1;
    }
    char text[24];
    snprintf(text, sizeof(text), "%lld", id);
    lua.pushlstring(L, text, std::strlen(text));
    return 1;
}

// takeRoadClick() -> id, name, number, class, length in metres, segment count, flags, x, y; or false when no road label
// has been clicked since the last call.
int Script_takeRoadClick(lua_State* L) {
    road_labels::Click click;
    if (!road_labels::TakeClick(&click)) {
        lua.pushboolean(L, 0);
        return 1;
    }
    lua.pushnumber(L, static_cast<double>(click.id));
    lua.pushlstring(L, click.name, std::strlen(click.name));
    lua.pushlstring(L, click.ref, std::strlen(click.ref));
    lua.pushnumber(L, static_cast<double>(click.cls));
    lua.pushnumber(L, static_cast<double>(click.length));
    lua.pushnumber(L, static_cast<double>(click.segments));
    lua.pushlstring(L, click.flags, std::strlen(click.flags));
    lua.pushnumber(L, static_cast<double>(click.x));
    lua.pushnumber(L, static_cast<double>(click.y));
    lua.pushlstring(L, click.info, std::strlen(click.info));
    return 10;
}

// ---- Messages between script states -------------------------------------------------------------------------
// The game runs a mod's scripts in several Lua states that share nothing (the interface, the game script's
// interface side, the simulation threads). post() and take() are named queues held here, so one state can
// leave a message for another. Text only; nothing is interpreted.
constexpr size_t kMaxChannelName = 48, kMaxMessageBytes = 256 * 1024, kMaxQueued = 512;
std::mutex g_channelMutex;
std::map<std::string, std::deque<std::string>> g_channels;

bool ChannelName(const char* name, size_t length) {
    if (name == nullptr || length == 0 || length > kMaxChannelName) return false;
    for (size_t i = 0; i < length; ++i) {
        const char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')) return false;
    }
    return true;
}

// post(channel, text) -> true, or false plus a reason. When a queue is full the oldest message is dropped.
int Script_post(lua_State* L) {
    size_t nameLength = 0, textLength = 0;
    const char* name = StringArg(L, 1, &nameLength);
    const char* text = StringArg(L, 2, &textLength);
    if (name == nullptr || text == nullptr) return ReturnFailure(L, "post(channel, text): both must be strings");
    if (!ChannelName(name, nameLength)) return ReturnFailure(L, "post: channel names are letters, digits, . _ - (at most 48)");
    if (textLength > kMaxMessageBytes) return ReturnFailure(L, "post: text is larger than 256 KB");
    std::lock_guard<std::mutex> lock(g_channelMutex);
    std::deque<std::string>& queue = g_channels[std::string(name, nameLength)];
    if (queue.size() >= kMaxQueued) queue.pop_front();
    queue.emplace_back(text, textLength);
    return ReturnOk(L);
}

// take(channel) -> the oldest message on the channel, or false when there is none.
int Script_take(lua_State* L) {
    size_t nameLength = 0;
    const char* name = StringArg(L, 1, &nameLength);
    std::string message;
    bool have = false;
    if (ChannelName(name, nameLength)) {
        std::lock_guard<std::mutex> lock(g_channelMutex);
        const auto found = g_channels.find(std::string(name, nameLength));
        if (found != g_channels.end() && !found->second.empty()) {
            message = std::move(found->second.front());
            found->second.pop_front();
            have = true;
        }
    }
    if (!have) {
        lua.pushboolean(L, 0);
        return 1;
    }
    lua.pushlstring(L, message.data(), message.size());
    return 1;
}

// ---- The worker ---------------------------------------------------------------------------------------------
// workerStart(files) -> true, or false plus a reason. files: paths separated by newlines, relative to the game
// folder (.lua files under mods). Each is run once in the worker's own Lua state.
int Script_workerStart(lua_State* L) {
    size_t length = 0;
    const char* files = StringArg(L, 1, &length);
    if (files == nullptr) return ReturnFailure(L, "workerStart(files): files must be a string");
    std::string reason;
    if (!lua_worker::Start(std::string(files, length), &reason)) return ReturnFailure(L, reason.c_str());
    return ReturnOk(L);
}

// workerRun(input) -> the job's number, or false when the worker cannot take it now.
int Script_workerRun(lua_State* L) {
    size_t length = 0;
    const char* input = StringArg(L, 1, &length);
    const unsigned id = input != nullptr ? lua_worker::Run(input, length) : 0;
    if (id == 0) {
        lua.pushboolean(L, 0);
        return 1;
    }
    lua.pushnumber(L, static_cast<double>(id));
    return 1;
}

// workerTake() -> job number, true or false (did it succeed), text (its result, or the error); or false when
// no job has finished.
int Script_workerTake(lua_State* L) {
    unsigned id = 0;
    bool ok = false;
    std::string text;
    if (!lua_worker::Take(&id, &ok, &text)) {
        lua.pushboolean(L, 0);
        return 1;
    }
    lua.pushnumber(L, static_cast<double>(id));
    lua.pushboolean(L, ok ? 1 : 0);
    lua.pushlstring(L, text.data(), text.size());
    return 3;
}

// workerAvailable() -> whether this build of the game lets the DLL run a Lua state of its own.
int Script_workerAvailable(lua_State* L) {
    lua.pushboolean(L, lua_worker::Available() ? 1 : 0);
    return 1;
}

// legacySource(folder) -> whether the old mod with that folder name is in legacy_mods in the game's folder.
// A converted mod asks this about the mod it was made from: without the original beside the game, what the
// converted mod adds is not offered (see the mod converter).
int Script_legacySource(lua_State* L) {
    size_t length = 0;
    const char* name = StringArg(L, 1, &length);
    bool present = false;
    if (name != nullptr && length > 0 && length < 200) {
        bool plain = !(length == 1 && name[0] == '.') && !(length == 2 && name[0] == '.' && name[1] == '.');
        for (size_t i = 0; i < length; ++i) {
            const unsigned char c = static_cast<unsigned char>(name[i]);
            if (c < 32 || c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') plain = false;
        }
        wchar_t wide[256] = {};
        const int count = plain ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, name, static_cast<int>(length), wide, 255) : 0;
        if (count > 0) {
            std::wstring path = OutputDir();                    // <game folder>\tf3api_out
            path.resize(path.size() - (sizeof("tf3api_out") - 1));
            path += L"legacy_mods\\";
            path.append(wide, static_cast<size_t>(count));
            const DWORD attributes = GetFileAttributesW(path.c_str());
            present = attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        }
    }
    lua.pushboolean(L, present ? 1 : 0);
    return 1;
}

// ---- Which mods are TF3OpenAPI's ----------------------------------------------------------------------------
// TF3OpenAPI's own mods have ids starting "tf3api_"; converted mods are listed by the converter in
// legacy_mods\tf3api_converted.txt ("fingerprint <tab> mod id <tab> old mod's folder" a line), read once.

std::once_flag g_convertedOnce;
std::map<std::string, std::string> g_converted;   // mod id -> old mod's folder

std::wstring GameDir() {
    std::wstring path = OutputDir();   // <game folder>\tf3api_out
    path.resize(path.size() - (sizeof("tf3api_out") - 1));
    return path;
}

const std::map<std::string, std::string>& Converted() {
    std::call_once(g_convertedOnce, [] {
        FILE* file = nullptr;
        if (_wfopen_s(&file, (GameDir() + L"legacy_mods\\tf3api_converted.txt").c_str(), L"rb") != 0 || file == nullptr) return;
        char line[2048];
        while (std::fgets(line, sizeof(line), file) != nullptr) {
            std::string text(line);
            while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
            const size_t a = text.find('\t');
            const size_t b = a == std::string::npos ? a : text.find('\t', a + 1);
            if (b == std::string::npos) continue;
            g_converted[text.substr(a + 1, b - a - 1)] = text.substr(b + 1);
        }
        std::fclose(file);
    });
    return g_converted;
}

bool FolderPresent(const std::string& folder) {
    if (folder.empty() || folder.size() > 200 || folder.find_first_of("/\\:*?\"<>|") != std::string::npos || folder == "." || folder == "..") return false;
    wchar_t wide[256] = {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, folder.data(), static_cast<int>(folder.size()), wide, 255);
    if (count <= 0) return false;
    const std::wstring path = GameDir() + L"legacy_mods\\" + std::wstring(wide, static_cast<size_t>(count));
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

// tf3api.modOrigin(modId) -> "converted" (made by the converter), "api" (one of TF3OpenAPI's own), or nothing
int Script_modOrigin(lua_State* L) {
    size_t length = 0;
    const char* name = StringArg(L, 1, &length);
    if (name == nullptr || length == 0 || length > 200) return 0;
    const std::string id(name, length);
    if (Converted().count(id) > 0) {
        lua.pushlstring(L, "converted", 9);
        return 1;
    }
    if (id.rfind("tf3api_", 0) == 0) {
        lua.pushlstring(L, "api", 3);
        return 1;
    }
    return 0;
}

// tf3api.modProblem(modId) -> "source" when a converted mod's old mod is not in legacy_mods, else nothing
int Script_modProblem(lua_State* L) {
    size_t length = 0;
    const char* name = StringArg(L, 1, &length);
    if (name == nullptr || length == 0 || length > 200) return 0;
    const auto& converted = Converted();
    auto it = converted.find(std::string(name, length));
    if (it == converted.end() || FolderPresent(it->second)) return 0;
    lua.pushlstring(L, "source", 6);
    return 1;
}

struct Exposed {
    const char* name;
    lua_CFunction fn;
};
int Script_has(lua_State* L);
const Exposed kFunctions[] = {
    {"has", &Script_has},
    {"boardClicks", &Script_boardClicks},
    {"boardClock", &Script_boardClock},
    {"boardColour", &Script_boardColour},
    {"boardLines", &Script_boardLines},
    {"boardRows", &Script_boardRows},
    {"boardSpots", &Script_boardSpots},
    {"boardText", &Script_boardText},
    {"boardsSeen", &Script_boardsSeen},
    {"legacySource", &Script_legacySource},
    {"log", &Script_log},
    {"modOrigin", &Script_modOrigin},
    {"modProblem", &Script_modProblem},
    {"placementMode", &Script_placementMode},
    {"stationPlan", &Script_stationPlan},
    {"stationPlanSeen", &Script_stationPlanSeen},
    {"stationPlanView", &Script_stationPlanView},
    {"planView", &Script_planView},
    {"post", &Script_post},
    {"setRoadLabels", &Script_setRoadLabels},
    {"take", &Script_take},
    {"takeBoardClick", &Script_takeBoardClick},
    {"takeRoadClick", &Script_takeRoadClick},
    {"workerAvailable", &Script_workerAvailable},
    {"workerRun", &Script_workerRun},
    {"workerStart", &Script_workerStart},
    {"workerTake", &Script_workerTake},
    {"writeFile", &Script_writeFile},
};

int Script_has(lua_State* L) {
    size_t length = 0;
    const char* name = StringArg(L, 1, &length);
    int found = 0;
    if (name != nullptr) {
        for (const Exposed& f : kFunctions) {
            if (std::strlen(f.name) == length && std::memcmp(f.name, name, length) == 0) found = 1;
        }
    }
    lua.pushboolean(L, found);
    return 1;
}

// ---- Registration --------------------------------------------------------------------------------------

// Adds the tf3api table to a state. Leaves the Lua stack exactly as it found it.
void Register(lua_State* L) {
    const int top = lua.gettop(L);
    lua.createtable(L, 0, static_cast<int>(sizeof(kFunctions) / sizeof(kFunctions[0])) + 1);
    for (const Exposed& f : kFunctions) {
        lua.pushcclosure(L, f.fn, 0);
        lua.setfield(L, -2, f.name);
    }
    lua.pushnumber(L, kApiVersion);
    lua.setfield(L, -2, "version");
    lua.setglobal(L, "tf3api");
    lua.settop(L, top);
}

// The mod list's Source column (the game's recipe "TableCellModSource" in gui/menu/mod_selector_page.tl) shows
// an icon for where a mod comes from. For TF3OpenAPI's own mods and converted ones a small "API" badge is put
// under that icon. Nothing of the game's scripts is copied or replaced: this waits for the game's ug_require,
// and when the react module comes through it, wraps react.RegisterRecipe so that the recipe of that one cell is
// wrapped as it is registered. Any error inside leaves the cell as the game draws it.
// The mod list source icons and titles as a Lua table (32 x 32 RGBA hex each), generated by tools/make_notices.py
const char* const kIconPieces[] = {
#include "source_icon.inc"
};

const char kBadgeChunk[] = R"LUA(
-- everything used is taken into locals now: the game removes some globals (rawget ...) from its states later
local rawget, rawset, setmetatable, getmetatable = rawget, rawset, setmetatable, getmetatable
local type, tostring, tonumber, pairs, pcall = type, tostring, tonumber, pairs, pcall
local api = tf3api
if type(api) ~= "table" then return end
local G = _G
local MARK = "tf3api:source_icon:"
local SHOWN = 32   -- points an icon is drawn at, whatever its pixels
local said = {}
local function say(what)
	if said[what] then return end
	said[what] = true
	pcall(api.log, "source icon: " .. what)
end

-- an icon as the raw pixels the interface's ImageView takes
local pixelCache = {}
local function iconPixels(source)
	local pixels = pixelCache[source]
	if pixels == nil then
		pixels = {}
		for byte in ICONS[source].hex:gmatch("%x%x") do pixels[#pixels + 1] = tonumber(byte, 16) end
		pixelCache[source] = pixels
	end
	return pixels
end

-- 1) the mod list asks mod_manager_react_util.getSourceInfo(source) for the icon and title of a mod's source
--    (gui/menu/mod_manager_react_util.tl); the folder of our own mods has none in the game, so it is given a
--    title and a marker in place of a picture file
local function wrapSourceInfo(m)
	if type(m) ~= "table" or rawget(m, "tf3apiSourceWrapped") then return end
	local original = rawget(m, "getSourceInfo")
	if type(original) ~= "function" then return end
	rawset(m, "tf3apiSourceWrapped", true)
	rawset(m, "getSourceInfo", function(source)
		local own = ICONS[source]
		if own ~= nil then return { iconPath = MARK .. source, title = own.title } end
		return original(source)
	end)
	say("the mod list's source names are wrapped")
end

local function apiType()
	local a = rawget(G, "api")
	return a ~= nil and a.type or nil
end

-- 2) an ImageView asked for that marker gets the pixels instead of a path: they are in the DLL, so the icon
--    never depends on any mod's files being there
local function wrapImageView(builtin)
	if type(builtin) ~= "table" or rawget(builtin, "tf3apiImageWrapped") then return end
	local original = builtin.ImageView
	if original == nil then return end
	rawset(builtin, "tf3apiImageWrapped", true)
	local function fix(arg)
		if type(arg) ~= "table" or type(arg.path) ~= "string" or arg.path:sub(1, #MARK) ~= MARK then return arg end
		local source = arg.path:sub(#MARK + 1)
		if ICONS[source] == nil then return arg end
		local copy = {}
		for k, v in pairs(arg) do copy[k] = v end
		copy.path = nil
		copy.data = iconPixels(source)
		-- the picture keeps its full size; it is drawn SHOWN points wide (the size of the game's own source icons),
		-- by a fixed size in the style, so that the rows of the list do not stretch
		local okStyle, style = pcall(function()
			local styleutil = rawget(G, "ug_require")("::/gui/main/styleutil.tl")
			return styleutil.makeStyle { size = { SHOWN, SHOWN }, maxSize = { SHOWN, SHOWN } }
		end)
		if okStyle and style ~= nil then
			local meta = {}
			if type(arg.meta) == "table" then for k, v in pairs(arg.meta) do meta[k] = v end end
			meta.styleSheet = style
			copy.meta = meta
		else
			say("the icon's size could not be set: " .. tostring(style))
		end
		local okScale, scaling = pcall(function() return builtin.type.ImageViewScaling.AutoFit end)
		if okScale and scaling ~= nil then copy.scaling = scaling end
		local ok, size = pcall(function() return apiType().Vec2i.new(ICONS[source].size, ICONS[source].size) end)
		if ok then copy.size = size end
		say("the source icon is handed over as pixels")
		return copy
	end
	rawset(builtin, "ImageView", setmetatable({}, {
		__call = function(_, a, b, c, d) return original(fix(a), fix(b), fix(c), fix(d)) end,
		__index = function(_, k) return original[k] end,
	}))
	say("ImageView is wrapped")
end

local function isModule(key, name)
	return type(key) == "string" and key:find(name, 1, true) ~= nil
end

local stored, seenMenu = 0, 0
local function onModuleUnsafe(key, m)
	stored = stored + 1
	if stored == 1 or stored % 100 == 0 then pcall(api.log, "source icon: " .. stored .. " modules loaded so far, last " .. tostring(key)) end
	if isModule(key, "mod_") and isModule(key, "menu") and seenMenu < 12 then
		seenMenu = seenMenu + 1
		pcall(api.log, "source icon: menu module " .. tostring(key))
	end
	if isModule(key, "mod_manager_react_util.tl") then
		local ok, err = pcall(wrapSourceInfo, m)
		if not ok then say("wrapping the source names failed: " .. tostring(err)) end
		say("source names module seen as " .. type(m) .. ", getSourceInfo is " .. type(type(m) == "table" and rawget(m, "getSourceInfo") or nil))
	end
	if isModule(key, "gui/main/builtin.lua") then
		local ok, err = pcall(wrapImageView, m)
		if not ok then say("wrapping ImageView failed: " .. tostring(err)) end
		say("builtin module seen as " .. type(m) .. ", ImageView is " .. type(type(m) == "table" and m.ImageView or nil))
	end
end

local function onModule(key, m)
	local ok, err = pcall(onModuleUnsafe, key, m)
	if not ok then say("the module hook failed: " .. tostring(err)) end
end

local function watchModules(modules)
	if type(modules) ~= "table" or getmetatable(modules) ~= nil then return end
	setmetatable(modules, { __newindex = function(t, k, v)
		rawset(t, k, v)
		onModule(k, v)
	end })
end

local function wrapRequire(req)
	return function(name, a, b)
		local m = req(name, a, b)
		onModule(name, m)
		return m
	end
end

local existing = rawget(G, "_ug_loadedModules")
if type(existing) == "table" then watchModules(existing) end
local req = rawget(G, "ug_require")
if type(req) == "function" then rawset(G, "ug_require", wrapRequire(req)) end
if getmetatable(G) ~= nil then return end
local watch = {}
watch.__newindex = function(t, k, v)
	if k == "_ug_loadedModules" and type(v) == "table" then pcall(watchModules, v) end
	if k == "ug_require" and type(v) == "function" then
		v = wrapRequire(v)
		if getmetatable(t) == watch then setmetatable(t, nil) end
	end
	rawset(t, k, v)
end
setmetatable(G, watch)
)LUA";

struct ChunkReader {
    const char* data;
    size_t size;
    bool given;
};

const char* ReadChunk(lua_State*, void* data, size_t* size) {
    auto* chunk = static_cast<ChunkReader*>(data);
    if (chunk->given) {
        *size = 0;
        return nullptr;
    }
    chunk->given = true;
    *size = chunk->size;
    return chunk->data;
}

bool g_badge = false;
std::atomic<bool> g_badgeFailed{false};

// Runs the badge chunk; false when it could not be loaded or run. Leaves the stack as it found it.
bool RunBadge(lua_State* L) {
    const int top = lua.gettop(L);
    static const std::string text = [] {
        std::string joined;
        for (const char* piece : kIconPieces) joined += piece;
        return joined + kBadgeChunk;
    }();
    ChunkReader chunk{ text.data(), text.size(), false };
    bool ok = lua.load(L, &ReadChunk, &chunk, "=tf3api_badge", nullptr) == 0 && lua.pcallk(L, 0, 0, 0, 0, nullptr) == 0;
    lua.settop(L, top);
    return ok;
}

bool RunBadgeGuarded(lua_State* L) {
    __try {
        return RunBadge(L);
    } __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        return false;
    }
}

std::atomic<bool> g_registrationFailed{false};

// Register() behind a guard: if a function located by signature turns out not to be what it should be, the
// likely symptom is an access violation here. Catch only that (never the game's own C++ or Lua errors),
// stop registering, and let the game carry on without the bridge.
bool RegisterGuarded(lua_State* L) {
    __try {
        Register(L);
        return true;
    } __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        return false;
    }
}

// The base library is opened once per new Lua state, on that state's own thread, before any script runs.
int HookOpenBase(lua_State* L) {
    const int result = g_originalOpenBase(L);
    if (g_registrationFailed.load(std::memory_order_relaxed)) return result;
    if (!RegisterGuarded(L)) {
        g_registrationFailed.store(true);
        TF3_LOG("bridge: registering tf3api in a Lua state faulted - bridge switched off for this session");
        return result;
    }
    if (g_badge && !g_badgeFailed.load(std::memory_order_relaxed)) {
        if (!RunBadgeGuarded(L)) {
            g_badgeFailed.store(true);
            TF3_LOG("bridge: the mod list badge could not be set up in a Lua state - switched off for this session");
        } else {
            static std::atomic<int> s_badgeStates{0};
            const int n = s_badgeStates.fetch_add(1) + 1;
            if (n <= 3) TF3_LOG("bridge: mod list badge code run in Lua state #%d", n);
        }
    }
    const int count = g_statesSeen.fetch_add(1, std::memory_order_relaxed) + 1;
    if (count <= 3 || count == 10 || count == 50 || count % 500 == 0) {
        TF3_LOG("bridge: tf3api registered in Lua state #%d", count);
    }
    return result;
}

} // namespace

void Install() {
    if (!config::GetBool("Bridge", "Enabled", false)) {
        TF3_LOG("bridge: disabled in tf3api.ini ([Bridge] Enabled=0)");
        return;
    }
    for (const Signature& s : kSignatures) {
        *s.target = reinterpret_cast<void*>(sigscan::FindUnique(s.name, s.pattern));
        if (*s.target == nullptr) {
            TF3_LOG("bridge: %s not found in this game build - script bridge unavailable", s.name);
            return;
        }
    }
    g_badge = config::GetBool("Bridge", "ModBadge", false);
    if (g_badge) {
        for (const Signature& s : kOptionalSignatures) {
            *s.target = reinterpret_cast<void*>(sigscan::FindUnique(s.name, s.pattern));
            if (*s.target == nullptr) {
                TF3_LOG("bridge: %s not found - no \"API\" badge in the mod list", s.name);
                g_badge = false;
            }
        }
    }
    g_hookTarget = reinterpret_cast<void*>(lua.luaopen_base);
    MH_STATUS status = MH_CreateHook(g_hookTarget, reinterpret_cast<void*>(&HookOpenBase),
                                     reinterpret_cast<void**>(&g_originalOpenBase));
    if (status == MH_OK) status = MH_EnableHook(g_hookTarget);
    if (status != MH_OK) {
        TF3_LOG("bridge: hook install failed (%d) - script bridge unavailable", static_cast<int>(status));
        g_hookTarget = nullptr;
        return;
    }
    TF3_LOG("bridge: ready - new Lua states get the tf3api table (API version %.0f)", kApiVersion);
}

void Uninstall() {
    // Tables already registered keep pointing at functions in this DLL, which stays loaded until the process
    // ends; only the hook is removed.
    if (g_hookTarget == nullptr) return;
    MH_DisableHook(g_hookTarget);
    g_hookTarget = nullptr;
}

void* HookedOpenBase() {
    return g_originalOpenBase != nullptr ? g_hookTarget : nullptr;
}

// Leaves a message on a named queue from native code (as post() does from a script).
void PostFromNative(const char* channel, const char* text) {
    if (channel == nullptr || text == nullptr || !ChannelName(channel, std::strlen(channel))) return;
    std::lock_guard<std::mutex> lock(g_channelMutex);
    auto& queue = g_channels[channel];
    if (queue.size() >= kMaxQueued) queue.pop_front();
    queue.emplace_back(text);
}

} // namespace tf3api::lua_bridge
