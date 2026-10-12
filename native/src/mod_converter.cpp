#include "mod_converter.h"

#include <cstdint>
#include <fstream>
#include <iterator>
#include <map>
#include <sstream>
#include <system_error>
#include <vector>

#include "lua.hpp"

namespace fs = std::filesystem;

namespace tf3api::mod_converter {

namespace {

const unsigned char kRules[] = {
#include "convert_lua.inc"
};

// shipped inside a converted station mod (see converter/station_shim.lua)
const unsigned char kStationShim[] = {
#include "station_shim_lua.inc"
};

const char* const kInboxName = "legacy_mods";
const char* const kStateName = "tf3api_converted.txt";   // inside the inbox: what was converted, and from what
const char* const kStageName = ".tf3api_stage";          // inside the inbox: a conversion in progress

fs::path FromUtf8(const char* text) { return fs::path(std::u8string(reinterpret_cast<const char8_t*>(text))); }

// Old mods have long file names; with the game's folder in front they can pass the 260 characters most file
// calls stop at. The extended form of an absolute path has no such limit.
fs::path Long(const fs::path& path) {
    std::error_code ec;
    fs::path absolute = fs::absolute(path, ec);
    if (ec) return path;
    std::wstring text = absolute.lexically_normal().make_preferred().wstring();
    if (text.rfind(L"\\\\", 0) == 0) return fs::path(text);   // already extended, or a network path
    return fs::path(L"\\\\?\\" + text);
}

std::string ToUtf8(const fs::path& path) {
    std::u8string s = path.generic_u8string();
    return std::string(reinterpret_cast<const char*>(s.data()), s.size());
}

// The rules may read anywhere under the old mod and write anywhere under the staging folder, nowhere else.
struct Job {
    fs::path source;
    fs::path stage;
};

bool g_stations = false;
bool g_stationDebug = false;

bool IsUnder(const fs::path& path, const fs::path& root) {
    std::error_code ec;
    fs::path p = fs::weakly_canonical(Long(path), ec);
    if (ec) return false;
    fs::path r = fs::weakly_canonical(Long(root), ec);
    if (ec) return false;
    auto pi = p.begin();
    for (auto ri = r.begin(); ri != r.end(); ++ri, ++pi) {
        if (pi == p.end() || *pi != *ri) return false;
    }
    return true;
}

Job* JobOf(lua_State* L) { return static_cast<Job*>(lua_touserdata(L, lua_upvalueindex(1))); }

int HostList(lua_State* L) {
    Job* job = JobOf(L);
    fs::path root = FromUtf8(luaL_checkstring(L, 1));
    lua_newtable(L);
    if (!IsUnder(root, job->source)) return 1;
    std::error_code ec;
    lua_Integer n = 0;
    const fs::path longRoot = Long(root);
    for (fs::recursive_directory_iterator it(longRoot, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
        if (!it->is_regular_file(ec)) continue;
        std::string rel = ToUtf8(it->path().lexically_relative(longRoot));
        lua_pushlstring(L, rel.data(), rel.size());
        lua_rawseti(L, -2, ++n);
    }
    return 1;
}

int ReadUpTo(lua_State* L, std::streamsize limit) {
    Job* job = JobOf(L);
    fs::path path = FromUtf8(luaL_checkstring(L, 1));
    if (!IsUnder(path, job->source)) return 0;
    std::ifstream in(Long(path), std::ios::binary);
    if (!in) return 0;
    std::string data;
    if (limit < 0) {
        std::ostringstream all;
        all << in.rdbuf();
        data = all.str();
    } else {
        data.resize(static_cast<size_t>(limit));
        in.read(data.data(), limit);
        data.resize(static_cast<size_t>(in.gcount()));
    }
    lua_pushlstring(L, data.data(), data.size());
    return 1;
}

int HostRead(lua_State* L) { return ReadUpTo(L, -1); }

int HostReadHead(lua_State* L) {
    lua_Integer n = luaL_checkinteger(L, 2);
    if (n < 0) n = 0;
    if (n > 65536) n = 65536;
    return ReadUpTo(L, static_cast<std::streamsize>(n));
}

int HostWrite(lua_State* L) {
    Job* job = JobOf(L);
    fs::path path = FromUtf8(luaL_checkstring(L, 1));
    size_t size = 0;
    const char* data = luaL_checklstring(L, 2, &size);
    if (!IsUnder(path, job->stage)) return luaL_error(L, "write outside the output folder: %s", lua_tostring(L, 1));
    std::error_code ec;
    fs::create_directories(Long(path.parent_path()), ec);
    std::ofstream out(Long(path), std::ios::binary | std::ios::trunc);
    if (!out) return luaL_error(L, "cannot write %s", lua_tostring(L, 1));
    out.write(data, static_cast<std::streamsize>(size));
    return 0;
}

int HostCopy(lua_State* L) {
    Job* job = JobOf(L);
    fs::path from = FromUtf8(luaL_checkstring(L, 1));
    fs::path to = FromUtf8(luaL_checkstring(L, 2));
    if (!IsUnder(from, job->source)) return luaL_error(L, "copy from outside the old mod: %s", lua_tostring(L, 1));
    if (!IsUnder(to, job->stage)) return luaL_error(L, "copy to outside the output folder: %s", lua_tostring(L, 2));
    std::error_code ec;
    fs::create_directories(Long(to.parent_path()), ec);
    fs::copy_file(Long(from), Long(to), fs::copy_options::overwrite_existing, ec);
    if (ec) return luaL_error(L, "cannot copy %s: %s", lua_tostring(L, 1), ec.message().c_str());
    return 0;
}

// A .tga picture (uncompressed or run-length packed, 8, 24 or 32 bits) read into rows of blue-green-red-alpha,
// top row first. False when the file is not one of those.
bool ReadTga(const fs::path& path, uint32_t* width, uint32_t* height, std::vector<uint8_t>* pixels) {
    std::ifstream in(Long(path), std::ios::binary);
    if (!in) return false;
    std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (file.size() < 18) return false;
    const uint8_t idLength = file[0], colourMap = file[1], kind = file[2], bits = file[16], descriptor = file[17];
    const uint32_t w = file[12] | (file[13] << 8), h = file[14] | (file[15] << 8);
    const bool packed = (kind == 10 || kind == 11);
    const bool grey = (kind == 3 || kind == 11);
    if (colourMap != 0 || !(kind == 2 || kind == 3 || packed)) return false;
    if (w == 0 || h == 0 || w > 16384 || h > 16384) return false;
    if (!((grey && bits == 8) || (!grey && (bits == 24 || bits == 32)))) return false;
    const size_t step = bits / 8;
    const size_t count = static_cast<size_t>(w) * h;
    std::vector<uint8_t> raw(count * step);
    size_t at = 18 + idLength;
    if (!packed) {
        if (file.size() < at + raw.size()) return false;
        std::copy(file.begin() + at, file.begin() + at + raw.size(), raw.begin());
    } else {
        size_t done = 0;
        while (done < count) {
            if (at >= file.size()) return false;
            const uint8_t head = file[at++];
            const size_t run = (head & 0x7f) + 1;
            if (done + run > count) return false;
            if (head & 0x80) {
                if (at + step > file.size()) return false;
                for (size_t i = 0; i < run; ++i) std::copy(file.begin() + at, file.begin() + at + step, raw.begin() + (done + i) * step);
                at += step;
            } else {
                if (at + run * step > file.size()) return false;
                std::copy(file.begin() + at, file.begin() + at + run * step, raw.begin() + done * step);
                at += run * step;
            }
            done += run;
        }
    }
    const bool topFirst = (descriptor & 0x20) != 0;
    const bool rightFirst = (descriptor & 0x10) != 0;
    pixels->assign(count * 4, 255);
    for (uint32_t y = 0; y < h; ++y) {
        const uint32_t from = topFirst ? y : (h - 1 - y);
        for (uint32_t x = 0; x < w; ++x) {
            const uint8_t* p = &raw[(static_cast<size_t>(from) * w + (rightFirst ? (w - 1 - x) : x)) * step];
            uint8_t* q = &(*pixels)[(static_cast<size_t>(y) * w + x) * 4];
            if (grey) { q[0] = q[1] = q[2] = p[0]; }
            else { q[0] = p[0]; q[1] = p[1]; q[2] = p[2]; if (step == 4) q[3] = p[3]; }
        }
    }
    *width = w;
    *height = h;
    return true;
}

// Writes rows of blue-green-red-alpha as an uncompressed .dds with every mip level (each the one above averaged
// two by two). Returns the number of levels, 0 on failure.
uint32_t WriteDdsWithMips(const fs::path& path, uint32_t width, uint32_t height, std::vector<uint8_t> level) {
    uint32_t levels = 1;
    for (uint32_t w = width, h = height; w > 1 || h > 1; w = (w > 1 ? w / 2 : 1), h = (h > 1 ? h / 2 : 1)) ++levels;
    std::error_code ec;
    fs::create_directories(Long(path.parent_path()), ec);
    std::ofstream out(Long(path), std::ios::binary | std::ios::trunc);
    if (!out) return 0;
    auto put = [&out](uint32_t v) { out.write(reinterpret_cast<const char*>(&v), 4); };
    out.write("DDS ", 4);
    put(124); put(0x2100F); put(height); put(width); put(width * 4); put(0); put(levels);
    for (int i = 0; i < 11; ++i) put(0);
    put(32); put(0x41); put(0); put(32); put(0x00FF0000); put(0x0000FF00); put(0x000000FF); put(0xFF000000);
    put(0x401008); put(0); put(0); put(0); put(0);
    uint32_t w = width, h = height;
    for (uint32_t n = 0; n < levels; ++n) {
        out.write(reinterpret_cast<const char*>(level.data()), static_cast<std::streamsize>(level.size()));
        if (n + 1 == levels) break;
        const uint32_t nw = w > 1 ? w / 2 : 1, nh = h > 1 ? h / 2 : 1;
        std::vector<uint8_t> next(static_cast<size_t>(nw) * nh * 4);
        for (uint32_t y = 0; y < nh; ++y) {
            const uint32_t y0 = (h > 1) ? y * 2 : 0, y1 = (h > 1) ? y * 2 + 1 : 0;
            for (uint32_t x = 0; x < nw; ++x) {
                const uint32_t x0 = (w > 1) ? x * 2 : 0, x1 = (w > 1) ? x * 2 + 1 : 0;
                for (int c = 0; c < 4; ++c) {
                    const uint32_t sum = level[(static_cast<size_t>(y0) * w + x0) * 4 + c] + level[(static_cast<size_t>(y0) * w + x1) * 4 + c] +
                                         level[(static_cast<size_t>(y1) * w + x0) * 4 + c] + level[(static_cast<size_t>(y1) * w + x1) * 4 + c];
                    next[(static_cast<size_t>(y) * nw + x) * 4 + c] = static_cast<uint8_t>((sum + 2) / 4);
                }
            }
        }
        level.swap(next);
        w = nw;
        h = nh;
    }
    return out ? levels : 0;
}

int HostResource(lua_State* L) {
    const std::string name = luaL_checkstring(L, 1);
    if (name != "station_shim.lua") return 0;
    lua_pushlstring(L, reinterpret_cast<const char*>(kStationShim), sizeof(kStationShim));
    return 1;
}

int HostMakeMips(lua_State* L) {
    Job* job = JobOf(L);
    fs::path from = FromUtf8(luaL_checkstring(L, 1));
    fs::path to = FromUtf8(luaL_checkstring(L, 2));
    if (!IsUnder(from, job->source) || !IsUnder(to, job->stage)) return 0;
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> pixels;
    try {
        if (!ReadTga(from, &width, &height, &pixels)) return 0;
        const uint32_t levels = WriteDdsWithMips(to, width, height, std::move(pixels));
        if (levels == 0) return 0;
        lua_pushinteger(L, width);
        lua_pushinteger(L, height);
        lua_pushinteger(L, levels);
        return 3;
    } catch (...) {
        return 0;   // out of memory on a huge picture and the like: the caller copies the file as it is
    }
}

// What the old mod looked like when it was converted: number of files, their total size, the newest change.
std::string Fingerprint(const fs::path& folder) {
    std::error_code ec;
    uint64_t count = 0, bytes = 0;
    int64_t newest = 0;
    for (fs::recursive_directory_iterator it(Long(folder), fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
        std::error_code e2;
        if (!it->is_regular_file(e2)) continue;
        ++count;
        bytes += it->file_size(e2);
        auto time = it->last_write_time(e2).time_since_epoch().count();
        if (!e2 && static_cast<int64_t>(time) > newest) newest = static_cast<int64_t>(time);
    }
    // ... and which rules converted it, so that better rules convert it again
    uint32_t rules = 2166136261u;
    for (unsigned char c : kRules) rules = (rules ^ c) * 16777619u;
    for (unsigned char c : kStationShim) rules = (rules ^ c) * 16777619u;
    rules = (rules ^ (g_stations ? 1u : 0u)) * 16777619u;
    rules = (rules ^ (g_stationDebug ? 2u : 0u)) * 16777619u;
    return std::to_string(count) + "/" + std::to_string(bytes) + "/" + std::to_string(newest) + "/" + std::to_string(rules);
}

struct Done {
    std::string fingerprint;
    std::string modId;
};

std::map<std::string, Done> ReadState(const fs::path& file) {
    std::map<std::string, Done> state;
    std::ifstream in(file, std::ios::binary);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t a = line.find('\t');
        size_t b = a == std::string::npos ? a : line.find('\t', a + 1);
        if (b == std::string::npos) continue;
        state[line.substr(b + 1)] = Done{ line.substr(0, a), line.substr(a + 1, b - a - 1) };
    }
    return state;
}

void WriteState(const fs::path& file, const std::map<std::string, Done>& state) {
    std::ofstream out(file, std::ios::binary | std::ios::trunc);
    for (const auto& [folder, done] : state) out << done.fingerprint << '\t' << done.modId << '\t' << folder << '\n';
}

// Runs the rules on one old mod. On success fills modId and summary and leaves the result in "stage".
bool ConvertOne(const fs::path& source, const fs::path& stage, const std::string& folderName, std::string* modId, std::string* summary) {
    Job job{ source, stage };
    lua_State* L = luaL_newstate();
    if (!L) {
        *summary = "no memory for the interpreter";
        return false;
    }
    // only what the rules need: no file, system or debug libraries - files go through the host functions above
    luaL_requiref(L, "_G", luaopen_base, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
    lua_settop(L, 0);
    for (const char* name : { "dofile", "loadfile" }) {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }

    bool ok = false;
    if (luaL_loadbuffer(L, reinterpret_cast<const char*>(kRules), sizeof(kRules), "=convert.lua") != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK) {
        *summary = std::string("the rules do not load: ") + (lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
    } else {
        lua_getfield(L, -1, "convertMod");
        lua_newtable(L);
        const luaL_Reg functions[] = { { "list", HostList }, { "read", HostRead }, { "readHead", HostReadHead }, { "write", HostWrite }, { "copy", HostCopy },
                                         { "makeMips", HostMakeMips }, { "resource", HostResource } };
        for (const luaL_Reg& f : functions) {
            lua_pushlightuserdata(L, &job);
            lua_pushcclosure(L, f.func, 1);
            lua_setfield(L, -2, f.name);
        }
        std::string src = ToUtf8(source), dst = ToUtf8(stage);
        lua_pushlstring(L, src.data(), src.size());
        lua_pushlstring(L, dst.data(), dst.size());
        lua_pushlstring(L, folderName.data(), folderName.size());
        lua_newtable(L);
        lua_pushboolean(L, g_stations);
        lua_setfield(L, -2, "stations");
        lua_pushboolean(L, g_stationDebug);
        lua_setfield(L, -2, "stationDebug");
        if (lua_pcall(L, 5, 1, 0) != LUA_OK) {
            *summary = std::string("the conversion stopped: ") + (lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
        } else if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "modId");
            if (const char* id = lua_tostring(L, -1)) *modId = id;
            lua_pop(L, 1);
            auto count = [L](const char* table, const char* field) -> long long {
                long long n = 0;
                lua_getfield(L, -1, table);
                if (lua_istable(L, -1)) {
                    if (field) {
                        lua_getfield(L, -1, field);
                        n = static_cast<long long>(lua_tointeger(L, -1));
                        lua_pop(L, 1);
                    } else {
                        n = static_cast<long long>(lua_rawlen(L, -1));
                    }
                }
                lua_pop(L, 1);
                return n;
            };
            std::ostringstream text;
            text << count("counts", "models") << " models, " << count("counts", "materials") << " materials, "
                 << count("counts", "textures") << " textures; " << count("problems", nullptr) << " problems, "
                 << count("missing", nullptr) << " missing files";
            *summary = text.str();
            lua_getfield(L, -1, "empty");
            bool empty = lua_toboolean(L, -1) != 0;
            lua_pop(L, 1);
            ok = !modId->empty() && !empty;
            if (empty) *summary = "nothing in it that the converter handles (no res/models or res/textures files)";
            else if (!ok) *summary = "the rules gave no mod id";
        } else {
            *summary = "the rules gave no report";
        }
    }
    lua_close(L);
    return ok;
}

bool SafeModId(const std::string& id) {
    if (id.empty() || id.size() > 120) return false;
    for (char c : id) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
    }
    return true;
}

} // namespace

const char* EmbeddedRules(size_t* size) {
    if (size) *size = sizeof(kRules);
    return reinterpret_cast<const char*>(kRules);
}

Result Run(const fs::path& gameDir, const LogFn& log, bool stations, bool stationDebug) {
    Result result;
    g_stations = stations;
    g_stationDebug = stationDebug;
    auto say = [&log](const std::string& text) { if (log) log(text); };
    try {
        std::error_code ec;
        fs::path inbox = Long(gameDir / kInboxName);
        fs::create_directories(inbox, ec);
        if (ec) {
            say("mod converter: cannot create " + ToUtf8(inbox) + ": " + ec.message());
            return result;
        }
        fs::path stateFile = inbox / kStateName;
        fs::path stage = inbox / kStageName;
        fs::path mods = Long(gameDir / "mods" / "release");
        std::map<std::string, Done> state = ReadState(stateFile);
        bool stateChanged = false;

        std::vector<fs::path> folders;
        for (fs::directory_iterator it(inbox, ec), end; !ec && it != end; it.increment(ec)) {
            std::error_code e2;
            if (!it->is_directory(e2)) continue;
            std::string name = ToUtf8(it->path().filename());
            if (name.empty() || name[0] == '.') continue;
            folders.push_back(it->path());
        }
        result.found = static_cast<int>(folders.size());

        for (const fs::path& folder : folders) {
            std::string name = ToUtf8(folder.filename());
            std::string print = Fingerprint(folder);
            auto known = state.find(name);
            if (known != state.end() && known->second.fingerprint == print && fs::exists(mods / known->second.modId / "mod.json", ec)) {
                ++result.upToDate;
                continue;
            }
            fs::remove_all(stage, ec);
            std::string modId, summary;
            if (!ConvertOne(folder, stage, name, &modId, &summary) || !SafeModId(modId)) {
                ++result.failed;
                say("mod converter: \"" + name + "\" not converted - " + summary);
                fs::remove_all(stage, ec);
                continue;
            }
            fs::path target = mods / modId;
            if (fs::exists(target, ec)) {
                // only ever replace a folder an earlier conversion made
                if (!fs::exists(target / "conversion_report.txt", ec)) {
                    ++result.failed;
                    say("mod converter: \"" + name + "\" not converted - mods/release/" + modId + " exists and was not made by the converter");
                    fs::remove_all(stage, ec);
                    continue;
                }
                fs::remove_all(target, ec);
            }
            fs::create_directories(mods, ec);
            fs::rename(stage, target, ec);
            if (ec) {
                ++result.failed;
                say("mod converter: \"" + name + "\" converted but could not be moved to mods/release/" + modId + ": " + ec.message());
                fs::remove_all(stage, ec);
                continue;
            }
            state[name] = Done{ print, modId };
            stateChanged = true;
            ++result.converted;
            say("mod converter: \"" + name + "\" -> mods/release/" + modId + " (" + summary + "); see conversion_report.txt there");
        }
        if (stateChanged) WriteState(stateFile, state);
        if (result.found > 0) {
            say("mod converter: " + std::to_string(result.found) + " old mods in legacy_mods - " + std::to_string(result.converted) + " converted now, " +
                std::to_string(result.upToDate) + " already done, " + std::to_string(result.failed) + " failed");
        }
    } catch (const std::exception& e) {
        say(std::string("mod converter: stopped - ") + e.what());
    } catch (...) {
        say("mod converter: stopped for an unknown reason");
    }
    return result;
}

} // namespace tf3api::mod_converter
