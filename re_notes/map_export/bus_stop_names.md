# Bus and tram stop names - research (2026-10-14)

Asked for: small bus and tram stops named after a local place or road, as in London; a stop beside a
station named after the station ("Southwark Station"), and a two-part name where two major places meet
("Southwark Station / The Cut"). The game today gives every station and stop the same `{townName} Station`
form (see PATCHNOTES, station names). Nothing below is built yet.

## What the sources say

**TfL bus stop graphics standard, issue 2** (`content.tfl.gov.uk/buses-bus-stop-graphics-standard-issue02.pdf`,
sections 4-7, 10):

- A stop flag carries, top to bottom: the roundel, the **stop name panel**, the **towards panel**, the route
  tiles. A **point letter** (a one- or two-character code in a disc on top of the flag) tells stops of one
  place apart.
- Stop name: one line where it fits (at most 19 characters a line at the main size), two lines rather than
  an abbreviation. Examples in the standard: "Trafalgar Square", "Tottenham Court Road", "Ealing Broadway
  Station".
- **Interchange stops**: "where a bus stop is located at a station interchange, network logos should be added
  to the end of the stop name" - the station's name is the stop's name ("Ealing Broadway Station", with the
  Underground / rail logos after it).
- **Secondary stop name**: "where a secondary stop name is required, it should be displayed at the smaller
  font size" - the standard's example is "Tottenham High Rd" over "White Hart Lane". This is the two-part
  name; in TfL's data it is written with a slash ("Sandell Street / Waterloo Station", "Southampton Street /
  Covent Garden", "Hampstead Heath Extension / Wildwood Road" are real stop names seen in third-party lists and
  a City Monitor article on the network).
- Towards panel: "Towards Trafalgar Square", "Towards Turnpike Lane and Southgate" - the general direction,
  not the route's last stop.
- Contracted place names: an approved list of abbreviations ("Rd", "St" ...) for when space is short.
- TfL (FOI answer, as summarised by the search; the page itself refused the fetch): stops are named for the
  route of travel and / or location; no business names, no advertising.

**NaPTAN, the national stop database** (GOV.UK "NaPTAN guide for data managers"; DfT "How to name bus stops
in NaPTAN"):

- **CommonName**: unique for an obvious group of stops within a locality. Acceptable: a nearby landmark, a
  nearby side street, or the stop's own street (only for a very short street with one group of stops).
  Unacceptable (for the CommonName field): two street names together, or a street name with a landmark.
- **Indicator**: tells stops with one CommonName apart - opp, o/s, adj, nr, "Stop A", bay / stance, or a
  bound ("N-bound"). Kept out of the name itself.
- The national rule against composites is about the database field; London's signs and data show composites
  ("X / Y") anyway - TfL's own standard has a secondary name. So: one name normally, a second one only when one
  name alone would be ambiguous or when two strong places meet.
- Mid-road stops on a long road with no landmark: named after the nearest side road, so stops along one road
  get distinct names (OSM talk-gb advice, consistent with NaPTAN).

## Rules as built (`core.stopNames`, `tf3api_road_names`; commits `238bbf9` .. `439f921`; not yet seen in the game)

For a small on-street bus or tram stop - an edge object of kind STOP_LEFT / STOP_RIGHT on a street segment;
termini and bus stations are buildings, not these, and keep the station naming. A stop's name is held by its
station group (`stationGroupSystem.getStationGroup`), so both sides of the road share one name.

1. **Station beside it** (a rail station within 150 m, `core.STOP_STATION_REACH`): "<station> Station" -
   "Southwark Station". The word stays here: it says the stop serves the station (the station's own name
   drops it). Where the stop's own road is a High Street or a numbered road, both: "Southwark Station /
   Southwark High Road".
2. **Otherwise the nearest side road** meeting the stop's road within 120 m (`core.STOP_SIDE_REACH`): "Mint
   Street".
3. **That name taken** (another stop near another junction with the same road): the road nearest the stop
   that joins Mint Street, not the stop's own road - on its own ("West Hill") when no bus route uses it (no
   stops on it), else "Oak Road / West Hill"; then "Oak Road / Mint Street" (user, 2026-10-14).
4. **In a two-part name the first half is always the road the stop sits on, or the station it serves** (user,
   2026-10-14).
5. **Otherwise its own road.** Never a motorway (they are known by number).
6. **Unique per map**: the first free candidate; all taken: the first one with "#2", "#3" as the game does.
   Station stops are named first.
7. **Renames are definitive** (user, 2026-10-14): the first time a stop is seen with a name the mod did not
   give it and the game would not make (`core.isGameStopName`: a town name, "... Station", the game's
   variant words, "Upper / Lower", "#n"), it is marked the player's and never renamed again. The marks and the
   names the mod gave are saved with the game (`b` lines of the saved choices).
8. **Existing stops are renamed too** (user's choice, 2026-10-14), a few a frame, with the game's own
   `makeEntitySetNameCmd` on the station group.

Not built: landmarks other than stations (hospitals, schools, parks - if the game exposes them), stop
letters / "opp" indicators, the "Towards" text, two-line names and contractions on our boards.

Unknowns for the first look in the game: that a stop edge object's entity gives its station group; where on the
road a stop is (its `EDGE_OBJECT` component's transform is tried, else the middle of its road piece).
