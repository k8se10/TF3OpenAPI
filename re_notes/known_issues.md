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
| 19 | Departure boards in asset groups all show one screen | Resolved |
| 20 | Board window's live picture not seen from above | Resolved |
| 24 | Departure boards had no menu picture (a purple box) | Resolved |
| 25 | Station diagram shows tracks only | Resolved |
| 21 | Start-up crash and window error in the boards' interface script | Resolved |
| 22 | Two-step placement sometimes needs extra clicks | Resolved |
| 23 | Signature fallback by text unproven on a real update | Open |
| 26 | Right button dead and a crash after closing the placing tool while an object was pinned | Resolved |
| 27 | Middle-button height steps are 3 m, not 0.5 m | Investigating |
| 28 | Newly built stations keep "Station" in their name | Investigating |
| 29 | Departure boards placed at the track do not snap to it | Investigating |
| 30 | A bulldozed board stays on the station diagram | Investigating |
| 31 | Adjust Road cannot draw a road across a roundabout | Investigating |
| 32 | Drawn cities have nothing to show them on the map in the game | Open |
| 33 | The day clock's time cannot be set; the game's time-of-day slider no longer moves the sky | Investigating |
| 34 | Left-hand traffic: the guard, buildings, roundabouts and stop arrows not yet watched in play | Investigating |
| 35 | Left-hand traffic: the modular street station's entrance and exit modules swap meaning | Open |
| 36 | A save already mixed by toggling a left-hand mod stays mixed | Deferred |
| 37 | Left-hand traffic: painted arrows on factory yards still point for traffic on the right | Open |
| 38 | Splash screen emblem: the animation is redrawn every frame; the final version not yet seen | Investigating |
| 39 | Converted mods have no protection beyond the old mod being present in `legacy_mods` | Roadmap Idea |

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

**Status:** Resolved

2026-10-14: boards at different stations show their own departures in the game (seen by the player; not
written up when it first worked).

An asset group keeps no settings, so a board cannot carry which of the 32 screens it shows; every such
board shows the same content. Candidates in `re_notes/boards/boards.md` ("Open"). PN Investigated 0.

## 20. Board window's live picture not seen from above

**Status:** Resolved (by replacement; not yet seen in the game)

