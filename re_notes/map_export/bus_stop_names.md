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

## Rules this gives (proposed, mine from the sources above)

For a small on-street bus or tram stop (not a terminus / bus station, which keeps the town's name):

1. **Station beside it** (a rail station within about 150 m, on the same road or a road leading from it):
   the station's name + "Station" - "Southwark Station". On a sign the word stays here: it says the stop
   serves the station (unlike the station's own name, which drops it).
2. **Landmark beside it** (another station or stop group of a kind, a town centre / High Street end, later
   anything we can name - hospitals, schools, parks if the game exposes them): its name.
3. **Otherwise the nearest side road** that meets the stop's road within about 120 m: "Wellington Road".
   No side road: the road the stop is on, when that road is short.
4. **Secondary name** ("A / B") only when the primary is a station or landmark AND another strong place is
   at the same spot: the stop's road is a High Street or a numbered road, or a second landmark - "Southwark
   Station / The Cut", "Brixton Station / Brixton Road". At most two parts.
4b. **When the side road's name is taken** (another stop near another junction with the same road), or the
   side road has bus stops of its own: the junction's two roads together - "Mint Street / West Hill" - or
   another road meeting there on its own, where that road has no bus stops of its own (user, 2026-10-14). A
   side road with its own bus stops is not used on its own: its name would point at its own stops.
5. **Unique per map** (our standing rule for names): stops with the same name are one group; within a group
   the two sides of the road get point letters / "opp" in the indicator, not a different name. If two
   unrelated stops would share a name, the second takes its side road instead.
6. **Length**: a name over 19 characters goes on two lines on our boards; contractions only from the TfL list
   ("Rd", "St", "Ave" ...) and only when it would not fit at all.
7. **Towards** (for later, boards and stop flags): the next major place along the route, not its last stop.

Inputs we already have: road names, numbers and types (road names mod), towns, rail stations by place
(`readStations`), the stop's position. Inputs to find: which stations in the game are small street stops vs
bus stations / termini (construction kind, `STATION` component of the stop), and how to set a stop's name
(`api.cmd.makeEntitySetNameCmd` on its station group or station - sets the saved name, as the player renaming
it does).

## Open decision

Renaming stops writes the names into the save (as a player renaming them would). Whether existing stops in a
save are renamed, only new ones, or only when the player asks (a button) - to be decided by the user.
