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
