#include "lua_worker.h"

#include "config.h"
#include "log.h"
#include "lua_bridge.h"
#include "sigscan.h"

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace tf3api::lua_worker {

namespace {

struct lua_State;
using lua_CFunction = int (*)(lua_State*);
using lua_Alloc = void* (*)(void* ud, void* ptr, size_t oldSize, size_t newSize);
using lua_Reader = const char* (*)(lua_State*, void* data, size_t* size);

// The game's own Lua 5.2.2, located by signature (build 40408 addresses and how each was found:
// re_notes/scripting/lua_vm.md).
struct Api {
    lua_State* (*newstate)(lua_Alloc, void* ud) = nullptr;
    int (*load)(lua_State*, lua_Reader, void* data, const char* chunkName, const char* mode) = nullptr;
    int (*pcallk)(lua_State*, int nargs, int nresults, int errfunc, int ctx, lua_CFunction k) = nullptr;
    void (*pushcclosure)(lua_State*, lua_CFunction fn, int upvalues) = nullptr;
    const char* (*pushlstring)(lua_State*, const char* text, size_t length) = nullptr;
    void (*setglobal)(lua_State*, const char* name) = nullptr;
    const char* (*tolstring)(lua_State*, int index, size_t* length) = nullptr;
    void (*settop)(lua_State*, int index) = nullptr;
    lua_CFunction openBase = nullptr, openString = nullptr, openTable = nullptr, openMath = nullptr;
} lua;

bool g_available = false;
constexpr size_t kMaxFileBytes = 8u * 1024u * 1024u;
constexpr size_t kMaxInputBytes = 128u * 1024u * 1024u;
constexpr size_t kMaxPending = 4;

// ---- The worker's state and queue ---------------------------------------------------------------------------

struct Job {
    unsigned id = 0;
    enum Kind { kLoad, kRun, kEval } kind = kRun;
    std::string text;                 // kRun: the input; kEval: Lua source; kLoad: unused
    std::vector<std::string> files;   // kLoad: paths relative to the game folder
};
struct Result {
    unsigned id = 0;
    bool ok = false;
    std::string text;
};

std::mutex g_mutex;
std::condition_variable g_wake;
std::deque<Job> g_pending;
std::deque<Result> g_finished;
bool g_threadStarted = false;
bool g_stop = false;
unsigned g_nextId = 1;
std::atomic<bool> g_started{false};   // files have been given

lua_State* g_state = nullptr;         // worker thread only
std::string g_loadError;              // worker thread only: what went wrong loading the files

void* Allocate(void*, void* ptr, size_t, size_t newSize) {
    if (newSize == 0) {
        std::free(ptr);
        return nullptr;
    }
    return std::realloc(ptr, newSize);
}

struct Chunk {
    const char* data;
    size_t size;
    bool given;
};
const char* ReadChunk(lua_State*, void* data, size_t* size) {
    auto* chunk = static_cast<Chunk*>(data);
    if (chunk->given) {
        *size = 0;
        return nullptr;
    }
    chunk->given = true;
    *size = chunk->size;
    return chunk->data;
}

std::string TopAsString(lua_State* L) {
    size_t length = 0;
    const char* text = lua.tolstring(L, -1, &length);
    return text != nullptr ? std::string(text, length) : std::string();
}

// Loads and runs a chunk, leaving its one result on the stack. Returns false with the message in *error.
bool RunChunk(lua_State* L, const char* source, size_t length, const char* name, std::string* error) {
    Chunk chunk{source, length, false};
    if (lua.load(L, &ReadChunk, &chunk, name, nullptr) != 0 || lua.pcallk(L, 0, 1, 0, 0, nullptr) != 0) {
        *error = TopAsString(L);
        if (error->empty()) *error = "error without a message";
        lua.settop(L, 0);
        return false;
    }
    return true;
}

bool OpenLibrary(lua_State* L, lua_CFunction open, const char* name, bool isBase) {
    lua.pushcclosure(L, open, 0);
    lua.pushlstring(L, name, std::strlen(name));
    if (lua.pcallk(L, 1, 1, 0, 0, nullptr) != 0) {
        lua.settop(L, 0);
        return false;
    }
    if (isBase) {
        lua.settop(L, 0);   // the base library puts itself into the globals
    } else {
        lua.setglobal(L, name);
    }
    return true;
}

lua_State* NewState() {
    lua_State* L = lua.newstate(&Allocate, nullptr);
    if (L == nullptr) return nullptr;
    // (opening the base library also runs the bridge's hook, which adds the tf3api table to this state)
    if (!OpenLibrary(L, lua.openBase, "_G", true) || !OpenLibrary(L, lua.openString, "string", false) ||
        !OpenLibrary(L, lua.openTable, "table", false) || !OpenLibrary(L, lua.openMath, "math", false)) {
        return nullptr;   // the state is abandoned: there is no lua_close among the located functions
    }
    return L;
}

std::wstring GameFolder() {
    wchar_t exePath[MAX_PATH] = {};
    const DWORD length = GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring path(exePath, length);
    const size_t slash = path.find_last_of(L"\\/");
    if (slash != std::wstring::npos) path.resize(slash + 1);
    return path;
}

bool ReadWholeFile(const std::string& relative, std::string* out) {
    std::wstring path = GameFolder();
    for (const char c : relative) path.push_back(c == '/' ? L'\\' : static_cast<wchar_t>(static_cast<unsigned char>(c)));
    FILE* file = nullptr;
    if (_wfopen_s(&file, path.c_str(), L"rb") != 0 || file == nullptr) return false;
    out->clear();
    char buffer[65536];
    size_t n;
    while ((n = fread(buffer, 1, sizeof(buffer), file)) > 0) {
        out->append(buffer, n);
        if (out->size() > kMaxFileBytes) break;
    }
    fclose(file);
    return out->size() <= kMaxFileBytes;
}

// "mods/x/core.lua" -> "core"; anything that is not a letter, digit or underscore becomes an underscore.
std::string GlobalNameOf(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    std::string name = path.substr(slash == std::string::npos ? 0 : slash + 1);
    const size_t dot = name.find('.');
    if (dot != std::string::npos) name.resize(dot);
    for (char& c : name) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) c = '_';
    }
    return name;
}

