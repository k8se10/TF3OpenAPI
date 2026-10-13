# How the game keeps time

Build 40420. Static reading of the executable and of the game's own scripts; nothing here was measured in
the running game. Addresses are for that build.

## What there is

| Thing | Where | What it is |
|---|---|---|
| Running time | `GameTime` component, first field (64-bit) | milliseconds of simulated time; stands still while paused, runs faster with the game's speed |
| Day list | `GameTime` component, a list of 16-byte entries | one entry per day begun: the running time at which it began, and the date as a day number |
| Calendar speed | `GameSpeed` component, first field (32-bit) | milliseconds per calendar day; 0 = the calendar stands still; 4000 where the engine needs a figure and has none |
| Game speed | `GameSpeed` component, second field | the speed-up factor |
| Sky time | `GameTime` component, `timeOfDaySec` | seconds of the day for the sun and moon; nothing in the engine advances it |

Script side (`api/tealdef`): components `GAME_TIME` (`gameTime`, `dates`, `timeOfDaySec`, `tickCount`,
`updateCount`) and `GAME_SPEED` (`speedup`, `millisPerDay`); commands `makeGameSetCalendarSpeedCmd(millisPerDay)`
("affects only the speed of the calendar, and not the simulation speed"), `makeGameSetDateCmd(date)`,
`makeGameSetTimeOfDayCmd(seconds)`; `api.engine.util.getCalendarDate(gameTime)`;
`api.util.getDefaultDayDuration()`, `getYearDuration(millisPerDay)`.

## How a day changes

`ecs::time_util::TickDays` (0x140bad780), called once per step from `GameSim::Step` (0x1401593d0):

- the next day boundary is the next **multiple of the day's length** after the present running time
  (`time + (length - time mod length)`), not "one day's length after the last change";
- for every boundary passed in this step an entry (boundary time, previous date + 1) is appended to the day
  list;
- with a length of 0 nothing is appended.

So: **place within the current day = running time modulo day length.** That is the time of day a clock
should show if the calendar day is to be the clock's day, and it needs neither the day list nor any state
of our own.

`CGameTime::GetDate` (0x1402a9170) and `CGameTime::GetDayNumber` (0x1402a9470) answer for any time: after
the last entry by adding (time - entry time) / day length to it, before it by a search in the list, and
for negative times by dividing by 4000. `CGameTime::ComponentChanged` (0x1402a8a90) compares the date
before and after a change and raises the year-changed, month-changed and day-changed signals;
`CGameTime::GameTimeChanged` (0x1402a8e10) serves subscribers that asked to be called every so many
milliseconds of running time (`CGameTime::OnIntervalStep`, 0x1402a96e0) - those are in running time, not
calendar days.

## Who reads the calendar

Readers of the calendar speed (all callers of the component getter 0x1402a3b70): `TickDays`, `GetDate`,
`GetDayNumber`, two small getters and the setter behind the command (0x140bad450). Callers of `GetDate`:
`simulation_util::Develop` (town development), the charts (`SnapDate`), and four unnamed functions.
The simulation's own periods (cooldowns, effects, the interval subscriptions) are counted in running time;
the game's interface converts them to calendar terms for display
(`formatDurationWithCurrentCalenderSpeed`).

**Not read yet:** who subscribes to the day / month / year signals (candidates: accounts by year,
availability of vehicles and buildings by date, vehicle age), and what `Develop` does with the date. Until
that is read, "a slower calendar changes nothing but the date" rests on the game's own description of its
calendar speed control (which offers stopped, 0.25x, 0.5x, 1x, 2x, 4x), not on our reading.

## Vehicle age and condition do not follow the calendar

Read from the game's own interface scripts (`gui/line_vehicle_mgmt/vehicle_util.tl`, `line_eow.script.tl`),
not yet from the executable:

- each part of a vehicle keeps `purchaseTime` (running time, milliseconds), `maintenanceState` and
  `maintenanceChange`;
- a model's `metadata.maintenance.lifespan` is in **seconds of running time**: the interface computes
  `lifespan * 1000` and compares it with `running time now - purchaseTime`;
- only the wording is calendar-based: `api.engine.util.formatAge(time0, time1)` turns a span of running
  time into "6 years" at the calendar's pace.

