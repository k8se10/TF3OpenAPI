# Left-hand traffic is a property of the save (design, 2026-10-15, build 40420)

User requirements (2026-10-15): switching any left-hand traffic mod on or off must leave a save safe - including a player who uses
the other left-hand mod (`left_hand_traffic_1`) with ours disabled; ours listed incompatible; roundabouts and every building,
modded included, flipped correctly; vehicles flipped as the other mod does; clean on / off; clean up what the other mod can leave
in a save. Status words: **built** = in the DLL / mods and tested outside the game; **unseen** = never run in the game.

## The idea

The side of the road is not a mod setting, it is a fact about a save: its roads were built for one side. Mods only decide what the
data that gets loaded and built next is written for. So an always-on part of TF3OpenAPI reads the save's side and makes everything
built afterwards follow it, whichever mod, ours, the other one or none, is on:

| piece | where | does |
|---|---|---|
| **save guard** (`mod/tf3api_save_guard`, `autoActivate`) | game script `guard.script.lua` | per game: reads the **authored** side (what the street types as loaded were written for: majority of the two-way ones, `sides.lua`), decides the **desired** side, rewrites street types written for the other side through the official `streetTemplateRep.setAsTable` (each read back to verify), tells the native layer both sides, remembers the desired side in the game's script state |
| guard's run script (`content/mod.script.lua`) | `loadScript` modifier | wraps the six junction functions of `street_constructions.script`, the shared `constructWithModules`, and the update function of road depot / street station / industry scripts: when a result carries `edgeLists` and desired != authored, each one-way piece is turned and what names its nodes follows (`sides.edgeLists`: roundabouts, ramps, depot entrance streets) |
| native layer (`native/src/driving_side.cpp`) | hook on the engine's construction part converter `0x142c1e910`, reset on `UI::CMenuUI::PreLoadAsync` `0x1406a22b0` | turns the road lane lists of every construction part (stations, depots, yards, any mod's) and re-points their stops and depot ways exactly when desired != authored; forgets both sides when a game starts loading, so a game whose guard has not spoken is never touched |
| **left-hand traffic mod** (`mod/tf3api_left_hand_traffic`) | `loadModel` modifier | its being enabled is the choice of the left for a NEW game; mirrors road vehicles and trams built for the right (`vehicle.lua`); declares `left_hand_traffic_1` and `left_hand_traffic_dev_1` incompatible, and depends on the guard |

**The desired side** is, in this order: the one remembered with the game; the one its roads were built for (sample of about 600 street
segments, read from their own lane lists); for a new game with no roads the left when our mod is enabled; else the authored side
(the mods' data as it is). So:

| situation | authored | desired | result |
|---|---|---|---|
| right-hand save, no left-hand mod | R | R | nothing changes |
| right-hand save, the OTHER left-hand mod enabled | L | R | street types turned back, buildings and junction pieces turned back: the save stays right-hand |
| left-hand save made with the other mod, loaded with it | L | L | nothing changes |
| the same save, the other mod disabled (ours off too) | R | L | street types turned to the left, buildings and junction pieces too: the save stays left-hand |
| a new game, our mod on | R | L | all turned to the left |
| a new game, the other mod on | L | L | as that mod made it |

## Why this is clean (what is and is not rewritten)

* Nothing in a save is rewritten. Networks are saved as built (`re_notes/left_hand_traffic/saves.md`): loading changes no lane under a
  vehicle. Only what is built or rebuilt after the guard has spoken follows the desired side.
* Street types are changed in memory only, through the game's own API, and verified. If one will not change, the guard leaves the buildings alone
  as well and logs which type.
* The native state is per game: cleared when a game starts loading (PreLoadAsync), set once the guard has decided.
* Everything is guarded: a fault in a script step leaves the construction, model or street as it was.
* Mixed saves: the guard counts the roads of each side and logs `WARNING` when both are present (a left-hand mod switched while the game was
  played); it changes nothing there. A repair (rebuilding the minority segments through the game's own update route, which re-plans
  vehicles) is not built.

## Parity with `left_hand_traffic_1` (read for facts; nothing of its code used)

Read from its `config.lua`, `runtime.lua`, `vehicle.lua`, `vehicle_animation.lua` and the file headers:

| it does | ours | note |
|---|---|---|
| two-way street types turned | built (guard, `setAsTable`) | one-way types left alone as theirs |
| `busAndTramRight` set | built (`sides.setSide`) | |
| construction results adapted after the shared pipeline, for 6 street / depot scripts and 32 industries | built natively for ALL constructions (engine converter) | covers any mod; unseen |
| model-space facility lanes (`transportNetworkProvider`) | covered: the stock script copies them into the result before the engine converts it | unseen |
| roundabouts / interchange ramps | built (guard wrapper) | unseen; `tag2nodes`, snap and free nodes renumbered |
| modular street station: stop reflected along its platform chain, and the entrance / exit module names swapped | **not done**: our stops follow the lane (node ^ 1); the module names are not swapped | open |
| industry marking atlas replaced by a mirrored one (27 MB shipped) | **not done**: would be generated from the game's own atlas at launch, never shipped | open |
| traffic lights: the game's own `leftHandTraffic` detection | nothing needed (the game's) | unseen |
| vehicles: mirrored when entrances are right-only, or no entrances and a left driver; roots, sided events, bounds, seats, entrances, colliders, lights, emitters | built (`vehicle.lua`, tested) | labels use our own rule; trains, aircraft, ships are not touched |
| vehicles: steering input reversed for mirrored models (wraps every script function) | **not done**: front wheels of a mirrored vehicle may steer the wrong way visually; a narrow `loadTransformator` wrapper is the plan | open |
| vehicles: "entry" case (a physical left door already on the model) | not done: such a vehicle is left as built | |

## Not done / open

1. Steering of mirrored vehicles (above). 2. The modular street station's stop position and module names; the industry marking atlas.
3. Repair of a mixed save. 4. UI direction arrows and placement previews: nothing has been changed for them; the other mod's own note says
"road graphics use lane direction", i.e. the game draws them from the lanes, so they should follow the turned lanes - **unseen, to be checked in
the game** (one-way roads and two-way roads, while placing and when built). 5. The destination displays of mirrored vehicles are only
re-placed by the existing label rule: the on-vehicle display system is to be rebuilt on the boards' mechanism (user, 2026-10-15).
6. Whether `setAsTable` re-runs other mods' `loadStreetTemplate` modifiers (that would turn a type straight back; the read-back check catches it),
and whether changing a street type while the game runs is safe for the render threads.

## First things to look at in the game

`tf3api.log`: `driving side: ready ...`, then per game `[tf3api_save_guard] this game keeps to the X (...)` and
`driving side: this game keeps to the X, its data was written for the Y - buildings are turned | left as they are`.
Test matrix (new maps / copies of a save): ours on; the other mod on; neither; a left-hand save with each of the three.
