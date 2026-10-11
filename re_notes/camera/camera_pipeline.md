# Camera pipeline — static RE notes

**Build:** 40408 (`TransportFever3.exe`, x64, image base `0x140000000`). Addresses below are for this build only.
**Method:** static only — string/RTTI search, `.pdata` function bounds, call-site scans (Python + capstone/pefile), Ghidra 12.1.2 headless decompile with `-noanalysis` on a scratch copy with the exception directory blanked (Ghidra's PE loader crashes on this exe's `.pdata`: `PEx64UnwindInfo` null). Nothing was injected or run.

## Classes (RTTI / assert strings)
- `UI::CameraManager` — owner; keyframes/recording (`InsertKeyFrame`, `RecordKeyFrame`, `DoStep`).
- `UI::CameraController` — the generic map/orbit camera (`Apply`, `Consume`, `Step`, `SetManualCamera`). Code lives around `0x1407c6000-0x1407cc000`.
- `UI::CameraAction` — camera tool / cinematic recording.
- `UI::FollowAction` — follow + **cockpit** camera. Source path in asserts: `ug/urban_games/train_fever/src/Game/UI/Actions/FollowAction.cpp` — same code tree as Train Fever (TF1), i.e. inherited, largely unchanged code. Constructor takes `CTerrain&`, `CGame*`, `CGameUI*`.
- `model_metadata::CameraConfig` / `CameraConfig::Position` — the per-model cockpit positions (`metadata.cameraConfig.positions`), read by `FollowAction::FetchCamPositionsFromModelData` (lambdas at `0x14052f2b0`, `0x14052f7f0`).

## FollowAction::SetCameraData — `0x140533840` (≈6 KB)
- Picks the active cockpit position from `m_cameraPositions` (assert `!m_cameraPositions.empty()`), gets the vehicle's model instances (`MODEL_INSTANCE_LIST` fat instances, assert `!mil.fatInstances.empty()`), and writes the camera into a struct at `*(this+200)`:
  - `+0x00..0x08` eye position (x, y, z)
  - `+0x0c..0x14` forward vector
  - `+0x18..0x20` up vector
  - `+0x24` an angle (used by the orbit helper below)
- Branches on `railVehicle` / `airVehicle` model metadata.
- **No terrain or water reference in this function** (no call to the water-level getter anywhere in the FollowAction code range). The push-up happens downstream.
- `0x140533560` — helper for the non-cockpit follow (orbit around the vehicle).

## Terrain / water primitives
- `0x140869310(x)` → returns the `CTerrain` object.
- `0x140388d30(terrain)` → `return *(float*)(terrain + 0x48);` — **the map's water level** (single float, no position argument). 49 callers in the exe.
- `0x140388660(terrain, &xy)` → terrain height at a 2D position.

## Camera ground height — `0x1407c8ce0`
```
t      = clamp((distance - 800) / 700, 0, 1)           // 800 m, 700 m
s      = t*t*(3 - 2t)                                    // smoothstep
ground = max(waterLevel, lerp(terrainH(xy), waterLevel, s))
```
So close in (< 800 m camera distance) the "ground" is `max(water, terrain)`; zoomed out (> 1500 m) it is the water level. **It is never below the water level.**

## Orbit / follow camera step — `0x1407c8e40`, `0x1407c691b` (+ split chunks `0x1407c6bcc`, `0x1407c6db2`)
- Camera state: `+0xb4` followed entity (−1 = none), `+0xe4/+0xe8` center xy, `+0x104` distance, `+0x108` angle, `+0x10c` pitch blend, `+0xa8` follow-target interface (vtable `+0x10` returns the entity position).
- Center height = `ground(center)` (above); when following, `max(water, lerp(terrain, water, s), entityZ)` — so the follow camera rides the terrain surface over a vehicle in a tunnel (matches long-standing TF2 player reports: "it has always done that while following a vehicle in a tunnel").
- Then `centerZ += 2.5`; eye height is pushed up to at least `ground(eye) + 4.0` (constant at `0x143677b5c`), and along the eye→center line in up to 100 steps.
- `0x1407c72b0`, `0x1407c8d80` — distance→pitch helpers (`max(0, distance - 16)`).

## Cockpit depth clamp — FOUND (2026-10-10)
- Per-frame cockpit step: `FollowAction` vtable `[4]` = `0x140532c80` (vtable at `0x1436b23f0`, recovered from RTTI). It applies the WASD/mouse offsets, calls `SetCameraData`, then the post-step `0x140530070`.
- Post-step `0x140530070`: builds eye/target/up via `0x1405326d0`, stores height-above-terrain at camera struct `+0x3c/+0x38`, then hands eye/target/up/FOV to the render camera (`0x1403077c0` / `0x1403078f0` / `0x1403078c0`).
- **`0x1405326d0` ends with an absolute world-height clamp on the eye: `eyeZ = clamp(eyeZ, -100.0, 6000.0)`** (`.rdata` `0x1436b2fcc` = -100, `0x1436b2fc4` = 6000). This is the bug: vanilla tunnels can go below world height -100, the eye is pinned at -100 and the view ends up above the terrain. (In the user's save the -100 floor happened to sit near the water surface, which is why it looked like a water clamp.)
  ```
  0x140532be9  C5 FA 10 05 ..        vmovss  xmm0, [-100]
  0x140532bf1  C4 C1 78 2F C3        vcomiss xmm0, xmm11
  0x140532bf6  77 0D                 ja      store            ; floor
  0x140532bf8  C5 FA 10 05 ..        vmovss  xmm0, [6000]
  0x140532c00  C4 C1 7A 5D C3        vminss  xmm0, xmm0, xmm11
  0x140532c05  C4 C1 7A 11 46 08     store: vmovss [r14+8], xmm0
  ```
- `0x1405326d0` has exactly two callers, both `FollowAction` (`0x14053009e`, `0x140530690`). The -100 constant itself is shared by 8 unrelated functions (identical-constant folding), so the constant must NOT be patched — only the jump.
- **Fix shipped in the native tier** (`native/src/camera_fix.cpp`): `77 0D` → `90 90`, located by a unique signature, byte-verified before writing, restored on unload, `[Camera] CockpitDepthFix` in `tf3api.ini` (default on). The 6000 ceiling and NaN behaviour are unchanged.

## Other camera notes
- Every camera driven through the normal controller (map, follow, anything a mod sets via `api.gui.camera`) keeps its focus/eye above `max(water level, terrain)` (`0x1407c8ce0`) — a script-driven camera cannot go underground. Not related to the cockpit bug.
- The follow camera still rides the terrain over tunnels (controller behaviour, unchanged, matches TF2).
