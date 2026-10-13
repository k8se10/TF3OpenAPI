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

## Reference (API version 15)

| Name | Since | Returns | What it does |
|---|---|---|---|
| `tf3api.version` | 1 | number | The API version. |
| `tf3api.has(name)` | 1 | boolean | Whether this build of the DLL has a function of that name. |
| `tf3api.log(text)` | 1 | `true`, or `false, reason` | Writes a line to `tf3api.log`, prefixed `[script]`. Limited to 2,000 lines per session; lines are cut at 1,500 characters. |
| `tf3api.writeFile(name, text)` | 1 | `true`, or `false, reason` | Writes `text` to `<game folder>\tf3api_out\<name>`. See below. |
| `tf3api.setRoadLabels(text)` | 2 | number of roads taken, or `false, reason` | Hands the roads to draw in the world to the label renderer. Replaces the previous set; an empty string clears it. Format below. |
| `tf3api.takeRoadClick()` | 3 | `id, name, number, class, length, segments, flags, x, y`, or `false` | The road whose label the player clicked since the last call. One click is held at a time; a later click replaces an unread one. `flags` (since 4) is the string the script sent for that road; `x, y` (since 5) is the spot on the road in world metres: the middle of the segment the label was drawn on. A tenth value, `info` (since 6), is the road's info text as the script sent it. |
| `tf3api.post(channel, text)` | 4 | `true`, or `false, reason` | Leaves a message on a named queue. See below. |
| `tf3api.take(channel)` | 4 | text, or `false` | Takes the oldest message off a named queue. |

### `writeFile`

- `name` is a plain file name: letters, digits, `.`, `_`, `-`; no path, no leading dot, no `..`; at most 80
  characters.
- Allowed extensions: `.html .svg .json .geojson .osm .txt .csv .lua .md`.
- At most 256 MB.
- The text is written to a temporary file first and then replaces the old file, so a failed write never
  leaves a half-written file in place of a good one.

### `post` and `take`

The game runs one mod's scripts in several Lua states that share nothing: the interface, the interface side
of a game script, and the simulation threads. These two functions are named queues kept in the DLL, so one
state can leave a message for another. The text is not interpreted.

- Channel names: letters, digits, `.`, `_`, `-`; at most 48 characters. Use the mod's id.
- A message is at most 256 KB. A queue holds 512 messages; when it is full the oldest is dropped.
- Queues are shared by every mod and are not private: do not put anything on one that another mod must not
  read.
- Messages are lost when the game closes.

### `setRoadLabels` text format

One record per line.

```
S <tab> shield <tab> class <tab> number <tab> name <tab> id <tab> flags <tab> info
G x0 y0 z0 x1 y1 z1
```

- `S` starts a road. `shield` is `M` (white on blue), `A` (yellow on green), `B` (black on white), `X` (white
  on grey, for a badge that is not a road number), `J` (white on black, a junction number) or `-`. `flags` is up to 10 characters of the script's own
  and comes back from `takeRoadClick`; it is optional.
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

## The worker (since 7; seen working in the game on build 40420)

A Lua state of the DLL's own, on a thread of its own, for work that is pure computation. It is made with the
game's own Lua and has the base, string, table and math libraries and the `tf3api` table; it has none of the
game's `api`.

| Name | Returns | What it does |
|---|---|---|
| `tf3api.workerAvailable()` | boolean | Whether this build of the game lets the DLL do this. |
| `tf3api.workerStart(files)` | `true`, or `false, reason` | `files`: paths separated by newlines, relative to the game folder; `.lua` files under `mods` only. Each file is run once in the worker state and what it returns is stored in a global named after the file (`core.lua` -> `core`). One of them should define the global function `tf3_job(input)`. Starting again replaces the state. |
| `tf3api.workerRun(input)` | job number, or `false` | Queues `tf3_job(input)`. At most four jobs wait at a time; input up to 128 MB. |
| `tf3api.workerTake()` | `job, succeeded, text`, or `false` | The next finished job: what `tf3_job` returned (as a string), or the error. |

Because the worker state has `tf3api` too, code running there can call `setRoadLabels`, `writeFile` and
`post` itself, from the worker thread.

Two things found on the first runs in the game. The bridge finds the game's `luaopen_base` and hooks it,
which replaces the function's first bytes, so the worker's own scan for the same function found nothing:
the worker takes the function from the bridge. And it has to call the hooked one, as the game does, or its
state has no `tf3api` table - with which a script running there can hand nothing back. At startup, with
`[Worker] SelfTest=1`, the log says `worker self-test: ran - "42ab|3|table|Lua 5.2"`; the third value is
the type of `tf3api` in the worker's state.

