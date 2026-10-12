// Test of the launch-time mod converter (native/src/mod_converter.cpp) on a made-up old mod in a temporary
// folder. Argument: the repository root (to check the built-in rules against converter/convert.lua).

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "mod_converter.h"

namespace fs = std::filesystem;

namespace {

int g_failed = 0;
int g_checks = 0;

void Check(bool ok, const char* what) {
    ++g_checks;
    if (!ok) {
        ++g_failed;
        std::printf("FAILED: %s\n", what);
    }
}

void Put(const fs::path& file, const std::string& text) {
    fs::create_directories(file.parent_path());
    std::ofstream(file, std::ios::binary) << text;
}

std::string Get(const fs::path& file) {
    std::ifstream in(file, std::ios::binary);
    std::ostringstream all;
    all << in.rdbuf();
    return all.str();
}

bool Has(const std::string& text, const char* part) { return text.find(part) != std::string::npos; }

} // namespace

int main(int argc, char** argv) {
    fs::path game = fs::temp_directory_path() / "tf3api_mod_converter_test";
    fs::remove_all(game);
    fs::create_directories(game);
    std::vector<std::string> lines;
    auto log = [&lines](const std::string& text) { lines.push_back(text); std::printf("  log: %s\n", text.c_str()); };

    // 1. nothing to do: the inbox is made, nothing else happens
    auto r = tf3api::mod_converter::Run(game, log);
    Check(fs::is_directory(game / "legacy_mods"), "the legacy_mods folder is made at launch");
    Check(r.found == 0 && r.converted == 0 && lines.empty(), "an empty inbox is silent");

    // 2. one old mod
    fs::path old = game / "legacy_mods" / "My Old Wagon_1";
    Put(old / "mod.lua", "function data() return { info = { name = _(\"n\"), description = \"d\" } } end");
    Put(old / "strings.lua", "function data() return { en = { n = \"My wagon\" } } end");
    Put(old / "res/models/model/vehicle/waggon/w.mdl",
        "function data() return { lods = { { children = { { id = \"w/body.msh\", type = \"MESH\", transf = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 } } },"
        " matConfigs = { { 0 } }, static = false, visibleFrom = 0, visibleTo = 400 } }, metadata = { } } end");
    Put(old / "res/models/mesh/w/body.msh",
        "function data() return { matConfigs = { { 0 } }, subMeshes = { { indices = { }, materials = { \"w/paint.mtl\" } } }, vertexAttr = { } } end");
    Put(old / "res/models/mesh/w/body.msh.blob", std::string("\x01\x02\x03\x00\x05", 5));
    Put(old / "res/models/material/w/paint.mtl",
        "function data() return { order = 0, type = \"PHYSICAL\", params = { map_albedo = { fileName = \"models/w/paint.tga\", type = \"TWOD\" } } } end");
    Put(old / "res/textures/models/w/paint.tga", "TGA");
    std::string before = Get(old / "res/models/mesh/w/body.msh");

    r = tf3api::mod_converter::Run(game, log);
    fs::path out = game / "mods" / "release" / "legacy_my_old_wagon_1";
    Check(r.found == 1 && r.converted == 1 && r.failed == 0, "the old mod is converted");
    Check(Has(Get(out / "mod.json"), "\"name\": \"My wagon\""), "mod.json carries the translated name");
    std::string model = Get(out / "content/res/models/model/vehicle/waggon/w.mdl");
    Check(Has(model, "mesh = \"w/body.msh\"") && Has(model, "\"w/paint.mtl\""), "the model is a tree with the material on the node");
    Check(!Has(Get(out / "content/res/models/mesh/w/body.msh"), "materials"), "the mesh keeps only its geometry");
    Check(Get(out / "content/res/models/mesh/w/body.msh.blob") == std::string("\x01\x02\x03\x00\x05", 5), "the blob is copied byte for byte");
    Check(Has(Get(out / "content/res/models/material/w/paint.mtl"), "converter/default_mga.dds"), "the material is written in the old form with the missing map filled in");
    Check(fs::file_size(out / "content/res/textures/converter/default_mga.dds") == 192, "the plain texture is written as binary");
    Check(fs::exists(out / "conversion_report.txt"), "a report is written");
    Check(Get(old / "res/models/mesh/w/body.msh") == before && !fs::exists(old / "conversion_report.txt"), "the old mod is untouched");
    Check(!fs::exists(game / "legacy_mods" / ".tf3api_stage"), "no staging folder is left behind");

    // 3. the next launch does nothing
    r = tf3api::mod_converter::Run(game, log);
    Check(r.found == 1 && r.converted == 0 && r.upToDate == 1, "a converted mod is not converted again");

    // 4. a changed old mod is converted again
    Put(old / "res/textures/models/w/extra.tga", "TGA2");
    r = tf3api::mod_converter::Run(game, log);
    Check(r.converted == 1 && fs::exists(out / "content/res/textures/models/w/extra.tga"), "a changed old mod is converted again");

    // 5. a folder the converter did not make is never replaced
    fs::path foreign = game / "mods" / "release" / "legacy_other";
    Put(foreign / "mod.json", "{}");
    Put(game / "legacy_mods" / "Other" / "mod.lua", "function data() return { info = { name = \"x\" } } end");
    Put(game / "legacy_mods" / "Other" / "res/textures/a.tga", "TGA");
    r = tf3api::mod_converter::Run(game, log);
    Check(r.failed == 1 && Get(foreign / "mod.json") == "{}", "an existing mod folder of someone else's is left alone");

    // 6. a folder with nothing to convert
    Put(game / "legacy_mods" / "Broken" / "mod.lua", "function data( return");
    r = tf3api::mod_converter::Run(game, log);
    Check(r.found == 3 && r.failed == 2, "three old mods are seen; the empty one fails without stopping the others");
    Check(!fs::exists(game / "mods" / "release" / "legacy_broken"), "a folder with nothing to convert does not become a mod");

    // 7. the rules built into the binary are the ones in the repository
    if (argc > 1) {
        std::string file = Get(fs::path(argv[1]) / "converter" / "convert.lua");
        std::string unix;
        for (char c : file) if (c != '\r') unix += c;
        size_t size = 0;
        const char* built = tf3api::mod_converter::EmbeddedRules(&size);
        Check(std::string(built, size) == unix, "convert_lua.inc is up to date with converter/convert.lua (run tools/embed_converter.py)");
    }

    fs::remove_all(game);
    std::printf("%d checks, %d failed\n", g_checks, g_failed);
    return g_failed == 0 ? 0 : 1;
}
