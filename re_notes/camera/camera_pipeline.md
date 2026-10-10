# Camera pipeline — static RE notes

**Build:** development install 40408 (`TransportFever3.exe`, x64, image base `0x140000000`). Addresses below are for this build only.
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

## What this means
- **Every camera driven through the normal controller** (map camera, follow camera, and therefore anything a mod sets with `api.gui.camera.setCameraData` / `focusPosition` / `followEntity`) is kept at or above `max(water level, terrain)` near the camera. A script-driven "own camera" would hit the same limit — it cannot replace the cockpit view underground.
- The cockpit view writes its eye directly (no terrain clamp — it works in tunnels), but is still pushed up once the vehicle goes below the **water level**. The exact cockpit-side water clamp has not been pinned yet; the remaining camera-controller caller of the water getter is in `0x1407c745e` (`Consume`, call at `0x1407c8260`) — next thing to decompile.
- A fix is therefore native: change the water-level floor for the cockpit path (and optionally the follow path). Deferred until the native tier is reopened.
