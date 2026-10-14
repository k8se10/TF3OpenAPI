# What needs testing in the game (2026-10-14)

Everything below is built and tested outside the game only, or seen only in part. Most important first within
each group. "Log" is `tf3api.log` next to the game executable; "game log" is the game's own `stdout.txt` in its
user-data folder (`crash_dump`).

## Crashes and save safety

1. **Placing tool closed with an object pinned.** Pin an object (first click), then close the tool (Esc, another
   tool, loading a save). The right button must still work in play; nothing may crash. Log: `the tool's close
   ... and destroy ... are watched`. (`7865d27`; issue #26)
2. **A save loads with our mods removed.** Copy a save, disable `tf3api_road_names`, `tf3api_departure_boards`,
   `tf3api_day_clock`, load the copy. Must load without errors. (issue #7)
3. **Road names come back from a save.** Save, quit, load: names and numbers the same. Game log: `from the save:`.

## Placing in two steps

4. Middle button held and dragged up or down: the height moves in 0.5 m steps, the view stays still.
5. Esc or a right click while pinned: the object follows the mouse again with its height and turn kept.
6. The second click after a turn builds first time. (issue #22)

## Stations, stops and names

7. **Existing stations** lose "Station" from names the game made. Log: `stations: N to lose "Station" ...`.
8. **New stations** are named without "Station" (`tf3api_station_names` enabled for the save). If not, the game
   does not take the mod's text for that name, and another route is needed.
9. **Bus and tram stops** named after the station beside them or the nearest side road; two-part names start with
   the road the stop is on. Log: `bus / tram stops: N to rename, ...`, after `the game's street name lists read`.
10. **Renames are definitive:** rename a stop or station yourself, reload: your name stays.

## Departure boards

11. A click on a board opens the board, not the station behind it.
12. Choosing platforms changes what the board shows.
13. Auto (Pn) / All / chosen platforms: a board serves the platform it stands at by itself.
14. **Boards placed at the track** (rail assets menu): they snap to the track, stand on the platform facing the
    right way, Left / Right works, and they join the station.
15. Layouts, arrivals boards, line-by-line redraw and scrolling, the three styles, casing and dot colours, menu
    pictures, the hanging board without a post, a bulldozed board forgotten.
16. Station diagram: platform tags on top of trains and boards.

## Roads

17. Renaming a road by clicking away from the name field (not Enter) keeps the name.
18. A renamed road keeps its name when extended, given a junction, or its type changed; to motorway drops it.
19. Road type and label choice, the Abandoned tickbox on a cut-off road.
20. Only one road or junction window open at a time.
21. Motorway junction numbers, and their windows.
22. A road under or over another does not take its name.
23. The road window's postcode and what the road can carry.
24. The street map page written from the game, with postcodes and city outlines.
25. Cities drawn by the player: one place for road numbers; London-style postcodes only for a drawn city.

## Day clock

26. Calendar modes: Realistic (the date changes at midnight), Balanced (on each hour), Transport Fever.
27. Sun and moon follow the clock; switched off, the game's own cycle returns.
28. Vehicle wear follows the calendar. Log: `vehicle wear and age follow the calendar: lifespans x ...`. A changed
    setting needs a restart of the game, not only a reload.

## Converter

29. Converted buses (eight packs): wheels, doors, engine sound, destination text on the blind, dirt.
30. Whole stations built by one construction: they place without stopping the game; trains and passengers use
    them.
31. A converted mod's items leave the menus when its old mod is taken out of `legacy_mods`; saves still load.
32. `[Converter] PackTextures=1`: converted vehicles look the same, their folders much smaller.
33. The P86: its rear end's blind, and how its label reads at a distance.

## Native fixes and measurements

34. Cockpit view below -100 m on build 40420.
35. Occlusion culling measured on and off on 40420.
36. Night lighting at `[Lighting] MaxLightsPerBucket=256` in heavy scenes: no "device lost", frame rate as before.

## Clean-up after testing

- Remove the test mod `tf3api_label_test` (a changed label shader) from the save and the mods folder.
- `[Converter] StationDebug` back to 0 if it is still set.
- Before any release: `ignoreSavedData` off and the development city removed in the road-names mod's
  `names.lua`.
