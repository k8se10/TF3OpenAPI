# Where a mod's "Source" comes from (build 40420, 2026-10-15)

Read from the executable (Ghidra, names from the game's own assertion texts) and the game's interface scripts.
Nothing tried in the game yet.

## The engine: one scan per folder, each folder stamped with a source name

`modhub::(anonymous)::UpdateLocalInstallations` (0x142f37350, `LocalModHubBackend.cpp`) scans the local mod
folders with one helper, `ScanFolder` here (0x142f30410), called once per folder:

```
ScanFolder(ctx, folders + 0x80, "BuiltInMods", out)   -- only when that folder is set (mods/testing/)
ScanFolder(ctx, folders + 0x00, "BuiltInMods", out)   -- mods/ (the install's mods/release)
ScanFolder(ctx, folders + 0x20, "DLC",         out)   -- dlcs/
ScanFolder(ctx, folders + 0x40, "StagingArea", out)   -- the user-data staging area
ScanFolder(ctx, folders + 0x60, "UserMods",    out)   -- the user-data mods folder
```

- `folders` holds paths of 0x20 bytes each (wide strings; the backend's constructor 0x142f24cb0 sets `mods/` and
  `dlcs/` and copies the three user-data paths it is given).
- The source name is a pointer to a global `std::string` (`s_BuiltInMods_143ce9c60`, `DAT_143ce9ca0` = "DLC" ...).
- `ScanFolder` does nothing when the folder does not exist (`file_system::Exists`), else lists its sub-folders and
  hands each to 0x142f351b0 with the folder and the source name: every mod found there gets that source.

So **a mod's source is purely the folder it was found in.** The Deluxe Upgrade is "DLC" because it sits in
`dlcs/`; everything in `mods/release` is "BuiltInMods", ours, converted ones and the mod.io mods installed
there alike.

`ModRep::RefreshModList` (0x142f9ab10) ranks the sources when two mods have the same id
("Multiple ({}) mods with same id found {}, the one from {} has been selected"): UserMods, StagingArea,
BuiltInMods, DLC, then the remote backends (mod.io ...). An unknown source in that ranking would fail its
assertion `chosen >= 0 && chosen < (int)searchResult.size()` - so a mod of a new source must never share its id
with another.

## The interface: source name -> icon and title

`mod_manager_react_util.getSourceInfo(source)` (`gui/menu/mod_manager_react_util.tl`) maps the name:
"UserMods" -> `source_manual_installed.tga` "User Mod"; "StagingArea" -> `source_staging_area.tga` "My Mods";
"BuiltInMods" -> `source_system.tga` "Built-In"; "DLC" -> `source_dlc.tga` (the gold icon) "DLC"; anything
else -> the icon and title of the mod hub backend whose `getDescription(id).name` equals it, else
`source_system.tga` "System". The mod list's Source cell (`TableCellModSource`, `gui/menu/mod_selector_page.tl`)
is that icon with the title as its tooltip. The mod list also calls `api.modhub.getBackendIdForSource(source)`
for a mod's details (lines 260 and 304) - what it answers for a name it does not know is not read yet.

## Our own source - how it would be done

1. Native: hook `ScanFolder`; after its call for "DLC", call it once more with our own folder
   (`<game>\tf3api_mods\`, a wide string of the same form) and our own source name ("TF3OpenAPI", a
   `std::string`). Mods found there get that source. Our mods and the converter's output move to that folder.
2. Interface: `getSourceInfo("TF3OpenAPI")` must give our icon and title. That needs a wrap of that one module
   function in the menu's Lua state - the same reach into the game's interface modules that the "API" badge
   needs (see below).
3. To read first: `getBackendIdForSource` for an unknown name (the mod details panel), and whether saves record
   a mod's source (a save made with a mod from `mods/release` loaded when it is in `tf3api_mods`).

Consequence to weigh: without the native layer the game does not scan `tf3api_mods` at all, so our mods and the
converted ones are simply not there (a save using them reports them missing through the game's own dialog);
the notice window cannot show, because its script is in those mods.

## Built (2026-10-15): our mods folder as a source

`native/src/own_mods.cpp`: our mods are packed into the DLL, written to `%LOCALAPPDATA%\TF3OpenAPI\mods\` at
launch, and the scan helper above is hooked (after its "DLC" call it scans that folder under the name
"TF3OpenAPI"). The folder is also where other authors' TF3OpenAPI mods can be put. Offline test: 2,040 files
extracted and compared byte for byte with the repository. Not yet seen in the game.

## The icon (2026-10-15)

`ModFilterBaseFileSystem` only serves the mods in its current set and asserts (`Filter(modId)`) when asked for a
file of another, so an icon taken from one of our mods' files would depend on that mod being active. The icon is
therefore carried by the DLL as raw pixels (`native/src/source_icon.inc`, 32 x 32 RGBA, made by
`tools/make_notices.py`): the bridge's script wraps `mod_manager_react_util.getSourceInfo` (answers the marker
"tf3api:source_icon" and the title "TF3OpenAPI" for our source) and `builtin.ImageView` (an ImageView asked for
that marker gets `data` and `size` instead of a path; `UI::ImageView::SetImage` takes 3 or 4 bytes a pixel).
Unproven in the game: the byte order (RGBA assumed; a wrong one shows as orange instead of blue), that `Vec2i`
is `api.type.Vec2i`, and that wrapping the builtin recipe by a proxy table leaves its other uses intact.

## Converted mods: one source for each game they come from (2026-10-15)

The converter writes a converted mod into `%LOCALAPPDATA%\TF3OpenAPI\converted\<trf|tf1|tf2>\` by the game its
old mod is from, and the scan hook adds those three folders under their own source names (`TF3OpenAPI-TrF`,
`-TF1`, `-TF2`), each with its own icon and title in `getSourceInfo` (`tools/make_notices.py` makes the four
icons). The game is told apart by the old mod's own files: `info.lua` without `mod.lua` is Train Fever, a
top-level `version` field in its models is Transport Fever 2 (all eight TF2 mods here have it, the P86 from
Transport Fever 1 does not).

## The earlier "API" badge attempt

The bridge runs a script in every new Lua state that waits for the game's module loader (`base/init.lua`:
`ug_require`, `_ug_loadedModules`) to load `gui/main/react.lua` and wraps `react.RegisterRecipe` for
`TableCellModSource`. In the first two runs no step of it was logged: the react module was never caught. The
build of `97b73a3` logs how it set itself up in each state; the next run says where it stops.
