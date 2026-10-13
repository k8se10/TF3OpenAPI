# Rotating and raising while placing: the two games compared

**Status: researched 2026-10-13, nothing built.** Build 40420 and the older game's executable; static
reading only.

## What is the same

Both games name the same key actions: `constructOpt1` / `constructOpt2` (rotate), `constructRaise` /
`constructLower` (height), `constructOpt5` .. `constructOpt8` (the other two axes), each with a
`...Precise` twin, `constructNoSnap`, and the modifier `IA_PRECISION_MODE`. The newer game adds
`constructAlignToTerrain`, `constructOpt56` and `constructOpt78`.

## What changed

| | Older game | Newer game |
| --- | --- | --- |
| where a key press is handled | in the executable: the placement tool registers a handler per key when it is set up (function at `0x14040fdb0` of the older game) | in the interface script `gui/construction/construction_react_util.tl`: `addStepValueInputActionHandlers(param, name, keyUp, keyDown)` |
| what a press does | changes the tool's own rotation by a fixed angle | steps a **parameter of the bottom bar** (`rotation`, `height`, `bend`, `slope` ...) through that parameter's `stepValueFn(value, direction, precise)` and writes it back with `changeParam` |
| rotation step | **11.25 degrees** (the constant pi / 16 in every rotate handler): 32 steps a turn, so 22.5, 45 and 90 degrees are reachable | **10 degrees** (1 degree in precision mode), from `addRotationParams`: 36 steps a turn - 45 degrees is not reachable without precision mode |
| rotation as a value | free | a slider of 36 fixed values (0, 10 .. 350) in the bottom bar; the tool reports a rotation made with the mouse back into it (`constructionBuilder.onRotationChangeFn`) |
| height | (handler not read yet) | the bottom bar's `height` parameter, stepped the same way |

## What restoring the older behaviour would take

The step rule is data on the parameter (`stepValueFn`), made by the interface script. A script mod can
wrap the script's exported functions when the interface loads (the way this project's road-name mod wraps
others) and give the `rotation`, `rotationX`, `rotationY` and `height` parameters the older game's step
rule, without shipping any of the game's script. No native code is needed for the steps themselves.

Still to be read before building: the older game's height and precise steps (inside its handlers), whether
the older game repeated the step while a key was held (and at what rate), and how the newer game's handlers
are fired (once a press, or repeating).

## Second look (2026-10-13): mouse rotation and the on-map height control

The user's two complaints: objects can no longer be rotated with the mouse, and the height buttons shown
on the map while placing are gone. What the two executables say:

**Mouse turn / raise.** The click handler of the placement tool, `UI::ConstructionBuilder::MousePressed`
(`0x14051b010` in the newer game; `0x140419aa0` in the older, whose signature is
`MousePressed(UI::CRendererComponent *, bool)`), opens the same way in both games:

    if the tool is not locked:
        if (modifier bits of the event & 3) != 0 and the first mouse button is held:
            set the tool's "being dragged" flag and return without building
    ... otherwise check the proposal and build

Bits 1 and 2 of the modifier word are the two Shift keys in the windowing library both games use. So in
both games a **Shift + left-button drag** puts the tool into its drag mode instead of building; the
interface's cursor list still has the matching cursors (`Turn`, `Raise`, `TurnRaise`), and the tool reports
a rotation made this way to the bottom bar (`constructionBuilder.onRotationChangeFn`). The newer game's
version has two more conditions (its third argument must be false, and it keeps a second flag, read again
in the tool's step). **Not confirmed on screen: whether Shift + drag still turns and raises in the newer
game.** If it does not, the two extra conditions and the flags at +0xb9d / +0xb9f / +0xcd3 of the tool are
where to look.

**The on-map control.** `UI::BuildControlComp` is the control drawn on the map beside what is being built
(its own asserted names: a slope layout, an info part, a control part, selectors for bridge, tunnel and
level-crossing type). It exists in both games. In the newer game its layout function
(`UI::BuildControlComp::UpdateLayout`, `0x140620b00`) is called from one tool only,
`UI::StreetBuilder::Step` - roads and track. The placement tool for constructions still owns one (a
removal of a `BuildControlComp` sits among its functions, `0x14051a2a0`) but nothing lays it out, so it
never shows. That matches the complaint. Which of the older game's tools laid it out, and what it showed
for a construction (height arrows, confirm, cancel), is still to be read from the older executable
(`UpdateLayout` there is `0x1404d2510`).

**Ways to bring them back** (nothing built):
1. If Shift + drag works: nothing to build for mouse rotation; at most a hint, or the drag without Shift.
2. Height buttons: either an interface element of our own that steps the bottom bar's `height` value (script
   only), or the game's own control shown again by the native layer calling its layout from the placement
   tool's step as the street tool does. The first is safer and needs no hook; the second is the original
   look.

## The decision, and what the game already has (2026-10-13)

**Wanted** (the user's words, shortened): for objects - stations, depots, assets - one click places the
thing and the game then asks for confirmation; during that confirmation, and only then, holding the right
mouse button and dragging turns it, in the game's own 10 degree steps; roads and track get the same extra
confirm step, so that the height control can come back.

**Roads and track: the game has this already, as a setting.** `AppConfig.enableSeamlessStreetBuilder`
(API definitions, `type.d.tl`: "Whether to enable the seamless construction mode for the street builder";
`true` in the settings file of the development install). The settings page shows it inverted, under
**Advanced Settings**, as **"Enable Drag-and-Confirm Construction Mode"**: "Enable drag-and-confirm
construction mode for tracks and roads. When enabled, construction is performed in two steps. Proposals
can be adjusted after placement and are built after confirmation." It can only be changed from the main
menu (`disabledInGame = true`). The older game's executable has no such name: there the two-step mode was
the only one. With it on, the street tool is the one that lays out the on-map control
(`UI::BuildControlComp::UpdateLayout` from `UI::StreetBuilder::Step`), so the height control should show
again. **Not yet seen on screen.**

**Objects: nothing in the game does it.** The object tool builds in its click handler; it has no
two-step mode and never shows its on-map control. That is what has to be built: a pinned state between the
first click and a confirm, with the right-button drag stepping the same `rotation` value as the keys
(10 degrees a step, `stepValueFn`), and height buttons stepping the `height` value. How to hold the tool's
position still while it is pinned is the open point; the street tool's own two-step mode
(`UI::StreetBuilder::Step`, `0x140585160`, and how it reads the setting) is the model to read first.
