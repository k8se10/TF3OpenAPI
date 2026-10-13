# Known issues

One entry per problem. Each opens with its status (Open / Investigating / Partially Resolved / Resolved /
Deferred / Roadmap Idea), updated in place; history follows as dated rounds. "PN" refers to an entry in
`PATCHNOTES.md` (section and number). Build 40420 unless stated.

## Index

| # | Problem | Status |
|---|---|---|
| 1 | Memory growth in the cockpit view deep underground | Investigating |
| 2 | 27 shadow passes for 4 cascades in the cockpit view | Open |
| 3 | Zoomed-out view limited by the main thread | Partially Resolved |
| 4 | Occlusion culling removes objects but gains no frame time | Deferred |
| 5 | Road labels are not hidden by terrain or buildings | Open |
| 6 | A click on a road label also reaches the game | Open |
| 7 | Saving road names with the game untested end to end | Open |
| 8 | Lua exceptions in the sliced road naming | Deferred |
| 9 | A road under or over another took its name | Resolved |
| 10 | Text on models breaks up into dots at a distance | Investigating |
| 11 | Converting old mods shows nothing for up to half a minute | Open |
| 12 | Converted textures are uncompressed and large | Partially Resolved |
| 13 | Old content kinds not converted (bridges, tunnels, depots, other stations, ship and aircraft animations, `headLights`) | Open |
| 14 | Converted road vehicles: wheels, door animations, dirt textures, label anchoring | Investigating |
| 15 | Painted-in window glass as separate parts breaks a train | Deferred |
| 16 | Buying a converted vehicle stopped the game | Resolved |
| 17 | Graphics device lost with a departure board on screen | Resolved |
| 18 | Departure boards could not be clicked or set up | Resolved |
| 19 | Departure boards in asset groups all show one screen | Open |
| 20 | Board window's live picture not seen from above | Investigating |
| 21 | Start-up crash and window error in the boards' interface script | Resolved |
| 22 | Two-step placement sometimes needs extra clicks | Investigating |
| 23 | Signature fallback by text unproven on a real update | Open |

---

## 1. Memory growth in the cockpit view deep underground

**Status:** Investigating

About 4 GB per minute seen once below -100 m with the cockpit depth fix on. The in-DLL allocation
profiler pointed at camera-driven texture mip loading, material box updates and lighting / shadow queues,
but it counts commits without frees, so churn looks like a leak and the owner is not proven. The depth fix
stays off by default. PN Investigated 1; `re_notes/camera/camera_pipeline.md`.

## 2. 27 shadow passes for 4 cascades in the cockpit view

**Status:** Open

Seen in the frame statistics; not explained. The shadow map limit (PN What's New) cuts their cost but not
their number. PN Investigated 2; `re_notes/renderer/shadows.md`.

## 3. Zoomed-out view limited by the main thread

**Status:** Partially Resolved

Drawing and stepping the interface costs several times the 3D scene. The town label fix took about 10% off
frame time. Nothing further yet. PN Investigated 3, Performance.

## 4. Occlusion culling removes objects but gains no frame time

**Status:** Deferred

17-18% of tested objects culled, no change in frame rate: the frame was limited elsewhere. Kept off by
default. Its "terrain tiles" signature was re-found for 40420. `re_notes/renderer/culling.md`.

## 5. Road labels are not hidden by terrain or buildings

**Status:** Open

The overlay draws without the scene's depth. Labels are now under the game's interface (PN Investigated 4,
resolved) but still over the world.

## 6. A click on a road label also reaches the game

**Status:** Open

Needs the game's input intercepted. The SDL event filter used for placement (issue 22) is the likely
route. Clicks are ignored while a tool other than the default one is active (`7c44321`). PN
Investigated 4a, 4b.

## 7. Saving road names with the game untested end to end

**Status:** Open

The send into the save was seen in the log; a load reading it back, and a save loading with the mod
removed, have not been checked. PN Investigated 7.

## 8. Lua exceptions in the sliced road naming

**Status:** Deferred

148 "Value is not a string, but a thread" exceptions in one session's log; naming finished. With the worker
thread running the sliced path is only the fallback. PN Investigated 00.

## 9. A road under or over another took its name

**Status:** Resolved (fix built; not yet seen in the game)

2026-10-13: the two rules that join roads running alongside each other looked at the map only; they now
need the two roads on one level (within 4 m). `44b58ec`; PN Fixed 34.

## 10. Text on models breaks up into dots at a distance

**Status:** Investigating

The game's `label_text` shader samples the glyph texture once per pixel and discards below a threshold.
Blended labels did not help (PN Fixed 23). A test shader with sixteen samples and brighter lit text was
made; the result is not in. If it helps it belongs in the native layer. PN Investigated 0.

## 11. Converting old mods shows nothing for up to half a minute

**Status:** Open

Conversion runs at launch before the game's window. A progress window (hooking the executable's entry
point) is planned. PN Investigated 0 (converted vehicles).