2026-10-13, later: the player asked for a drawn plan instead ("the birds eye view doesnt work, lets just
derive diagram only, its better for perf too"). The window now draws the station from its tracks
(`937f24a`; PN What's New 40); the plan view is off by default and unused.

2026-10-13: the window's picture circled the board. Cause: the plan was set for the board's own entity,
and a board in an asset group has none. `f28109d` applies the plan to any circling live view while the
window is open; not yet seen. PN What's New 38.

## 21. Start-up crash and window error in the boards' interface script

**Status:** Resolved

A game window script named without `::/` (from a mod that means the mod's own files) stopped the game at
start-up; a loop variable `_` hid the translate function. Both seen fixed. `ab94a61`, `4e115ce`,
`499a0d9`; PN Fixed 36, 37.

## 22. Two-step placement sometimes needs extra clicks

**Status:** Resolved

2026-10-14: seen fixed in the game.

2026-10-13: a second click that could not build let go of the object. It now stays pinned unless the
click starts building. `376eedb`; not yet seen. PN Fixed 38.

## 26. Right button dead and a crash after closing the placing tool while an object was pinned

**Status:** Resolved

2026-10-14 (later): seen fixed in the game - the right button works after backing out, no crash.

2026-10-14: reported in play - after placing in two steps and backing out, the right button did nothing;
loading a save after that stopped the game. The crash dump (build 40420): an access violation in the game's
code called from our turn (`placement.cpp` `Turn`), called from the input filter on a right drag - the pinned
tool had been closed and freed, and nothing had told the DLL. Fix: the tool's close
(`UI::BasicAction::Deactivate`, `0x1404b1a70`, slot 6 of its table) and its deleting destructor
(`0x140516170`, slot 0) are hooked from the live tool's table at the first pin and let go of the object; the
filter also checks the tool's first bytes are still its table. `7865d27`, deployed, not yet seen. PN Fixed 45.

## 23. Signature fallback by text unproven on a real update

**Status:** Open

The resolver finds functions by their assertion texts (400 sampled cases on 40420: 238 found, 162 refused,
0 wrong). Proving it rescues a hook needs the next game build. PN Groundwork 29.

## 24. Departure boards had no menu picture (a purple box)

**Status:** Resolved (built; not yet seen in the game)

2026-10-13: the game takes a construction's menu pictures from files beside it (`<name>@2x.tga`,
`<name>_preview@2x.tga`); the boards had none. The builder now renders both from each board. `166aa76`;
PN What's New 42.

## 25. Station diagram shows tracks only

**Status:** Resolved

2026-10-14: platforms, buildings, tags, the board and live trains all show and line up (player: "works just
fine"). Causes found on the way: models were on the sub-construction; a model's axes are the matrix's
columns 0 and 1; the window shows the picture bottom row first; the floating layout's positions run 0..1;
platforms come from the terminal's stopping point. PN Fixed 41, What's New 44.

2026-10-13: first look at the diagram window. Seen working: the window, the native drawing into its
pictures (the game makes each a texture of its own size, with every smaller level), the track pieces, the
board on the overview. Missing: platforms, buildings, stairs (no model was read), platform tags (no
platform's stopping track was read), the board's marker on the map. `9a3f4a6` reads models from the
station's sub-constructions as well, takes a stopping track from the terminal's edge list or its stopping
point's piece of track, draws the boards into the map, and logs the reason for anything still empty. Not
yet seen. PN What's New 43, Fixed 39.

## 27. Middle-button height steps are 3 m, not 0.5 m

**Status:** Investigating

2026-10-14: the view now stays still while the middle button is dragged, but the object still moves in the
game's coarse 3 m steps. The log said `the bottom bar's height setting cannot be reached`: the script found the
bottom bar through Lua's debug library (`debug.getupvalue`), which does not work in the interface's Lua state.
It now wraps the game's `construction_react_util.getActionParams` (called through the shared module table)
and takes the bottom bar from its last argument. `067abaf`; not yet seen. PN Fixed 54.

## 28. Newly built stations keep "Station" in their name

**Status:** Investigating

2026-10-14: stations already built lose the word; a newly built one is still "X Station". The text-only mod
(`tf3api_station_names`) is not taken by the game for that name, and the road-names mod's renaming pass only
ran again when streets changed - most rail stations change none. It now also runs when the number of stations
changes. `0b56538`; not yet seen. PN Fixed 55.

## 29. Departure boards placed at the track do not snap to it

**Status:** Investigating

2026-10-14: the at-the-track boards did not snap at all. The snap point named transport modes but no edge kind;
the game's own constructions that snap (its rail depot, maintenance station) name `snapToBaseEdgeTypes`. Now
`{ "TRACK" }`. `067abaf`; not yet seen. PN Fixed 56.

## 30. A bulldozed board stays on the station diagram

**Status:** Investigating

2026-10-14: a bulldozed board was taken off the list (log: `taken off the list (no longer there -
bulldozed)`) but the window kept the marker: it only ever added boards. The boards script now sends the list
of boards there are after each survey and the window drops the others. `067abaf`; not yet seen. PN Fixed 57.

## 31. Adjust Road cannot draw a road across a roundabout

**Status:** Investigating

2026-10-14: reported in the game. A roundabout's own segments are left out of every junction's list, so the
joins the tool writes around a ring were never applied, and a road that crossed one would not be a single
line. For the tool a roundabout now counts as one junction (`core.ringNodes`, `core.junctionOf`), and joins
between two arms of the same ring are applied; automatic naming is unchanged. Offline test 15b. `067abaf`,
`0b56538`; not yet seen. PN Fixed 58.

## 32. Drawn cities have nothing to show them on the map in the game

**Status:** Open

2026-10-14: cities drawn with the tool exist and the rules use them, but nothing is shown above them. The
decided design is to reuse the game's own town label and window for cities (`CLAUDE.md` section 14); not
started.

## 33. The day clock's time cannot be set; the game's time-of-day slider no longer moves the sky

**Status:** Open

2026-10-14: with the sky following the clock, the game's own slider has no effect, and the clock (running time
as a clock) cannot be set. Setting it means an offset on the clock, which would lose the match with the
Timetables mod's clock that the player wants kept; needs the player's decision.

2026-10-14 (later), the player's direction: the game's own time-of-day menu is the switch. The mod no longer sets
the sky's cycle; the sky follows the clock only while the game's continuous cycle is chosen, and Custom keeps the
game's slider. The clock itself stays the game's running time (the Timetables match is kept). `2ac4d0c`; not
yet seen. PN Fixed 62.


## 34. Left-hand traffic: the guard, buildings, roundabouts and stop arrows not yet watched in play

**Status:** Investigating

2026-10-15: new two-way roads in a game with the left-hand mod drive on the left, vehicles steer correctly and the
destination displays of mirrored vehicles work (seen). Built and tested outside the game, not yet seen: the save
guard (a save's side kept with the other left-hand mod on or off), the turned lanes of buildings and the
one-way pieces of roundabouts and ramps, and the arrow of a bus or tram stop following its lane (`f8eed16`,
the rule tested in `tools/tests/driving_side_test.cpp`). The matrix to play is item H of
`re_notes/testing_checklist.md`. Design: `re_notes/left_hand_traffic/save_guard.md`. PN What's New 63-65.

## 35. Left-hand traffic: the modular street station's entrance and exit modules swap meaning

**Status:** Open

2026-10-15: the entrance and exit modules of the modular street station lay one-way street pieces and the
building's lanes are turned by the DLL, so the flow through a station is the mirror of the right-hand one; the
module called "Entrance" then carries the flow out. The older left-hand mod swaps the two modules' names to hide
this. Whether it matters in play is only seen in the game: build a modular bus station in a left-hand game.

## 36. A save already mixed by toggling a left-hand mod stays mixed

**Status:** Deferred

2026-10-15: roads built for both sides do not connect properly where they meet. The guard counts them and warns in
`tf3api.log`, and changes nothing: a network is saved as built, so repairing means rebuilding those streets'
networks and re-planning every vehicle on them. Not attempted.

## 37. Left-hand traffic: painted arrows on factory yards still point for traffic on the right

**Status:** Open

2026-10-15: the older left-hand mod ships a mirrored picture of the arrows painted on industry yards (27 MB). A
mirrored picture would have to be made from the game's own at launch, never shipped. Cosmetic; not started.

## 38. Splash screen emblem: the animation is redrawn every frame; the final version not yet seen

**Status:** Investigating

2026-10-15: the game only shows or hides a splash picture. A run of faded copies looked choppy, so the DLL now
moves the picture's texture window (the zoom) and rewrites its pixels (the fade) on every step of the splash
(`048b802`). Whether the game keeps up with a texture swap each frame is not yet seen. Settings in `[Splash]`.

## 39. Converted mods have no protection beyond the old mod being present in `legacy_mods`

**Status:** Roadmap Idea

2026-10-15: a plan to carry converted mods packed and encrypted, so their files are never plain on disk, was
started and dropped; none of it is in the repository. Converted mods are plain files, offered only while the old
mod is in `legacy_mods`, with the notice window naming a missing one. Facts read for a later attempt are in
`re_notes/ui/mod_sources.md`.