So a slower calendar changes what a vehicle's age is called, not when its lifespan runs out. How
`maintenanceState` falls (the part that makes a vehicle look and perform worn) is engine-side and unread;
`maintenanceChange` suggests a rate per running time. To make wear follow a slow calendar, the lifespan
would have to be scaled (a model modifier can do that) and the engine's wear rate found.

### Wear: the engine's rule (build 40420)

Found with `tools/ghidra/FloatStores.java` (functions that store floats at +0x38 and +0x3c and step by
0x60): **0x140b7e610**, called per vehicle from the vehicle system's update at 0x140b82100. A vehicle part
is 0x60 bytes; `maintenanceChange` is the float at +0x38, `maintenanceState` at +0x3c (1 = as new, 0 = worn
out). For every part, each call:

    rate   = interval * X / (lifespan * 100)
    decay  = rate * k                 k = 1, or 0.4 / 0.05 in two vehicle states (not yet identified;
                                      one is tied to the vehicle's state field at +0xa8, one to a depot count)
    repair = (1 / (0.1 * state + 0.07) - 3.25) * rate     only where the vehicle is being maintained
    change = repair - decay
    state  = clamp(state + change, 0, 1)

`lifespan` is the model's `metadata.maintenance.lifespan` (read through the metadata map by the key
"maintenance", integer at +0x10 of the record); X is the number beside it at +0x18 and `interval` a float
the caller passes - **neither is identified yet** (X is probably one of the record's scales, the interval
the step's time). So:

- **wear is linear in time and inversely proportional to the model's lifespan** - a vehicle with twice
  the lifespan wears at half the pace; there is no speed-up as it gets worse;
- repair is fastest on a badly worn vehicle (the bracket is 11 at state 0, 2.6 at 0.5, 0 at about 2.4 -
  never negative in range) and can be capped to the decay by a flag of the caller;
- nothing here reads the calendar: wear and the end of a lifespan both run on running time.

Stock lifespans (306 vehicle models): 10,958 to 43,830, clearly written as days (30 to 120 years of 365.25
days), most often 36,525. The interface treats the number as seconds of running time (`lifespan * 1000`
milliseconds), which at the stock four seconds a day is a quarter of it in calendar days: 36,525 reads as
25 years. No stock model sets `maintenanceScale`.

Other readers of the state: `vehicle_util_engine::CalcRunningCosts` (0x1426a1bf0, through 0x142694080) and
`vehicle_util::GetEmissionPenalty` (0x1426924c0, a table of levels).

## The sky

`game_mechanics/game_time/game_time.script.tl` sets the sky's time each update, by mode:

| Mode (name in the interface) | What it does |
|---|---|
| `Dynamic` (Dynamic) - the default | moves the sky towards a target drawn by chance from three states (noon, morning about 7:00, evening about 15:00), each held some minutes; forwards or backwards |
| `Automatic` (Continuous) | advances the sky steadily and wraps at 24 hours |
| `Local` (Local Time) | the computer's clock |
| `Constant` (Custom) | leaves it where the player put it |

The mode is kept in that script's saved state and changed by the event `GameTime` / `SetMode`.
The day list grows by one entry per calendar day for the whole life of a save (16 bytes each), and reading
the `GAME_TIME` component from a script hands the whole list over each time.

## What the day clock mod does with this

`mod/tf3api_day_clock`. The clock is the running time read as a clock (seconds = running time / 1000 modulo
86,400), so at normal game speed it runs in real time; the departure boards show the same. A setting picks
the calendar's pace:

| Mode | Milliseconds per day | Date changes |
|---|---|---|
| Realistic | 86,400,000 (fits the engine's 32-bit field) | at 00:00:00, because day boundaries are multiples of the day's length |
| Balanced | 3,600,000 | on every full hour of the clock |
| Transport Fever | the game's own, untouched (put back once if another mode had changed it) | every few seconds, as shipped |

A second setting ties the sky to the clock: the sky's mode is switched to `Constant` once and its time set
to the clock's whenever the two are 20 seconds apart; switched off, the mode it had is put back once.
Rules and their test: `day_clock.script.lua`, `tools/tests/day_clock_test.lua`.