## 12. Converted textures are uncompressed and large

**Status:** Partially Resolved

`[Converter] PackTextures=1` writes DXT1 / DXT5 / BC5 as the game's own textures are (`78cfaab`); off by
default until seen in the game.

## 13. Old content kinds not converted

**Status:** Open

Bridge and tunnel kinds, depots, road / water / air and cargo stations, mods that are scripts, the moving
parts of ships and aircraft, and a road vehicle's `headLights` (parts lit at night). Counted in
`re_notes/converter/key_census.md`. PN Investigated 0, Groundwork 33.

## 14. Converted road vehicles

**Status:** Investigating

2026-10-12: eight bus mods; one worked. Causes read from the game's log: wheel names not matching part
meshes, door animations of other mods or of the older game, dirt textures under old names, labels tied to
no part. Fixed in `04bf886`, `fb847dd`, `ae0edc6`, `80b2b48`; checked outside the game (every mesh,
material and animation named exists). Not yet seen in the game. PN Fixed 28-31.

## 15. Painted-in window glass as separate parts breaks a train

**Status:** Deferred

Adding parts to a converted vehicle (glass copies) folded the Class 450 up even without wheel meshes in
them. `[Converter] GlassParts=0` by default; the train is fine without them. PN Investigated 0 (glass).

## 16. Buying a converted vehicle stopped the game

**Status:** Resolved

The old-location model layout; output moved to the content layout with `version = 2`. PN Investigated 0.

## 17. Graphics device lost with a departure board on screen

**Status:** Resolved

2026-10-13: three sessions lost the device after a full-size screen texture loaded. Three corrections
(write only images the game filled; hold images across the submit; one queue lock). Seen fixed in the
game; which one did it is unknown. `0f42e12`, `a7d2fca`; PN Fixed 33.

## 18. Departure boards could not be clicked or set up

**Status:** Resolved

2026-10-13: a collider was added, then found that the game makes placed boards asset groups. Our own
click spots and window; seen. `a7be5ff`, `376eedb`, `4ff97d7`, `8f3f54a`; PN Fixed 35, Groundwork 36.

## 19. Departure boards in asset groups all show one screen

**Status:** Open

An asset group keeps no settings, so a board cannot carry which of the 32 screens it shows; every such
board shows the same content. Candidates in `re_notes/boards/boards.md` ("Open"). PN Investigated 0.

## 20. Board window's live picture not seen from above

**Status:** Investigating

2026-10-13: the window's picture circled the board. Cause: the plan was set for the board's own entity,
and a board in an asset group has none. `f28109d` applies the plan to any circling live view while the
window is open; not yet seen. PN What's New 38.

## 21. Start-up crash and window error in the boards' interface script

**Status:** Resolved

A game window script named without `::/` (from a mod that means the mod's own files) stopped the game at
start-up; a loop variable `_` hid the translate function. Both seen fixed. `ab94a61`, `4e115ce`,
`499a0d9`; PN Fixed 36, 37.

## 22. Two-step placement sometimes needs extra clicks

**Status:** Investigating

2026-10-13: a second click that could not build let go of the object. It now stays pinned unless the
click starts building. `376eedb`; not yet seen. PN Fixed 38.

## 23. Signature fallback by text unproven on a real update

**Status:** Open

The resolver finds functions by their assertion texts (400 sampled cases on 40420: 238 found, 162 refused,
0 wrong). Proving it rescues a hook needs the next game build. PN Groundwork 29.
