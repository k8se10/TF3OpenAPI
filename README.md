# TF3OpenAPI

> Formerly "TF3 Optimizations + DLSS". Files and settings still use the old short name `tf3opt`.

**An open native modding platform for Transport Fever 3, growing out of a set of performance fixes.**

Transport Fever 3's official modding API covers content: models, scripts, the interface, game rules. It does
not reach the engine: the renderer, the frame loop, drawing in the world, the engine's internal data, or
files on disk. TF3OpenAPI is a native layer that sits inside the game process and reaches those parts
directly. Today it uses that reach for its own fixes and tools. The plan is to open it up, step by step,
as a documented API that any mod can build on.

It is unofficial, free, and not affiliated with Urban Games or Paradox Interactive.

---

## What it is meant to become

Three layers, built in this order:

1. **Native core** — a DLL loaded by the game that locates engine functions at startup and hooks or calls
   them. This exists and is where the current fixes live.
2. **A bridge to the game's scripts** — functions the DLL registers inside the game's Lua, so ordinary
   script mods can ask the native side for things the official API cannot do, and the native side can call
   back into scripts. Not built yet; the engine entry points for it have been located.
3. **A public API on top of that bridge** — stable, named, versioned functions with documentation and
   example mods. Mods call the API; engine addresses and layouts stay inside the DLL, so a game update is
   fixed in one place and mods keep working. Not built yet.

Each capability is added because a real feature needs it, then generalised. Nothing is exposed on
speculation.

Principles the platform holds to:

- **Read-only and render-only by default.** Anything that could change the simulation is marked as such and
  off unless asked for. Saves made with TF3OpenAPI's own features load in the unmodified game.
- **A mod's mistake must not take the game down silently.** Arguments are checked at the boundary and
  failures are written to a log.
- **Survive game updates.** If one function cannot be located on a new build, that function reports itself
  unavailable and the rest still loads.
- **Open.** Public source, documented API, usable by other authors without asking.

---

## Which game build this is developed against

**TF3OpenAPI is being developed against the launch build of Transport Fever 3, build 40408
(29 September 2026). It has not yet been run on the current retail build, 40420 (the first stability update,
8 October 2026).**

No engine address is hard-coded. Every hook is found at startup by signature scanning: the DLL searches
the game's code for a byte pattern that identifies the function. A pattern must match exactly once; if it
matches nowhere or more than once, that feature is skipped and the reason is written to `tf3opt.log`. The
game is never patched on disk.

Because of this, most features should carry forward to newer builds unchanged, and a feature whose
function was rewritten should switch itself off rather than misbehave. That is the design, not a test
result: until it has been run on 40420 or later, treat anything beyond 40408 as unverified.

Windows only. The script-only mods in `mod/` do not depend on the DLL and are not tied to Windows.

---

## What exists today

Status words used below: **verified** = run in the game and seen to work; **built** = written and tested
outside the game only; **planned** = not started.

### Fixes

| Feature | Status | Notes |
|---|---|---|
| Cockpit camera depth fix | verified | The cockpit view is clamped to a world height of -100 m, so it breaks in deep tunnels. This removes the lower clamp. |
| Shadow map resolution limit | verified | The game sizes shadow maps from the screen (4096x4096 at 1080p, 1440p and 4K on High). This sets a maximum. |
| Town label fix (`tf3opt_hud_fix`, script mod) | verified | Each town label fetched the state of every town to read its own. Now fetched at most once a second. |
| Terrain occlusion culling | verified to run, **no measured benefit** | Off by default. See "Honest results". |

### Diagnostics

| Feature | Status | Notes |
|---|---|---|
| Sampling profiler | verified | CPU time per thread and per function, including which script file and line the time belongs to. Can run continuously. |
| Vulkan frame statistics | verified | Frame times, time spent waiting in Vulkan calls, draw calls, render passes by size, texture and buffer traffic, GPU load. |
| Allocation profiler, `bad_alloc` probe | verified | For memory investigations. Off by default. |

### Road names and map export (in progress)

| Piece | Status |
|---|---|
| Grouping road segments into streets, generating names and road numbers (British conventions) | built |
| Map export to interactive HTML, SVG, GeoJSON and OpenStreetMap XML | built |
| Road names drawn on the roads in the game, by the native layer | planned |
| Click a road name to open its panel: rename, road type, label style, statistics | planned |
| "Adjust road" tool: a green line along the road, drag either end to change its extent | planned |
| Names and types saved with the game | planned |
| Road systems for other countries as editable profiles (UK, US, Germany, France, generic) | planned |
| Per-quantity unit settings for the whole game interface | planned |
| Floating button and main settings panel | planned |

### Further out

- DLSS / upscaling through NVIDIA Streamline. NVIDIA-only, opt-in, and only useful where the graphics card
  is the limit.
- A converter for Train Fever / Transport Fever 1 and 2 asset mods.
- Maps that can grow beyond their original bounds. Exploratory.

---