void LoadFiles(const std::vector<std::string>& files) {
    g_loadError.clear();
    g_state = NewState();   // a previous state, if any, is left behind (no lua_close); starts are rare
    if (g_state == nullptr) {
        g_loadError = "could not create the worker's Lua state";
        return;
    }
    for (const std::string& path : files) {
        std::string source;
        if (!ReadWholeFile(path, &source)) {
            g_loadError = "could not read " + path;
            break;
        }
        std::string error;
        const std::string chunkName = "@" + path;
        if (!RunChunk(g_state, source.data(), source.size(), chunkName.c_str(), &error)) {
            g_loadError = path + ": " + error;
            break;
        }
        lua.setglobal(g_state, GlobalNameOf(path).c_str());
    }
    if (g_loadError.empty()) {
        TF3_LOG("worker: Lua state ready, %zu files loaded", files.size());
    } else {
        TF3_LOG("worker: %.400s", g_loadError.c_str());
        g_state = nullptr;
    }
}

Result Execute(const Job& job) {
    Result result;
    result.id = job.id;
    if (job.kind == Job::kLoad) {
        LoadFiles(job.files);
        result.ok = g_loadError.empty();
        result.text = g_loadError;
        return result;
    }
    if (job.kind == Job::kEval) {
        lua_State* L = NewState();
        if (L == nullptr) {
            result.text = "could not create a Lua state";
            return result;
        }
        std::string error;
        if (RunChunk(L, job.text.data(), job.text.size(), "=selftest", &error)) {
            result.ok = true;
            result.text = TopAsString(L);
            lua.settop(L, 0);
        } else {
            result.text = error;
        }
        return result;
    }
    if (g_state == nullptr) {
        result.text = g_loadError.empty() ? "the worker has not been started" : g_loadError;
        return result;
    }
    lua.pushlstring(g_state, job.text.data(), job.text.size());
    lua.setglobal(g_state, "TF3_INPUT");
    static const char kCall[] = "return tf3_job(TF3_INPUT)";
    std::string error;
    if (RunChunk(g_state, kCall, sizeof(kCall) - 1, "=job", &error)) {
        result.ok = true;
        result.text = TopAsString(g_state);
        lua.settop(g_state, 0);
    } else {
        result.text = error;
    }
    return result;
}

// Nothing in the queue: the thread sleeps on the condition variable.
void ThreadMain() {
    SetThreadDescription(GetCurrentThread(), L"tf3api Lua worker");
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(g_mutex);
            g_wake.wait(lock, [] { return g_stop || !g_pending.empty(); });
            if (g_stop) return;
            job = std::move(g_pending.front());
            g_pending.pop_front();
        }
        Result result = Execute(job);
        if (job.kind == Job::kLoad && result.ok) continue;   // a good load needs no report
        std::lock_guard<std::mutex> lock(g_mutex);
        g_finished.push_back(std::move(result));
        while (g_finished.size() > 16) g_finished.pop_front();
    }
}

