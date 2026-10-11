# The `tf3api` script API

What the native layer gives the game's scripts. Source: `native/src/lua_bridge.cpp`. Build 40408.

The DLL hooks the function that opens Lua's base library, which every Lua state the game creates calls once.
In that call it adds one global table, `tf3api`, to the new state. So the table exists in the UI states and
in the game-script states alike. How the Lua C API functions were located: `re_notes/scripting/lua_vm.md`.

`[Bridge] Enabled=1` in `tf3api.ini` switches it on.

## Rules for scripts

- The table is optional. A mod must work without the DLL:
  `if tf3api and tf3api.has("writeFile") then ... end`
- Functions never raise Lua errors. They report failure through their return values.
- Arguments must be strings where a string is asked for; numbers are not converted.
- Nothing in the API changes the simulation or the save.

## Reference (API version 3)

| Name | Since | Returns | What it does |
|---|---|---|---|
| `tf3api.version` | 1 | number | The API version. |
| `tf3api.has(name)` | 1 | boolean | Whether this build of the DLL has a function of that name. |
| `tf3api.log(text)` | 1 | `true`, or `false, reason` | Writes a line to `tf3api.log`, prefixed `[script]`. Limited to 2,000 lines per session; lines are cut at 1,500 characters. |
| `tf3api.writeFile(name, text)` | 1 | `true`, or `false, reason` | Writes `text` to `<game folder>\tf3api_out\<name>`. See below. |
| `tf3api.setRoadLabels(text)` | 2 | number of roads taken, or `false, reason` | Hands the roads to draw in the world to the label renderer. Replaces the previous set; an empty string clears it. Format below. |
| `tf3api.takeRoadClick()` | 3 | `id, name, number, class, length, segments`, or `false` | The road whose label the player clicked since the last call. One click is held at a time; a later click replaces an unread one. |

### `writeFile`

- `name` is a plain file name: letters, digits, `.`, `_`, `-`; no path, no leading dot, no `..`; at most 80
  characters.
- Allowed extensions: `.html .svg .json .geojson .osm .txt .csv .lua .md`.
- At most 256 MB.
- The text is written to a temporary file first and then replaces the old file, so a failed write never
  leaves a half-written file in place of a good one.

### `setRoadLabels` text format

One record per line.

```
S <tab> shield <tab> class <tab> number <tab> name <tab> id
G x0 y0 z0 x1 y1 z1
```

- `S` starts a road. `shield` is `M` (white on blue), `A` (yellow on green), `B` (black on white) or `-`.
  `class` is 1 to 3. `number` and `name` may each be empty; a road with neither is dropped. `id` is the
  script's own number for the road and comes back from `takeRoadClick`; it is optional.
- `G` is one segment of the road started last, in world metres.
- Which text a road shows is the script's decision: it leaves out what should not be drawn.
- Limits: 100,000 roads, 400,000 segments, 64 characters per text field.

### `takeRoadClick`

A click is a press and release of the left mouse button on a shield or a name, with the cursor moving no
more than 5 pixels in between, while the game window is in front. The click is not taken away from the
game: whatever is under the label is clicked as well.

`length` is in metres. `class` is the class the script sent.

## Where calls may come from

Any Lua state, any thread. `log` and `writeFile` do their work in the calling thread: `writeFile` blocks for
as long as the write takes, so large exports belong at a moment a short pause is acceptable.
`setRoadLabels` parses in the calling thread and swaps the result in; the renderer picks it up on the next
frame.

## Version history

| Version | Added |
|---|---|
| 1 | `version`, `has`, `log`, `writeFile` |
| 2 | `setRoadLabels` |
| 3 | `takeRoadClick` |

## Not built yet

- Calls from native code into scripts (events). `takeRoadClick` is polled for now.
- Settings: reading `tf3api.ini` values from scripts.
- A store that outlives a Lua state, for data that must survive a save reload.
- Per-road traffic counts from the engine.
