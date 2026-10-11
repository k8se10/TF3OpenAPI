#include "mod_converter.h"

#include <cstdint>
#include <fstream>
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

const char* const kInboxName = "legacy_mods";
const char* const kStateName = "tf3api_converted.txt";   // inside the inbox: what was converted, and from what
const char* const kStageName = ".tf3api_stage";          // inside the inbox: a conversion in progress

fs::path FromUtf8(const char* text) { return fs::path(std::u8string(reinterpret_cast<const char8_t*>(text))); }

std::string ToUtf8(const fs::path& path) {
    std::u8string s = path.generic_u8string();
    return std::string(reinterpret_cast<const char*>(s.data()), s.size());
}

// The rules may read anywhere under the old mod and write anywhere under the staging folder, nowhere else.
struct Job {
    fs::path source;
    fs::path stage;
};

bool IsUnder(const fs::path& path, const fs::path& root) {
    std::error_code ec;
    fs::path p = fs::weakly_canonical(path, ec);
    if (ec) return false;
    fs::path r = fs::weakly_canonical(root, ec);
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
    for (fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
        if (!it->is_regular_file(ec)) continue;
        std::string rel = ToUtf8(it->path().lexically_relative(root));
        lua_pushlstring(L, rel.data(), rel.size());
        lua_rawseti(L, -2, ++n);
    }
    return 1;
}

int ReadUpTo(lua_State* L, std::streamsize limit) {
    Job* job = JobOf(L);
    fs::path path = FromUtf8(luaL_checkstring(L, 1));
    if (!IsUnder(path, job->source)) return 0;
    std::ifstream in(path, std::ios::binary);
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
    fs::create_directories(path.parent_path(), ec);
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
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
    fs::create_directories(to.parent_path(), ec);
    fs::copy_file(from, to, fs::copy_options::overwrite_existing, ec);
    if (ec) return luaL_error(L, "cannot copy %s: %s", lua_tostring(L, 1), ec.message().c_str());
    return 0;
}

// What the old mod looked like when it was converted: number of files, their total size, the newest change.
std::string Fingerprint(const fs::path& folder) {
    std::error_code ec;
    uint64_t count = 0, bytes = 0;
    int64_t newest = 0;
    for (fs::recursive_directory_iterator it(folder, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
        std::error_code e2;
        if (!it->is_regular_file(e2)) continue;
        ++count;
        bytes += it->file_size(e2);
        auto time = it->last_write_time(e2).time_since_epoch().count();
        if (!e2 && static_cast<int64_t>(time) > newest) newest = static_cast<int64_t>(time);
    }
    return std::to_string(count) + "/" + std::to_string(bytes) + "/" + std::to_string(newest);
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
        const luaL_Reg functions[] = { { "list", HostList }, { "read", HostRead }, { "readHead", HostReadHead }, { "write", HostWrite }, { "copy", HostCopy } };
        for (const luaL_Reg& f : functions) {
            lua_pushlightuserdata(L, &job);
            lua_pushcclosure(L, f.func, 1);
            lua_setfield(L, -2, f.name);
        }
        std::string src = ToUtf8(source), dst = ToUtf8(stage);
        lua_pushlstring(L, src.data(), src.size());
        lua_pushlstring(L, dst.data(), dst.size());
        lua_pushlstring(L, folderName.data(), folderName.size());
        if (lua_pcall(L, 4, 1, 0) != LUA_OK) {
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

Result Run(const fs::path& gameDir, const LogFn& log) {
    Result result;
    auto say = [&log](const std::string& text) { if (log) log(text); };
    try {
        std::error_code ec;
        fs::path inbox = gameDir / kInboxName;
        fs::create_directories(inbox, ec);
        if (ec) {
            say("mod converter: cannot create " + ToUtf8(inbox) + ": " + ec.message());
            return result;
        }
        fs::path stateFile = inbox / kStateName;
        fs::path stage = inbox / kStageName;
        fs::path mods = gameDir / "mods" / "release";
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