// Call with g_mutex held.
unsigned Queue(Job job) {
    if (!g_threadStarted) {
        g_threadStarted = true;
        std::thread(&ThreadMain).detach();
    }
    job.id = g_nextId++;
    const unsigned id = job.id;
    g_pending.push_back(std::move(job));
    g_wake.notify_one();
    return id;
}

// The first name in a library's list of functions (a luaL_Reg array), or nullptr when it cannot be read.
// On its own so that the guarded read is in a function with nothing to unwind.
const char* FirstRegisteredName(uintptr_t list) {
    __try {
        return *reinterpret_cast<const char* const*>(list);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return nullptr;
    }
}

bool SameText(const char* a, const char* b) {
    __try {
        return a != nullptr && std::strcmp(a, b) == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool SafePath(const std::string& path) {
    if (path.size() < 10 || path.size() > 240) return false;
    if (path.compare(0, 5, "mods/") != 0 && path.compare(0, 5, "mods\\") != 0) return false;
    if (path.find("..") != std::string::npos || path.find(':') != std::string::npos) return false;
    if (path.compare(path.size() - 4, 4, ".lua") != 0) return false;
    for (const char c : path) {
        if (static_cast<unsigned char>(c) < 0x20) return false;
    }
    return true;
}

} // namespace

bool Available() { return g_available; }

bool Start(const std::string& files, std::string* reason) {
    if (!g_available) {
        *reason = "the worker is not available in this build of the game";
        return false;
    }
    Job job;
    job.kind = Job::kLoad;
    size_t at = 0;
    while (at <= files.size()) {
        size_t end = files.find('\n', at);
        if (end == std::string::npos) end = files.size();
        std::string path = files.substr(at, end - at);
        while (!path.empty() && (path.back() == '\r' || path.back() == ' ')) path.pop_back();
        if (!path.empty()) {
            if (!SafePath(path)) {
                *reason = "only .lua files under the mods folder can be loaded: " + path;
                return false;
            }
            job.files.push_back(std::move(path));
        }
        at = end + 1;
    }
    if (job.files.empty() || job.files.size() > 16) {
        *reason = "between 1 and 16 files are needed";
        return false;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    g_pending.clear();   // jobs for the state being replaced are dropped
    Queue(std::move(job));
    g_started.store(true);
    return true;
}

unsigned Run(const char* input, size_t length) {
    if (!g_available || !g_started.load() || length > kMaxInputBytes) return 0;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_pending.size() >= kMaxPending) return 0;
    Job job;
    job.kind = Job::kRun;
    job.text.assign(input, length);
    return Queue(std::move(job));
}

bool Take(unsigned* job, bool* ok, std::string* text) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_finished.empty()) return false;
    Result result = std::move(g_finished.front());
    g_finished.pop_front();
    *job = result.id;
    *ok = result.ok;
    *text = std::move(result.text);
    return true;
}