## Honest results

All figures are from one machine (RTX 2080 Ti, Ryzen 5 9600X, 2560x1440, highest settings) and one
early-to-mid game save, measured with the built-in profiler. They are single sessions, not averaged
benchmark runs, and will differ on other hardware and saves.

- **Shadow map limit, cockpit view.** At 4096x4096 the game rendered 27 shadow passes per frame, about 77%
  of all pixels drawn. Limiting to 2048 took the cockpit view from roughly 20 fps to roughly 40 fps.
  Going lower gave nothing further. No change in the zoomed-out view.
- **Town label fix, zoomed-out view.** The label script's CPU cost fell from 3.4-3.7 s per 10 s to under
  0.1 s. Frame time went from 28-30 ms to 25-26.5 ms, about 10%.
- **Occlusion culling.** It removes 17-18% of the objects it tests, with no visible change in frame rate.
  The frame was limited elsewhere. It stays in the tree as groundwork and is off by default.
- **A draw-distance and LOD-distance mod** in the style of the Transport Fever 2 "Performance tuning" mod
  was tried and withdrawn: visible loss of detail for little gain. It is kept in `mod/` as shelved.

What the profiling showed about the game on this save: the cockpit view is limited by the graphics card,
mostly by shadow rendering and full-screen passes; the zoomed-out view is limited by the main thread, where
drawing and updating the interface cost several times more than the 3D scene. A third-party script mod was
also found using 39% of the main thread during its scans, which is the kind of thing the profiler is for.

---

## Installing

Nothing here is packaged for release yet. For development builds:

1. Build `native/tf3opt.vcxproj` (x64, Release). The output is `winhttp.dll`.
2. Copy `winhttp.dll` next to `TransportFever3.exe`. The game loads it in place of the system library of
   that name, and it passes every call through to the real one.
3. Optionally put a `tf3opt.ini` next to it (see below). Without one, defaults apply.
4. Script mods: copy a folder from `mod/` into the game's `mods` folder and enable it for a save.

To remove: delete `winhttp.dll`, `tf3opt.ini` and the `tf3opt` log and profile files from the game folder.
The game and its saves are left as they were.

### Settings (`tf3opt.ini`)

Every feature has its own switch. A feature stays off by default until it has been verified and measured.

| Section | Key | Meaning |
|---|---|---|
| `[Camera]` | `CockpitDepthFix` | 1 = cockpit view follows vehicles below -100 m |
| `[Shadows]` | `MaxResolution` | Largest shadow map edge in pixels; 0 = unchanged |
| `[Shadows]` | `ToggleKey` | Key that switches the limit off and on while playing (118 = F7) |
| `[Occlusion]` | `Enabled`, `ToggleKey`, ... | Terrain occlusion culling and its tuning |
| `[Profiler]` | `Enabled`, `Continuous`, `Seconds`, `RateHz`, `Key`, `Keep`, `VulkanStats` | Profiler and frame statistics |
| `[Debug]` | `BadAllocProbe`, `AllocProfiler` | Memory diagnostics |

Logs go to `tf3opt.log`, profiler reports to `tf3opt_profile.txt` and the `tf3opt_profiles` folder, all
next to the game executable.

---

## Known limitations

- Developed and tested on one game build (40408) and one machine. See above.
- The memory growth seen in the cockpit view deep underground is not explained yet.
- The road-name work has only run against synthetic test data so far.
- The profiler slows the game while it samples; continuous mode is a development aid, not something to
  leave on.
- No installer, no releases yet.

---

## Distribution

TF3OpenAPI will be released on **Nexus Mods and GitHub**. The native layer will not be published through
the in-game mod browser (mod.io), whose rules require mods to use only the official scripting API. Script
mods that need the native layer will say so.

It is and will stay free. It contains no game files and no game code.

---

## Repository layout

| Path | Contents |
|---|---|
| `native/` | The DLL: hooks, fixes, profiler, Vulkan statistics |
| `mod/` | Script mods: `tf3opt_hud_fix`, `tf3opt_road_names`, `tf3opt_performance` (shelved) |
| `tools/` | `road_map.py` (map export), `annotate_profile.py`, tests |
| `re_notes/` | Reverse-engineering notes: renderer, camera, shadows, Lua, map export |

---

## Credits and licences

- [MinHook](https://github.com/TsudaKageyu/minhook) by Tsuda Kageyu — function hooking (BSD 2-Clause),
  with a local change so functions compiled with AVX instructions can be hooked.
- [Masked Software Occlusion Culling](https://github.com/GameTechDev/MaskedOcclusionCulling) by Intel
  (Apache 2.0).
- The draw-distance experiment followed the idea of "Performance tuning" for Transport Fever 2 by okeating.
  No code was taken.
- The road-name interface is modelled on how Cities: Skylines presents road names. No code or assets were
  taken.

Transport Fever is a trademark of Urban Games. This project is not endorsed by or affiliated with Urban
Games or Paradox Interactive.
