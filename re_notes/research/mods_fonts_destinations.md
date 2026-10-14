# Mod sources, label fonts, line destinations (research, build 40420, 2026-10-15)

Read from the executable (Ghidra, names recovered from its own assertion texts), the game's data and the
installed mods. Nothing tried in the game yet unless said.

## 1. How the game finds and reads a mod - and how converted mods could be kept from the player's hands

**What the game does (read):**

- Mods come from "modhub" backends: a local one (`modhub::LocalModHubBackend`, the `mods/release`-style folders),
  mod.io (`ModioModHubBackend`) and Steam Workshop. A mod a backend reports is "added to filesystem" (log text
  "new ModHubMod was installed and will be added to filesystem").
- The game reads everything through its own virtual file system (`framework/filesystem`):
  `DefaultBaseFileSystem::AddModDir`, `DirectBaseFileSystem::AddModDir / GetPhysicalPath`,
  `CachedBaseFileSystem::AddModToFileCache`, with `ModFilterBaseFileSystem` on top. A mod is added as a folder;
  `AddModDirToCache` (0x143001050) walks it and calls `AddArchive` (0x143000400, "Adding archive {}") for the
  archives the mod names.
- **A mod can be packed.** `_content.json` beside `mod.json` lists `archives` - each `{ fileName = "<x>.zip",
  entries = { { fileName, fileSize, headerOffset }, ... } }` - and loose `files`. The archives are plain zip files
  in the mod's `content` folder, stored without compression; `headerOffset` is each entry's local header offset.
  Urban Games' own campaign missions in `mods/release` are shipped exactly so (13 archives each), and the base
  game itself (`base/_content.json`, 1,092 archives). The game's own cooker (`--and-cook`) writes this form.
- The executable reads files only through `CreateFileW` / `ReadFile` / `SetFilePointerEx` and the C runtime's
  `fopen` / `fread`; no file is mapped into memory.

**Also read (40420):** `BuildModCache` (0x1430019d0) reads a mod's `_content.json` when there is one ("Reading
content cache from json for dir '{}'") and takes the mod's files from it alone; without one the folder is scanned.
An archive is opened by `io::ZipFileReader` (0x143020c80) through a C++ file stream and its own zip directory is
read. The game's own archives begin with the bytes `UG` in place of the first `PK` signature.

**Status 2026-10-15: the user approved this; it was not built** (the encrypted packing and the decryption of reads
were not carried on with). Converted mods stay plain files, offered while their old mod is in `legacy_mods`, and
now carry a notice window (below).

**Proposal (as approved, not built):**

1. The converter writes a converted mod in the packed form: `content/<group>.zip` (stored) and `_content.json`
   with the index - the game's own format, and far fewer files on disk.
2. The archives are written **encrypted** (a stream cipher, so any byte range can be decrypted on its own). The
   native layer hooks `CreateFileW` / `ReadFile` / `SetFilePointerEx` (and `ReadFile` with an offset) for those
   files only and decrypts what the game reads. To the player the files are unreadable; to the game they are
   ordinary zips.
3. **The key comes from the old mod itself** (a hash of its files in `legacy_mods`): without the original mod
   present the archives cannot be read at all - the "requires the original author's mod" rule from 2026-10-12,
   now enforced by the files themselves rather than by a script that hides menu entries.
4. Honest limits, for the docs: a determined player can still take the data out of the game's memory; forks of
   our code are not bound by any of it. It is a deterrent, as decided.

Open: whether `_content.json`'s index must match the archive byte for byte (it is read instead of the zip's own
directory - cheaper for us, but every offset must be right); whether the game checks anything else
(`_metadata`, `texture_metadata_cache.lua`) for packed mods. Both are checked by converting one mod this way.

## 2. A font of the mod's own on model labels (Isotherm Sans on the P86 blind)

**What the game does (read):**

- A model label has a `font` field (the Model Editor lists `labelList.labels.*.font`, a string). The model loader
  keeps it with the label and writes it back only when it is set (0x140d50420); none of the game's own models,
  nor any Transport Fever 2 model, sets it.
- The label renderer (0x142c39200) takes, for each label, its font: when empty, the language's default (from the
  language data); otherwise the label's own, and asks `CFontManager::GetFont` (0x142760090) for it at the label's
  size. Fonts are cached by name and size.
- The language files (`locale/<lang>.lang.lua`) name the interface fonts by paths under `locale/`:
  `fontMap = { regular = "Lato2OFL/Lato-Regular.ttf", bold = "Lato2OFL/Lato-Bold.ttf", ... }`; the font files
  are in `locale.zip` (`locale/Lato2OFL/...`, `locale/Noto/...`).
- A font that cannot be read ends in "Could not read font" (`FontManager.cpp`) - probably a fatal error.

**Reading (unproven):** the label's `font` is a path of the same kind, looked up under `locale/`; a mod shipping
`content/locale/<folder>/<font>.ttf` would add a font the label can name.

**What the original used:** the old P86 mod has no labels and no font; "Stratford" is painted on its picture,
upside down, about 14 points high, in a bold sans too small to name. Unrecoverable.

**A missing font stops the game:** `UI::CFontManager::GetFont`'s error lambda (0x14275ffd0) logs "Could not read
font" as a warning and then does not return.

**Built (2026-10-15, user: Isotherm Sans, built into the DLL):** see PATCHNOTES. The font is written at
`content/locale/tf3api/` and `content/tf3api/` of the converted mod, because which base the label's name is
looked up from is not read; the labels name `tf3api/IsothermSans-Bold.ttf`. Behind `[Converter] LabelFont`.

**Test first proposed (superseded):** the P86 remaster's labels get `font = "Lato2OFL/Lato-Bold.ttf"` (a
file the game has - if the path form is wrong the worst case is the error above when the P86 is shown, so the
test is behind a switch). If the text turns bold, the doubled labels go, and Isotherm Sans can be shipped the same
way (the font file from the player's own folder, never in our repository - it is the user's font).

## 3. Line destinations as native behaviour (replacing the Destination Displays mod)

**What the Destination Displays mod does (read for the facts, nothing of its code used):** per line it keeps the
ticked stops and their display texts in its game script's state; every few seconds it **renames every vehicle**
(`makeEntitySetNameCmd`) to "<number> [designator] <destination>", so that the vehicles' NAME labels show the
destination; it publishes `apiLineDestinations` / `apiVehicleDestinations` for other mods. Renaming vehicles
means simulation commands all the time, and the vehicles' real names are lost while it runs.

**Proposal (not built):**

- **Data:** per line, the destination stops and their display texts, in our own game script's state (saved with
  the game), keyed so that they survive edits of the line (stop + its neighbours, as that mod does).
- **Interface:** the same controls in the game's line window (a plugin at the line stops list), plus the default
  when nothing is ticked (first stop and the stop half-way round).
- **Native part - the "native behaviour":** the label renderer is where a vehicle's text is chosen; the native
  layer answers a destination label itself, from the line's destinations and the vehicle's next stop, without
  renaming any vehicle and without simulation commands. Which label kind carries it (NEXT_STOP? a CUSTOM label
  with a marker?) and where the renderer takes a label's text from (the entry at `+0x78` / `+0x1e*4` of the
  renderer's list) is the next thing to read.
- **Boards, the street map and the converter's remasters** read the same data.
- Saves made with the Destination Displays mod: its ticked stops can be read from its state once and taken over.