## Departure boards (since 9)

The boards' screens are textures of the game that the DLL writes into (`native/src/boards.cpp`). There are
32 screens, numbered from 0; screen `s` is known by its texture's size, (1920 + 16 * (s % 8)) x
(400 + 16 * floor(s / 8)). Numbers that name a screen are passed AS TEXT (`tostring(n)`): the bridge has no
number reader. Every function returns `true` when the picture changes, `false` when it stayed the same.
Seen working in the game on build 40420. Needs `[Boards] Enabled=1`.

| Name | Since | Returns | What it does |
|---|---|---|---|
| `tf3api.boardLines(l1, l2, l3)` | 9 | boolean | Three centred lines for every screen the script has said nothing else about (the "not connected" message). |
| `tf3api.boardClock(seconds)` | 9 | boolean | The running clock, seconds since midnight as text; anything else shows `--:--:--`. |
| `tf3api.boardsSeen()` | 9 | number | How many screen textures of the game are being written to (0: none loaded yet). |
| `tf3api.boardText(screen, l1, l2, l3)` | 10 | boolean | Three lines for one screen. A line without a tab is centred; `time<tab>destination<tab>platform<tab>expected` is laid out in columns. |
| `tf3api.boardRows(screen, r1 .. r5)` | 11 | boolean | Five rows for one screen. A row is fields separated by tabs; a field starting `<N ` has its left edge at dot column N, `>N ` its right edge, otherwise it is centred; a leading `~` (before those) makes a field scroll when it is longer than its room. The character with code 1 stands for the running clock. A row whose text changes is drawn in from the left (`[Boards] RefreshMs`). Rows up to 600 characters. |
| `tf3api.boardColour(screen, rgb)` | 15 | boolean | The colour of one screen's lit dots, `"r g b"` (0-255); its dark dots are an eighth of it (amber keeps the shipped shade). Unreadable: amber. |
| `tf3api.boardSpots(text)` | 14 | number taken | Places that can be clicked although the game does not let them be: one per line, `id x y z radius` (world metres). Replaces the previous set. Drawn by nothing; tested against the mouse on a click. |
| `tf3api.takeBoardClick()` | 14 | id as text, or `false` | The spot clicked since the last call. |

## Live views and placement (since 12)

| Name | Since | Returns | What it does |
|---|---|---|---|
| `tf3api.placementMode(on)` | 12 | 0, 1 or 2 | Tells the DLL whether the game's "Drag-and-Confirm Construction Mode" is on (`"1"`) or off (anything else); a script can read that setting, the DLL cannot. Objects are placed in two steps only while it is on. Returns 0 off or unavailable, 1 on, 2 an object is pinned. Needs `[Placement] ConfirmObjects=1`. Seen working. |
| `tf3api.planView(entity, numbers)` | 13 | boolean | Makes the small live picture in an entity's window look straight down. `entity` is its number as text, or `"any"` for whatever live view is circling (since 14; a board in an asset group has no view of its own). `numbers` is `"x y z height upX upY"`: the point looked at, the camera's height above it, and the direction on the ground that points up the picture. An empty `numbers` gives the view back to the game. Up to eight entities at a time. Needs `[Boards] PlanView=1`. The hook is seen installing; the picture from above is not yet seen. |

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
| 4 | `post`, `take`; `takeRoadClick` also returns `flags`; shield kind `X` |
| 5 | `takeRoadClick` also returns the world position `x, y` |
| 6 | a road's line can carry an `info` text (up to 96 characters), returned by `takeRoadClick` |
| 7 | the worker: `workerAvailable`, `workerStart`, `workerRun`, `workerTake` |
| 8 | `legacySource(folder)`: whether the old mod with that folder name is in `legacy_mods` in the game's folder (a plain folder name only). A converted mod asks it about the mod it was made from |
| 9 | departure boards: `boardLines`, `boardClock`, `boardsSeen` (`3dfe684`) |
| 10 | `boardText`: a screen of its own per content (`8bc6184`) |
| 11 | `boardRows`: rows of fields at given columns (`68c7a14`) |
| 12 | `placementMode` (`01a8021`) |
| 13 | `planView` (`8be0036`) |
| 14 | `boardSpots`, `takeBoardClick`; `planView` takes `"any"` (`8f3f54a`, `f28109d`) |
| 15 | `boardColour`; scrolling fields and the refresh in `boardRows` (`6e212c6`, `166aa76`) |

## Not built yet

- Calls from native code into scripts (events). `takeRoadClick` is polled for now.
- Settings: reading `tf3api.ini` values from scripts.
- A store that outlives a Lua state, for data that must survive a save reload.
- Per-road traffic counts from the engine.