void Install() {
    if (!config::GetBool("Worker", "Enabled", true)) {
        TF3_LOG("worker: off ([Worker] Enabled=0)");
        return;
    }
    struct Signature {
        const char* name;
        const char* pattern;
        void** target;
    };
    const Signature signatures[] = {
        {"lua_newstate", "48 89 6C 24 18 48 89 74 24 20 57 48 83 EC 20 48 8B F2 48 8B E9", reinterpret_cast<void**>(&lua.newstate)},
        {"lua_load", "48 89 5C 24 10 56 48 83 EC 50 49 8B D9 48 8B F1", reinterpret_cast<void**>(&lua.load)},
        {"lua_pcallk", "48 89 74 24 18 57 48 83 EC 40 33 F6 48 89 6C 24 58", reinterpret_cast<void**>(&lua.pcallk)},
        {"lua_pushcclosure", "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 49 63 F8", reinterpret_cast<void**>(&lua.pushcclosure)},
        {"lua_pushlstring",
         "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B 41 18 49 8B F8 48 8B F2 48 8B D9 48 83 78 18 00 7E ?? E8 ?? ?? ?? "
         "?? 4C 8B C7 48 8B D6 48 8B CB E8 ?? ?? ?? ??",
         reinterpret_cast<void**>(&lua.pushlstring)},
        {"lua_setglobal",
         "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 48 8B 41 18 48 8B FA 48 8B E9 BA 02 00 00 00 48 8B 48 40 "
         "E8 ?? ?? ?? ?? 48 8B 5D 10 48 8B D7 48 8B CD 48 8B F0 4C 8D 43 10 4C 89 45 10 E8 ?? ?? ?? ?? 48 89 03 48 8B D6 0F B6 "
         "48 08 83 C9 40 89 4B 08 48 8B CD 4C 8B 45 10 4D 8D 48 E0",
         reinterpret_cast<void**>(&lua.setglobal)},
        {"lua_tolstring", "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 49 8B D8 8B F2 48 8B F9 E8 ?? ?? ?? ??",
         reinterpret_cast<void**>(&lua.tolstring)},
        {"lua_settop", "85 D2 78 ?? 48 8B 41 20 4C 63 CA 49 FF C1 49 C1 E1 04", reinterpret_cast<void**>(&lua.settop)},
        {"luaopen_base", "40 53 48 83 EC 20 BA D8 B9 F0 FF 41 B8 02 00 00 00", reinterpret_cast<void**>(&lua.openBase)},
        {"luaopen_string", "40 53 48 83 EC 20 33 D2 48 8B D9 44 8D 42 0E", reinterpret_cast<void**>(&lua.openString)},
        {"luaopen_math", "40 53 48 83 EC 20 33 D2 48 8B D9 44 8D 42 1B", reinterpret_cast<void**>(&lua.openMath)},
    };
    bool all = true;
    for (const Signature& s : signatures) {
        // The bridge hooks luaopen_base, which overwrites the bytes this pattern looks for (seen in the game:
        // found by the bridge, then "0 matches" here). Take the unhooked function from the bridge instead; a
        // worker state then also stays free of the bridge's table, as intended.
        if (std::strcmp(s.name, "luaopen_base") == 0) {
            if (void* original = lua_bridge::OriginalOpenBase()) {
                *s.target = original;
                TF3_LOG("worker: luaopen_base taken from the bridge (it is hooked there)");
                continue;
            }
        }
        *s.target = reinterpret_cast<void*>(sigscan::FindUnique(s.name, s.pattern));
        if (*s.target == nullptr) all = false;
    }
    // The table library's opener looks exactly like the coroutine library's (both make a table of six
    // functions). They differ in the list of functions they register: the one whose first name is "concat".
    {
        const char* pattern = "40 53 48 83 EC 20 33 D2 48 8B D9 44 8D 42 06 E8 ?? ?? ?? ?? 45 33 C0 48 8D 15 ?? ?? ?? ??";
        std::vector<uintptr_t> matches;
        sigscan::FindAll(pattern, 8, &matches);
        for (const uintptr_t match : matches) {
            const uintptr_t list = sigscan::ResolveRipRelative(match + 23, 3, 7);   // lea rdx, [the luaL_Reg list]
            if (SameText(FirstRegisteredName(list), "concat")) lua.openTable = reinterpret_cast<lua_CFunction>(match);
        }
        if (lua.openTable == nullptr) {
            TF3_LOG("sigscan luaopen_table: NOT FOUND among %zu candidates - no worker", matches.size());
            all = false;
        } else {
            TF3_LOG("sigscan luaopen_table: found at +0x%llx (of %zu candidates)",
                    static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(lua.openTable) - reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr))),
                    matches.size());
        }
    }
    if (!all) {
        TF3_LOG("worker: not available (Lua functions missing - different game build?)");
        return;
    }
    g_available = true;
    TF3_LOG("worker: available");

    if (config::GetBool("Worker", "SelfTest", false)) {
        Job job;
        job.kind = Job::kEval;
        job.text = "return string.format('%d', 6 * 7) .. table.concat({ 'a', 'b' }) .. '|' .. tostring(math.floor(3.7)) .. '|' .. type(tf3api) .. '|' .. _VERSION";
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            Queue(std::move(job));
        }
        // the answer is collected by whoever calls Take first; log it from here after a short wait
        std::thread([] {
            for (int i = 0; i < 50; ++i) {
                Sleep(100);
                unsigned id = 0;
                bool ok = false;
                std::string text;
                if (Take(&id, &ok, &text)) {
                    TF3_LOG("worker self-test: %s - \"%.200s\" (expected \"42ab|3|table|Lua 5.2\")", ok ? "ran" : "FAILED", text.c_str());
                    return;
                }
            }
            TF3_LOG("worker self-test: no answer after 5 s");
        }).detach();
    }
}

void Uninstall() {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_stop = true;
    g_wake.notify_all();
}

} // namespace tf3api::lua_worker
