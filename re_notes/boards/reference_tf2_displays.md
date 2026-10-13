# The Transport Fever 2 displays mod: how it behaves

Reference for our departure boards, which have to work the way this mod did. The mod is "Dynamic Departures /
Arrivals Displays" for Transport Fever 2 (Steam Workshop 2749557458). **Read for its behaviour only - none of
its code, models or texts is used**; ours is written from the game's API and our own model.

## What the player does

1. Picks a display in the assets menu and places it near a station. There are four:
   - a departures display **for one train terminal** (platform): the next two trains at that terminal;
   - the same for a **street terminal** (kerb);
   - a departures display **for a station**: vehicles leaving from all its terminals;
   - an arrivals display **for a station**: vehicles approaching all its terminals.
2. **The display joins a station by itself.** On placing, stations within 100 m are looked for:
   - one: the display joins it;
   - several: a window "Pick a station to join" lists them by name, each with "Join" and "Go there"
     (moves the camera to it) and a "Go back";
   - none: a warning window "Cannot find a nearby station to join".
3. **Once attached, a display is tied to its station for good.** If the station is bulldozed, its displays
   are removed as soon as the game runs again.
4. A terminal display finds its terminal itself ("Auto": the nearest one; re-guessed when the station's
   configuration window or the display's own is closed), or the player sets the terminal number.
5. Settings when placing (and afterwards, in the display's window): style (on a post, hanging, floating;
   for station displays also wide ones), colour scheme (orange on black, white on blue, ...), align to the
   platform (terminal displays), time display - **minutes to go or clock time** (terminal displays), show
   intermediate destinations (yes / no).
6. A button in the bottom bar switches all displays on and off ("they can be performance-intensive"). When
   on, they refresh every 5 seconds.

There is no number, channel or other bookkeeping for the player: place it, it works.

## What a display shows

- **Terminal display:** two entries. Each: destination, the line's name, and the time - minutes to go
  (`5'`) or the clock time `HH:MM`, and `Due` when it is about to arrive. With intermediate destinations on,
  the next stop is shown as well when it differs from the destination. A clock.
- **Station departures display:** a heading `DEPARTURES`, column titles `To | (line) | platform | Time`, one
  row per vehicle - destination, line name, terminal number, clock time (`Due` when imminent) - the
  station's name as a footer, a clock.
- **Station arrivals display:** the same with `ARRIVALS`, `From` and the origin.
- When nothing is known: `Sorry no service` in place of a destination and `--:--` / `-` for the time; a
  line with a problem shows `!` for its time.
- **Line names:** if a line's name has a part in brackets, only that part is shown ("(IC 335) London -
  Rosenheim" shows "IC 335"; several bracketed parts are joined by a space); a name without brackets is
  shown whole; a name with empty brackets shows nothing.
- The clock is the game's running time read as a clock (`HH:MM:SS`), and all times are on it.

## How it predicts

Facts about the game's data it relies on (the same fields exist in Transport Fever 3):

- a vehicle's `stopIndex` is the **next** stop, counted from 0;
- `lineStopDepartures` are milliseconds of game time, 0 while not yet recorded;
- `sectionTimes` are seconds, and take a round of the line to fill in;
- `doorsTime` is microseconds.

It averages, over all vehicles of a line, the time from stop to stop (from the departure times, falling
back on section times, and on a fixed guess for a new line), and for each vehicle adds up the averages from
where it is to the station. "Accuracy improves over time" and drops for a while when vehicles are added or
removed.

## Where ours has to differ, and why

- Ours lights dots in a texture; the game gives no text on a model that a script can change cheaply. Each
  different content needs a texture of its own, of which the mod ships a fixed number (32). Displays that
  show the same thing share one. This is bookkeeping of ours and must stay invisible to the player; when
  all are in use, a further display says so instead of showing something wrong.
- One model and one colour (amber on black) so far.
