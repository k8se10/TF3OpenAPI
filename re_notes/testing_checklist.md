# What needs testing in the game

## State at the session break (2026-10-14, evening)

The results written below were read. Done since: track boards withdrawn (they crashed the game - bulldoze any
placed); badges far out limited to main A roads (1-2 digits, 3 digits only nearer in, never 4); P86 blind a deeper
red with bolder text. Confirmed by these results: middle-button height (great), labels at the screen edges, board
line-by-line redraw, new stations renamed (on the next pass), converted buses so far. Next session, open from
these results:
- road numbers on motorways (retest after the carriageway fix), item 1;
- terrain on the street map is coarse when zoomed in (one grid of at most 320 samples): needs a finer or tiled grid;
- P86 blind font: the user's own font "Isotherm Sans" (looks like TfL's) - find out whether a model label can use
  a font of a mod's own;
- line destinations built into our native layer as game behaviour (replacing the Destination Displays mod; the
  boards read that mod for now);
- converted-mod protection: our own mod source in the native loader, so converted files are never user-accessible
  (research how the game defines a mod source);
- day clock: real time is beta; changing day / time unsupported; testing deferred.

Everything below is built but not yet confirmed in the game. "Log" is `tf3api.log` next to the game executable;
"game log" is the game's own `stdout.txt` in its user-data folder (`crash_dump`). Build 40420. Write your result
after each item, as before.

## New since the last look

1. **Road numbers you set yourself.** Open a road's window, type a number in **Number** (A1, A1(M), B1234, M25)
   and click away. The road shows it and the label reads "Number (yours)".
   - Give it a number that another road has **from the rules** (a number you did not type): your road gets it,
     and the other road is given a new number by the rules. - known buggy on m ways - testing better after the fix 
   - Type the same number into **two roads yourself**: both keep it - one designation running along several
     roads. (A number you typed is never taken from a road by another number you type.)
   - Clear the field: the road gets a number from the rules again. - this part seems  to work ok
   - Build on or change the road: your number stays.
2. **Road labels, zoom hierarchy.** Zoomed far out (below about 20%): only A, M and A(M) badges are drawn - no
   street names, no B roads, no junction numbers. Zoom in past 20% and they come back. - okay i shouldve further clarified only main a roads not just a---- only a-- or a- or sometimes maybe a--- never a----
3. **Road labels at the screen edges.** In the outer 5% of the screen on each side, labels fade and soften towards
   the edge; everywhere else they look as before. - yes this works 

## Third / second fixes for what failed last time

4. **Middle-button height while an object is pinned**: should now step 0.5 m. Log: `height steps of 0.5 m go to
   the bottom bar's "height" setting`; if it says `cannot be reached`, send me the log. - perfect feels great to use in game too, truly great ux 
5. **Newly built rail stations without "Station"**: build a new rail station and wait a few seconds; it should
   read "Maze Hill", not "Maze Hill Station" or "Maze Hill <station type>". Bus and cargo stations keep their
   names. If one still has "Station", the log line `stations: ... (left alone: '...')` names it. - yeah it spawned with station in name but by next look it had been stripped 
