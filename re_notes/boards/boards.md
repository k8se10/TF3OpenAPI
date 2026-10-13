# Departure boards - the design as built

Build 40420. Script mod `mod/tf3api_departure_boards`, native `native/src/boards.{h,cpp}`,
`native/src/board_picture.cpp`, `native/src/plan_view.cpp`, click spots in `native/src/road_labels.cpp`.
Behavioural reference: `reference_tf2_displays.md` (the older game's displays mod; none of its code,
models or texts is used). Every statement below is marked **seen** (in the game), **built** (tested
outside the game only) or **read** (from the game's files or executable).

## The model and its screens

- `tools/build_boards.py <board.glb>` turns a board model (casing parts only; the modelled LED field is
  dropped) into one mesh with a material per colour, a post of its own, and a screen quad in front of the
  dot field with a square dot pitch. It writes 32 screen textures `screen_00.dds` .. `screen_31.dds`, one
  mesh and one model per screen, and the constructions. Only `screen_00.dds` is kept in the repository.
- A screen is 240 x 50 dots, 8 x 8 pixels a dot, lit amber or unlit dark, with a black margin. Screen `s`
  has the size (1920 + 16 * (s % 8)) x (400 + 16 * floor(s / 8)): the size is how the native layer tells
  the screens apart. The shipped pictures show the "not connected" message (`TF3OpenAPI / Departure
  information unavailable / github.com/k8se10/TF3OpenAPI`) and `--:--:--`, which is what a board shows
  with no native layer.
- Three styles from three models: `board_modern_pole`, `board_heritage_pole`, `board_hanging` (the
  hanging one gets a post up behind its canopy and an arm over it). Departures and arrivals each: six
  constructions in the station buildings menu, no construction type, the style passed to the shared
  construction script as `updateScript.params.style` (it arrives as `captureParams`). One player setting,
  `tf3api_casing` (ComboBox, counted from 1): the casing colour, applied to the colour with the most
  surface in the model (the body). Models `<style>_c<k>.mdl` for k = 0..6, all on screen 0; the modern
  style keeps its 32 screen models for boards the script rebuilds with a screen number.
- Menu pictures (read from the game's own archives): a construction's pictures are the files beside it,
  `<name>@2x.tga` (240 x 150, 32-bit with transparency, bottom-up) and `<name>_preview@2x.tga` (720 x 405,
  24-bit). Without them the menu shows a purple box. The builder renders them from the board (a small
  rasteriser: flat-shaded triangles, the screen looked up dot by dot in a sample picture).

## Writing the screens (native) - seen

- `vkstats` reports every image the game makes, uploads into and destroys. An image of a screen's size
  (at any of the first five mip levels, since streaming makes smaller copies first), 2D, a plain 32-bit
  format and usable as a copy destination is taken as that screen's image - but only once the game has
  itself copied data into it (it makes two full-size images at once and fills one).
- A painter thread makes a screen's picture when its text changes (`boards::Compose` places the dots,
  `boards::Paint` makes the pixels and the smaller levels; font table from `tools/embed_board_font.py`).
  At present time, on the presenting thread, the picture is copied into every image of that screen with
  our own command buffer, staging buffer and fence: barrier to transfer, copy every level, barrier back,
  submit without waiting. An image is left alone for 90 frames after it is made or after the game last
  copied into it, and one copy is made at most every 6 frames.
- Safety (from the device-lost round, Fixed 33 in the patch notes): the image list is held from choosing
  to submitting, the game's destroy call waits (at most 1 s) for a copy of ours that names the image, and
  every submit and present - the game's, ours and the overlay's - goes through one lock.
- Rows (`tf3api.boardRows`): five rows with tops at dot rows 1, 11, 21, 31, 41; fields separated by tabs,
  `<N ` left edge at column N, `>N ` right edge, else centred; character code 1 is the running clock,
  which the native layer keeps going by itself.
- **Refresh**: a line whose text changes keeps the time it changed; the painter puts out its dots from
  column `step * 240 / 40` on, with `step` worked out from the time over `[Boards] RefreshMs` (1600 ms).
  The screen's key includes the sum of its lines' steps, so every step makes the screen due again.
- **Scrolling**: a field written `~<N ...` that is wider than its room runs past in a window, offset
  2 columns every 80 ms after a 2.5 s hold, with 40 dark columns between end and start. The offsets are
  part of the screen's key. While any screen refreshes or scrolls, copies are made every 2 frames
  instead of 6, and the next picture is asked for right after a copy.
- **Dot colour**: `tf3api.boardColour`; the dark dots are an eighth of the lit colour (amber keeps the
  shipped shade so the picture test still matches the shipped texture).

## How a board is known - seen

- **Build events.** The interface's game script receives `builder.proposalCreate` (the constructions a
  build would add, with file name and placement) and `builder.proposalApply` (the player confirmed). A
  board in a confirmed build is added to the list `state.placed` with its place and kind. The list is
  handed to the simulation side, which keeps it in the save (`update` / `handleEvent` `setBoards`), and
  read back on load. One line per board: `x y z kind platforms mode layout`; a board's id is 1000 + its
  place in the list.
