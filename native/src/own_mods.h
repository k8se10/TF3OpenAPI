#pragma once

#include <filesystem>

// The TF3OpenAPI mods folder, and TF3OpenAPI's own mods in it.
//
// %LOCALAPPDATA%\TF3OpenAPI\mods\ is a mods location of its own: the game's mod scan is made to look there too,
// as a source of its own ("TF3OpenAPI"), and mods for TF3OpenAPI by other authors can be put there like in any
// mods folder. TF3OpenAPI's own mods (mod/tf3api_*) are carried by the DLL (tools/embed_mods.py) and written
// there at launch - only the files that are missing or have changed. A list of what was written
// (tf3api_extracted.txt in that folder) is kept so that a file TF3OpenAPI wrote and no longer ships is removed,
// and nothing else in the folder is ever touched.
//
// [OwnMods] Enabled=1 in tf3api.ini switches it on (off by default until seen working in the game).
namespace tf3api::own_mods {

// Writes the mods out. Files only (safe from DllMain). Returns the folder, or an empty path when switched off,
// nothing is packed in, or it failed (logged).
std::filesystem::path Extract();

// Hooks the game's mod folder scan so that it also scans the folder Extract returned. Needs MinHook.
void Install();
void Uninstall();

} // namespace tf3api::own_mods