6. **Departure boards at the track**: now in the **rail tools** menu, beside the signals. A board should snap to a
   track the way a signal does and stand on the platform beside it. - this is far worse and crashed the game go back to them being station assets(also place along track didnt work in a station - works outside of it so pointless without modding that too
- **Platform side** (Left / Right) and **Height above the track** (default 1.25 m) move it.
   - It should join the station and show departures.
   - Log: `N board(s) built`.
7. **P86 destination blind lit from behind**: the P86 reconverts at the next launch. The blind's face should glow
   red day and night, with the white text over it.
   - If the whole cab glows, the lit area is wrong.
   - If nothing changes at all, look in the game log for `p86_dlr_indoor`. - works great but needs a bit of colour darkening(looks too pink when lit) and also could do with text emboldening and maybe use my own font isotherm sans as it looks much more like the tfl one 
8. **Departure boards redraw line by line**: when the departures change, the lines are redrawn one at a time, top
   to bottom; a line waiting for its turn keeps its old text.
   - Is it still choppy? Send me the log lines `boards: animation over ... pictures copied (... a second) at ...
     frames a second; painting ... ms` - they show where the time goes. - yes works 
9. **Street map page with terrain**: once the road names are up, `tf3api_out\road_map.html` (in the game folder)
   is written by itself - also by **Write street map** in the small TF3OpenAPI window. Open it in a browser:
   shaded hills and blue water should lie under the roads.
   - Log: `terrain for the map: ...`.
   - For SVG, GeoJSON and OSM files: `python tools/road_map.py "<game folder>\tf3api_out\road_export.json"`;
     the SVG has the terrain too. - yes but rn terrain is always lod even when zooming on the export 

## Built earlier, not yet tried

[10. **Day clock and the game's sky menu**.
    - **Continuous cycle** (in the game's time-of-day menu): the sun and moon follow the clock.
    - **Custom:** the game's own slider sets the time and the mod leaves it alone.
    - **Dynamic** going back and forth is the game's own behaviour.
11. **Calendar modes in full**: Realistic (the date changes at midnight on the clock), Balanced (on each hour),
    Transport Fever (the game's own pace).
12. **Vehicle wear follows the calendar**: Realistic or Balanced, wear setting on. Log: `vehicle wear and age
    follow the calendar: lifespans x ...`. A changed setting needs a restart of the game, not only a reload.] - ]- the real time is considered in beta and works fine though changing days/time is unsupported at this time - testing here deffered till more work is done on it 

13. **Converted buses, full test**: many models - wheels turn, doors open, engine sound, destination text on the
    blind, dirt.- as far as observed so far no known issues 
14. **Whole stations of one construction (converted)**: they place; now check that trains stop and passengers
    board. - untested presumed working, pending confirmation (stations are early alpha conversion as even the tf2 mod deliberatly avoided it due to complexity, should work doesnt mean always works)
15. **A converted mod without its old mod**: take the old mod out of `legacy_mods` and start the game.
    - Its vehicles, stations and tracks should be gone from the menus.
    - A save that uses them should still load. - i had a better idea since which was using our native loader find out how the game defines "mod source" so this way we can make our own proprieatary mod source and loading system which ensures the files are never user accessible once converted killing the issue in the water for our releases(forks are not protected by this because can be changed freely)
	
16. **Packed textures**: set `[Converter] PackTextures=1` in `tf3api.ini` and start the game (it reconverts).
    Converted vehicles should look the same, and their folders should be much smaller. - still untested as of yet

## On hold (nothing to test)

- Road names read back from a save: `ignoreSavedData` is on until the naming is good enough for your main save.
- Drawn cities have nothing on the map yet; this comes with the left-hand traffic work.
- Occlusion culling: left off (`Cull=0`).

## Confirmed so far

Placing in two steps (pin, turn, Esc / right click back, tool closed safely, second click builds); a save loads
with our mods removed; existing stations renamed; bus and tram stops named the London way, renames definitive;
departure boards (click, window, platforms, Auto / All, layouts, arrivals, styles, colours, menu pictures, hanging
board, removal on bulldozing and from the diagram, platform tags, different content per station); road names
(rename on focus loss, names kept through changes, type, label choice, Abandoned, one window at a time, junction
numbers, under / over roads, postcodes, capacity, street map page, Adjust Road across roundabouts, London
postcodes only for a city named London); occlusion off with road names still drawn; day clock and calendar
basics; cockpit view below -100 m; night lighting cap. Details in `PATCHNOTES.md` and
`re_notes/known_issues.md`.

## Clean-up after testing

- Remove the test mod `tf3api_label_test` (a changed label shader) from the save and the mods folder.
- `[Converter] StationDebug` back to 0 if it is still set.
- Before any release: `ignoreSavedData` off and the development city removed in the road-names mod's
  `names.lua`.