- **The game makes it an asset group** (read and seen): a placed board becomes part of an asset group
  entity, which cannot be selected and keeps no settings; the interface's state does not list asset
  groups. The board is found again with the game's spatial lookup (`octree.findEntitiesInCircle`) by its
  place, and recognised by the model ids of its model instances.
- **Joining.** A board within `JOIN_REACH` (100 m) of a station's outline joins the nearest station
  (`core.nearby`). Stations come from the station-to-construction map and their station groups.
- **Removal.** After every confirmed build and every 1,800 frames each known board is looked for where it
  stood (`boardThere`); one that was found before and is gone is dropped (`forgetBoard`). A board never
  found is kept, so a lookup that sees nothing cannot empty the list. The window also has "Forget this
  board". Built; not yet seen.

## Clicking and the window

- The game cannot pick a board in an asset group, so the script hands the native layer a click spot per
  such board (`tf3api.boardSpots`: id, place 1.7 m above the base, radius 1.8 m); the native layer tests
  a left click against them and the script takes it with `tf3api.takeBoardClick`. Seen.
- The window (`gui/tf3api_boards/boards_ui.script.lua`, our own, opened on that click; seen): a plan of
  the station, the station's name and the board's kind, the station's platforms as toggle buttons,
  "Layout", "Dot colour", "Several platforms" (one merged list, or each in turn for `CYCLE` = 8 s), and
  "Forget this board". Choices go to the game script as `set <id> <platforms> <mode> <layout/colour>`
  and are kept with the board (the colour travels with the layout: `core.splitLayout`).
- **The plan** (built; replaces the live view, at the player's request: it did not work and costs a
  camera): `segmentsOf(group)` reads each terminal's `vehicleEdges`, the edge's geometry from the
  `TRANSPORT_NETWORK` component of the edge's entity (`straight` / `cubicSpline` / `cubicOffsetSpline`
  `.pos`, or an arc's ends), and takes the ends as world positions - or, when they lie more than 1.5 km
  from the station's construction, as positions in the construction's frame (unproven which applies).
  `core.diagram` turns them into the station's frame (along the longest track, across it, from the middle),
  one line per platform; `core.diagramText` sends it to the window, which draws it with the game's
  `builtin.Chart`: one `LINE` series per platform (lit amber when served, grey otherwise), the board as a
  short blue line, platform numbers as the y-axis labels.
- **Plan view** (built, now unused and off; the hook is seen installing): the native layer hooks the game's orbit of a live
  view (`0x1405329c0`, part of `UI::FollowAction`; `action+0xc8` = camera: eye, direction, up) and, where
  a plan is set, writes an eye straight above the station looking down. The height is from the station's
  length and width (`core.planHeight`, with the view's half-angle tangents taken as 0.4142 vertically and
  0.7364 across - guessed, not measured - and a 12% margin). The window sets the plan for `"any"` live
  view while it is open and clears it on close, because a board in an asset group has no live view of
  its own.

## Content

- `core.allocate` gives each different content (station, kind, platforms, mode, layout) one of the 31
  screens 1-31; screen 0 is the "not connected" one. A board in an asset group carries no screen number:
  every such board shows the screen its model names (screen 0's model), so they all show one content -
  **the open problem of this design.**
- Departures (`vehiclesOf`, `screenStep`; one screen every 20 frames): the station group's line stops,
  each line's vehicles, their next stop (`stopIndex`, from 0) and when they left the last one
  (`lineStopDepartures`, ms); the time to this station from the line's section times (`sectionTimes`, s)
  averaged over its vehicles (`core.averages`, `core.eta`) plus `DWELL` = 25 s a stop on the way.
  Destination = the stop half-way round the line (`core.destination`), origin likewise backwards; calling
  points = the stops up to the destination (`core.callingAt`). `Due` under 60 s; nothing beyond 4 hours.
- Layouts (`core.layoutRows`; built): `national` (default), `platform`, `metro`, `bus`, `station`; see the
  patch notes, What's New 39.
- The clock is the game's running time read as a clock (`floor(gameTime / 1000) % 86400`), the same as
  the day clock mod's and the Timetables mod's.

## History

1. One picture for every board; the clock first followed the sky's time and ran backwards (`3dfe684`).
2. A screen number chosen by the player per board (`24d6ff4`) - rejected: boards must work as the older
   game's displays did, with nothing numbered by hand.
3. Joining by itself, rebuilt once through a build command to carry its station and screen (`68c7a14`) -
   which assumed the board stays a construction; it does not.
4. Collider, then plain constructions, then found by model in asset groups, our own click and window,
   noted from build events, removal, layouts, plan view (`a7be5ff` .. `f28109d`).

## Open

- Different content for boards in asset groups (candidates: the screen chosen at build time by building
  the model of a free screen; or the native layer telling boards apart by place).
- Station picker when several stations are in reach; the window opening right after a board is placed;
  the large station-wide boards.
