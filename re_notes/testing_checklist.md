# What needs testing in the game

"Log" is `tf3api.log` next to the game executable; "game log" is the game's own `stdout.txt` in its user-data
folder (`crash_dump`). Build 40420.

## Results of the look on 2026-10-14

| # | Item | Result |
|---|---|---|
| 1 | Placing tool closed with an object pinned | ✅ right button works afterwards, no crash |
| 2 | A save loads with our mods removed | ✅ |
| 3 | Road names come back from a save | ⏸ not tested on purpose: `ignoreSavedData` is on until the naming is good enough for the main save |
| 4 | Middle-button height steps of 0.5 m, view still | 🟠 view still; steps still 3 m - second fix built (below) |
| 5 | Esc / right click while pinned goes back | ✅ |
| 6 | Second click after a turn builds first time | ✅ |
| 7 | Existing stations lose "Station" | ✅ |
| 8 | New stations named without "Station" | 🟠 still "X Station" - second fix built (below) |
| 9 | Bus and tram stops named the London way | ✅ |
| 10 | Renames are definitive | ✅ |
| 11 | A click on a board opens the board | ✅ |
| 12 | Platform choice changes the board | ✅ |
| 13 | Auto / All / chosen platforms | ✅ |
| 14 | Boards placed at the track snap to it | 🟠 no snapping - fix built (below) |
| 15 | Layouts, arrivals, redraw, scrolling, styles, colours, pictures, hanging board, bulldozed board forgotten | ✅ except: a removed board stayed on the station diagram - fix built (below) |
| 16 | Platform tags on top in the diagram | ✅ |
| 17 | Rename taken when the field loses focus | ✅ |
| 18 | A renamed road keeps its name through changes | ✅; Adjust Road could not draw a road across a roundabout - fix built (below) |
| 19 | Road type, label choice, Abandoned | ✅ |
| 20 | One road or junction window at a time | ✅ |
| 21 | Motorway junction numbers and windows | ✅ |
| 22 | A road under or over another keeps its own name | ✅ |
| 23 | Postcode and capacity in the road window | ✅; London postcodes must be kept for a drawn city named London / Greater London - built (below) |
| 24 | Street map page from the game | ✅; terrain and water were missing - built (below) |
| 25 | Drawn cities | 🟠 they exist and work in the rules, but nothing shows them on the map in the game (open) |
| 26 | Calendar modes | ✅ no problems seen, not fully tried |
| 27 | Sun and moon follow the clock | ✅; but the clock cannot be set, and the game's time-of-day slider no longer moves the sky (open) |
| 28 | Vehicle wear follows the calendar | not yet tried |
| 29 | Converted buses | 🟡 a first short test went well; a full test with many models still to do |
| 30 | Whole stations of one construction | 🟡 they place; use by trains and passengers not yet tried |
| 31 | Converted mod hidden without its old mod | not yet tried |
| 32 | `PackTextures=1` | not yet tried |
| 33 | P86 rear blind and reading at a distance | 🟡 fine; wants backlighting of the panel and text, especially in the dark - lit text built (below) |
| 34 | Cockpit view below -100 m on 40420 | ✅ no crashes since the fix first ran |
| 35 | Occlusion culling measured | ⏸ little benefit for the risk: left off (`Cull=0`) |
| 36 | Night lighting at 256 lights per bucket | ✅ no worse in frame rate |

## Built since, to look at next

1. **Middle-button height** (`067abaf`). The log of the last look said `the bottom bar's height setting cannot be
   reached`: the way through Lua's debug library did not work in the interface's Lua state. The script now
   wraps the game's `construction_react_util.getActionParams` and takes the bottom bar from its argument. Look
   for `height steps of 0.5 m go to the bottom bar's "height" setting` in the log; the height should move in
   0.5 m steps. - still in steps of 3 instead of the "0.5" requested
2. **New stations** (`0b56538`). Building a station that changes no street (most rail stations) did not start
   the renaming pass; it now also starts when the number of stations changes. Build a new rail station and
   wait a few seconds: "Maze Hill", not "Maze Hill Station". Log: `stations: N to lose "Station" ...`.
3. **Boards at the track** (`067abaf`). The snap point now names the edge kind (`snapToBaseEdgeTypes =
   { "TRACK" }`), as the game's own rail depot does. A board from the rail assets menu should snap to a track.
4. **Removed boards on the diagram** (`067abaf`). Bulldoze a board: it should leave the station diagram as well.
5. **Adjust Road across a roundabout** (`067abaf`, `0b56538`). Take a road's end across a roundabout to an arm
   on the far side: the road should carry on there, the roundabout staying a street of its own. Taking the end
   back to the roundabout should shorten it again.
6. **London postcodes** (`067abaf`). The city tool offers "London style" only while the name typed is London
   or Greater London (any case). A road leading to "Greater London" is "London Road".
7. **Terrain on the street map** (`0b56538`). After the names are up the log says `terrain for the map: N x M
   samples every S m (P% water) in T s`; `tf3api_out\road_terrain.json` appears. Write the map page: shaded
   relief and water under the roads. Also in the SVG from `tools/road_map.py`.
8. **P86 blind** (`b46020b`). The destination text is drawn lit (it reconverts at the next launch): it should
   read in the dark. The panel behind it is not lit yet.
9. **Occlusion** (`b46020b`). With `Cull=0` the road names must still be drawn; F10 still switches culling on to
   compare.

10. **Day clock and the game's own sky menu** (`2ac4d0c`). In the game's time-of-day menu: the continuous
    cycle - the sun follows the clock; Custom - the game's slider sets the time and the mod leaves it; Dynamic /
    Local - the game's. A save the earlier version had switched to Custom comes back on the continuous cycle once
    (log: `the sky's cycle, set to Custom by an earlier version of this mod, is put on "Automatic"`).
11. **Board animation** (`d383534`). A line drawn in and the calling points scrolling should look continuous.
12. **P86 blind lit from behind** (`e0a8b53`). Reconverted at the next launch: the blind's face glows a soft red
    by day and night, with the white text over it. If the whole cab interior glows or nothing does, the mask's
    area is off.

## Clean-up after testing

- Remove the test mod `tf3api_label_test` (a changed label shader) from the save and the mods folder.
- `[Converter] StationDebug` back to 0 if it is still set.
- Before any release: `ignoreSavedData` off and the development city removed in the road-names mod's
  `names.lua`.
