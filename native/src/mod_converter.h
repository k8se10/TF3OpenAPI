#pragma once

#include <filesystem>
#include <functional>
#include <string>

// Converts older Transport Fever mods at launch.
//
// Old mods are put in <game>\legacy_mods\<mod folder>. Each one is converted once into
// <game>\mods\release\<legacy_...> by the rules in converter/convert.lua (built into the DLL and run by a Lua
// interpreter of our own - the game's is not usable this early). The source folder is only read.
// Runs before the game lists its mods, so a converted mod is in the mod list in the same launch.
namespace tf3api::mod_converter {

struct Result {
    int found = 0;       // old mods in the inbox
    int converted = 0;   // converted in this run
    int upToDate = 0;    // converted in an earlier run and unchanged since
    int failed = 0;
};

using LogFn = std::function<void(const std::string&)>;

// gameDir: the folder with the game's executable. Creates legacy_mods when it is missing.
// Never throws; problems are logged and counted.
// stations: also convert Transport Fever 2 station constructions and modules (experimental; a construction file
// the game cannot read can keep a save from loading, so this is off unless asked for).
// stationDebug: converted stations write the walking lanes of the station last built to
// <game>\tf3api_out\station_lanes_<mod>.txt (through the script bridge), for finding lane problems.
// remasters: the changes the converter has for particular old mods are made (converter/remasters.lua)
// glassParts: a body whose picture holds paint and glass gets its glass drawn by a second, blended copy of
// each part (experimental)
// packTextures: pictures written with mip levels are packed as the game's own are (DXT1 / DXT5 / two-channel
//             normal maps) instead of plain 32-bit ones: a quarter to an eighth of the size
Result Run(const std::filesystem::path& gameDir, const LogFn& log, bool stations = false, bool stationDebug = false, bool remasters = true,
           bool glassParts = false, bool packTextures = false);

// The rules as built into this binary (for the test, which checks them against converter/convert.lua).
const char* EmbeddedRules(size_t* size);

} // namespace tf3api::mod_converter
