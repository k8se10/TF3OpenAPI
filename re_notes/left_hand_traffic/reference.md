# Left-hand traffic: what exists, and what "as good as native" has to mean

Read 2026-10-13 against game build 40420, the older game's files, and two existing mods. The two mods are
behavioural references only: nothing of their code or data is used. Nothing here has been tried in the game.

## The game itself

- **There is no driving side in the engine.** The executable has no such setting. The side follows from
  data: each street lane's `forward` flag (lanes are listed from kerb to kerb), the lane lists of stations,
  depots, stops and industries, and the vehicle models.
- **The game's own scripts already allow for left-hand lanes.** `infrastructure/traffic_light/
  trafficlightutil.lua` has a function `leftHandTraffic(args)` that works out, from which lanes of an
  approach need a light, whether traffic keeps left, and then puts the poles and beams on the other side.
  The same function is in the older game. So traffic lights need no change of ours: they follow the lanes.
- All 81 stock street templates are `roadType = "STREET"` with `laneConfigs` of
  `{ forward, height, offset, speed, transportModes, width }`. None sets `busAndTramRight`.

## The older game's mod (Transport Fever 2, Workshop 2092939800)

One script of about 200 lines and 83 textures. What it does:

1. Sets `game.config.leftHandTraffic = true` (a flag for other mods; the older game's executable does not
   contain the name).
2. Streets: reverses the ORDER of the lanes between the two pavements. (The newer game's lanes carry a
   `forward` flag instead; turning the flag is the equivalent.)
3. Road and tram depots: swaps the entry and exit nodes.
4. Station models: reverses each lane list that buses, trucks or trams use, negates the tangents, and
   re-points the stops.
5. Road vehicles and trams: mirrors the model by negating one term of the root transform; swaps the left
   and right indicator lists.
6. Labels on mirrored vehicles: moves each label's origin to the OTHER END of its text line (origin plus
   its width along its own direction) and then turns its direction round. A label is placed from one
   corner, so a mirrored label must start from what was its far corner. This is the step that keeps a
   destination blind's text on the blind.
7. Ships re-painted textures for 26 buses and 23 trams: lettering painted on a body comes out backwards
   when the body is mirrored, so those pictures were painted mirrored in advance.

Points 6 and 7 are what a mirror needs to look right. Point 7 cannot be done by rule in general (it needs
knowing where the lettering is on a picture); for the newer game it means: mirror a vehicle only where its
picture has no lettering to reverse, or flip the lettering's part of the picture, or do not offer it.

## The newer game's mod in use on the development save (mod.io 6418096, version 0.1.22)

Script only, about 3,000 lines; says of itself that its scope is new games. Parts:

| Part | What it changes |
| --- | --- |
| streets | two-way templates: every road lane's `forward` inverted; one-way: direction kept, lane purposes laid out from the other kerb; `busAndTramRight = false` |
| streets laid by constructions | reversed for the game's own roundabout and five interchange kinds; one-way templates the player draws are left alone |
| model lanes | road lane lists of station / depot models reversed pair by pair (ends swapped, tangents negated, `forwardOnly = true`) |
| constructions | results of the road depot, tram depot, maintenance station, modular street station, underground station, small stops and 32 industries: lanes reversed, terminals re-pointed |
| stop position | the modular street station's stop moved to the other end of its platform, keeping its clearance |
| entry / exit modules | the two one-way modules of the modular street station swap their meaning |
| industry markings | another picture for painted arrows on factory yards |
| vehicles | mirrored where its checks pass (375 in one session), otherwise left as built (334), 124 of those refused outright |
| vehicle animation | steering input reversed for mirrored models |

Seen on the development save: the destination blinds of mirrored buses are in the wrong place or
unreadable. Its label step multiplies each label by a fixed reflection; it does not move the label's origin
to the other end of the text as the older game's mod did (point 6 above). That difference is the likely
cause; not yet proven on screen.

## What ours has to do

- Lanes: the same result as the mod the existing saves were made with, wherever that mod acts. A save holds
  where each vehicle is on a lane; equal lanes mean nothing moves under any vehicle.
- Traffic lights: nothing (see above), to be confirmed on screen.
- Vehicles: one form of each. Mirrored where the mirror is right: labels re-placed from the other end of
  their line, indicators swapped, steering reversed, doors and seats on the kerb side, and no reversed
  lettering. Otherwise not offered. A model built for left-hand traffic is left exactly as built.
- A reset for vehicles and people where our lanes differ from the saved ones. What the game does by itself
  in that case has to be seen on a copy of a save first.

## Inventory: where road lanes live in the game's data (build 40420, counted from every archive)

Counted by script over all archives of the base game and the two packs, so that no case is left to be
found by trying.

| Where | How many | What carries the lanes |
| --- | --- | --- |
| street types (`infrastructure/street.zip`) | 81 templates, 75 with lanes for road vehicles | `laneConfigs[].forward`; 6 highway types are one-way (each carriageway its own street) |
| street station models (`stations/street.zip`, `modular_street_station/models`) | 234 models | `metadata.transportNetworkProvider.laneLists` on the model, the older game's form |
| street station scripts | 3 (`modular_terminal`, `modules`, `underground_station`) | lane lists, stops, street edges; the underground station lays `tram_new` |
| road depots (`depots/road.zip`) | 3 scripts (road depot, tram depot, maintenance station) | lane lists, entry / exit nodes, an entrance street (`street/constructions/entrance_*`) |
| industries (`industries/*.zip`) | one script each, about 118 KB | lanes and stops written out in the script as named lists (`lane_01`, `lane_terminal_input`, ...); road modes are not named as text there, so a text search does not find them |
| laid-out junctions (`street_construction.zip`) | 1 script | roundabout and interchanges, built from one-way town, country and highway types |
| airports, harbours, heliports | own scripts | stops for aircraft and ships; whether any has a road lane of its own is still to be read |
| shared | `scripts/construction/legacytransportnetworks.lua`, `construction_util_serialized.d.tl`, `base/base_mod.lua` | the step that turns model lanes into construction lanes, and the form constructions are stored in |

Consequence for the design: the cases are too many and too differently written to treat one by one
(the 32 industries alone). The place to act is the finished result of a construction - its lane lists with
their transport modes, its stops and its street edges - which has one form whatever script made it, and
which also covers constructions of other mods.

## How a vehicle's place is stored (from the API definitions)

`MovePath.path.edges` is a list of `{ EdgeId(entity, index), forward }`: an entity that has a transport
network, the number of an edge in it, and the direction along it; `dyn.pathPos` is the edge's place in
that list and the distance along it. So a saved vehicle refers to lanes by number within a street or a
construction. If those numbers mean the same lanes after loading, the vehicle is where it was. If a lane
has turned round, its saved path runs against the lane.

Not answered by the definitions, and it decides how a switch of mod must be handled: whether a street's
network is stored in the save as it was built or made again from its street type at each load.

## Inventory: the game's own road vehicles and trams

133 models in the base game and the two packs (77 road vehicles, 56 trams). 46 carry text labels: 16 road
vehicles (the London bus has 6) and 30 trams. Every stock label names the part it sits on. Driver and
passenger seats are a list of places on the model (`seatProvider.seats`), doors are animations.

## Still to be read before anything is built

1. The construction pipeline (`scripts/construction/construction.script.tl`) and the stored form of a
   result: where exactly a finished result can be changed, once, for every construction.
2. The street station's 234 models and its stop rule (which end of a platform a bus stops at).
3. One industry script in full: how its named lane lists become lanes, and which are one-way.
4. The junction script: which arms are one-way and how they are ordered.
5. The executable: what `busAndTramRight` does, how a kerb-side stop on a plain street picks its side,
   whether junction priority or turning assumes a side, whether a street's network is saved or rebuilt.
6. Each of the 133 vehicles: door side, driver's seat side, labels, and whether the body carries lettering
   (this last one needs the pictures looked at).

## The vehicles' own facts (counted from the game's models, build 40420)

**Driver's side**, from the seats marked as crew (`seatProvider.seats[].crew`), by which side of the
vehicle's length they are on: road vehicles 55 left, 13 right, 7 centre, 1 with no crew seat; trams 10
left, 4 right, 16 centre, 6 on both sides, 20 with none. So thirteen of the game's own road vehicles are
right-hand-drive as built and need nothing.

**Doors open by side.** The events a part can move on include `open_doors_left`, `open_doors_right` and
`open_all_doors` (with `close_...` to match): the game opens the doors on the side the platform is on.
Road vehicles: 13 models have `open_doors_right`, 6 `open_doors_left`, 10 `open_all_doors`; most have no
door animation at all. A mirrored vehicle needs its `..._left` and `..._right` events exchanged on every
part, and likewise `blink_lights_left_on/off` with `blink_lights_right_on/off`.

**Every event name in use**, by carrier (for the mirror, and for converting ships and aircraft):

| Carrier | Events on parts |
| --- | --- |
| road | `blink_lights_left_on/off`, `blink_lights_right_on/off`, `brake_lights_on/off`, `open/close_doors_left`, `open/close_doors_right`, `open/close_all_doors`, `drive`, `empty_load`, `forever` |
| tram | the road list, plus `front/back/inner_forward/backward_parts_on/off`, `pantograph`, `has_next_on/off`, `has_no_next_on/off`, `has_previous_on/off`, `has_no_previous_on/off` |
| rail | `front/back/inner_forward/backward_parts_on/off`, `open/close_doors_left/right`, `open/close_all_doors`, `pantograph`, `tilt`, `wheels`, `forever` |
| water | `paddles`, `rudder`, `drive`, `props_off`, `props_blurred_off`, `open/close_doors_left/right`, `open/close_all_doors`, `forever` |
| air | `aileron_left`, `aileron_right`, `elevator`, `rudder`, `flaps`, `pitch`, `open_wheels`, `close_wheels`, `props_on/off`, `props_blurred_on/off`, `beacon_lights`, `strobe_lights`, `landing_light_on/off`, `open/close_doors_left/right`, `open/close_doors_cargo`, `open/close_all_doors` |
