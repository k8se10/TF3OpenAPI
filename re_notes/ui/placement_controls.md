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
