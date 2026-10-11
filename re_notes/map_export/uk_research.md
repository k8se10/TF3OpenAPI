# How it works in Britain: postcodes, post towns, cities and road numbers

Research for the road-names mod, 2026-10-11. Sources are listed at the end; every statement here comes from
them. The last section compares what the mod does today with what the sources say.

## Postcodes

**Structure.** A postcode is an outward code and an inward code separated by one space. The outward code is
the postcode area (one or two letters) plus the district; the inward code is the sector (one digit, 0-9)
plus the unit (two letters). Example: `LA1 1EX` is area LA, district 1, sector 1, unit EX.

**Formats of the outward code:** `A9`, `A99`, `AA9`, `AA99`, and in central London `A9A` (in E1, N1 and W1)
and `AA9A` (in WC, EC1-EC4 and SW1). Single-letter areas are only B, E, G, L, M, N, S and W.

**Letters not used:** Q, V and X in the first position; I, J and Z in the second; C, I, K, M, O and V in the
unit.

**Scale.** About 121 geographic areas, about 2,990 districts, about 11,200 sectors, about 1.7 million
postcodes. A postcode covers a group of addresses, typically around 10 to 15. An area can have up to 100
districts.

**What an area is.** Most areas are named after a major town or city (NR Norwich); some after a smaller town
(UB Uxbridge), a combination of towns, or a region (FY Fylde). The letters are a mnemonic: usually the first
two letters (CH Chester), the first and last (BH Bournemouth), or the first and a key syllable
(IV Inverness).

**What decides the boundaries.** The system was designed for one purpose: to help the Post Office sort mail
by machine. Areas do not follow county or council boundaries. Districts are often not even contiguous, and a
district's position within its area cannot be worked out from its number.

**District numbers.** Districts are normally numbered from 1 (a few areas start at 0 or 10). Numbering
usually runs outward from the main post town, and in most areas the central district of the main post town
is 1. Other patterns exist: by direction (HS runs north to south), in clusters round several towns, and in
London alphabetically.

## Post towns

A post town is a required line of every address, written in capitals, and is the basic unit of delivery.
There are about 1,500. Post towns began as the places with a delivery office.

A post town usually corresponds to one or more districts (Crawley is RH10 and RH11) and often covers many
towns and villages besides the one it is named after. Occasionally one district is shared by several post
towns (WN8: Wigan and Skelmersdale). They rarely match administrative boundaries.

An address is: street, optional locality, POST TOWN, postcode. The county is not needed.

So the hierarchy is: **area** (a major town, about 120) > **post towns** (about 1,500, so on average a dozen
per area) > **districts** (about 3,000, on average two per post town) > sectors > units. (The averages are
my arithmetic on the sources' counts.)

## London

**History.** Devised in 1856, introduced in 1857. Ten districts, each run like a separate post town: two
central ones, EC and WC, and eight compass points, N, NE, E, SE, S, SW, W, NW. NE was abolished in 1866 and
merged into E; S was abolished in 1868 and split between SE and SW. (Those letters were later reused: NE is
Newcastle, S is Sheffield.)

**Numbers, 1917.** As a wartime measure each district was subdivided. The sub-district served by the
district's head office became 1. **The rest were numbered alphabetically by the name of their delivery
office:** E2 Bethnal Green, E3 Bow, E4 Chingford, E5 Clapton; N2 East Finchley, N3 Finchley. So in London a
district's number says nothing about how far out it is: SE2 (Abbey Wood) is a long way from SE1.

**Counts.** E 19 districts, EC 4, N 22, NW 11, SE 28, SW 20, W 14, WC 2: 120 in all.

**SW has two series:** SW1 is the head district and SW2-SW10 run alphabetically (Brixton to West Brompton);
then a second "Battersea" series starts with its own head district at SW11 and runs to SW20. W2 is likewise
a second head district. SE28 (Thamesmead) was added later for a new development.

**Central subdivisions.** The busiest central districts were split further by adding a letter: E1, N1,
EC1-EC4, SW1, W1, WC1 and WC2.

**The postal district is not London.** It covers 620 km2; Greater London is 1,570 km2. Outer London uses
fifteen ordinary areas (BR, CR, HA, KT, TW, UB and others). "The London postal district has never been
aligned with the London boundary." Within it, LONDON is the post town, and the locality (Bethnal Green) is
an optional line.

## Cities

City status is granted by the monarch by letters patent. It does not depend on size and brings no powers.
There are 76: 55 in England, 8 in Scotland, 7 in Wales, 6 in Northern Ireland. Until 1889 it went with
having a cathedral.

**A city usually contains towns.** Many holders of city status are whole council districts: "Each includes a
number of towns and villages outside the urban area from which the district takes its name." The City of
Leeds includes Otley; the City of Canterbury includes Whitstable and Herne Bay; the City of Winchester
includes Bishop's Waltham. The towns inside keep their names and identities.

**London is not a city.** The City of London and the City of Westminster are the only parts of London with
city status; no London borough has been granted it.

## Road numbers

**Zones.** Numbering is radial from London (and from Edinburgh in Scotland). The single-digit roads radiate
from the centre, "allocated sequentially in a clockwise direction" from the A1, which goes north, and they
form the zone boundaries (the Thames stands in for the boundary between zones 1 and 2).

**Which zone a road belongs to:** "The first digit in the number of any road should be the number of the
furthest-anticlockwise zone entered by that road." The A38 starts in zone 3 and ends in zone 6.

**Two digits** supplement the radials, again clockwise from their single-digit road: A10, A11, A12, A13,
then the A2, then A20. **Three and four digits** "further split and criss-cross the radials", and "lower
numbers originate closer to London than higher numbered ones."

**B roads** are distributor roads with less traffic than A roads; their class "does not reflect physical
width or quality". They follow the same zones and almost always have three or four digits. Many three-digit
B roads outside London are former A roads, downgraded when a new road was built.

**Motorways** have their own zones, clockwise from the M1. "Shorter motorways typically take their numbers
from a parent motorway in contravention of the zone system": M48 and M49 are spurs of the M4, M271 and M275
of the M27. A stretch of A road upgraded to motorway keeps its number with `(M)`.

**In and round cities.** Ring roads usually get a number of their own (Coventry's is the A4053, Derby's the
A601, Leicester's the A594), though some are made of sections of several numbered roads (Leeds, Oxford). The
radial A roads run in to the ring or the centre and meet it at junctions.

**Gaps and duplicates.** A road can have a gap where a motorway replaced it (the A8 has a 25-mile gap for
the M8). The same number is occasionally used twice for unrelated roads.

**C, D and U roads** are local authority numbers that do not normally appear on signs.

## What the mod did, and what was changed after this research

| Topic | Before | Britain | Now |
|---|---|---|---|
| Postcode area | One per biggest 12% of towns | One per major town, holding many post towns | The biggest 4% of towns head an area |
| Post town | Same thing as an area | A level below the area | Every town is a post town with its own district |
| Districts | 2 km squares in a spiral | Patches round localities, 1 at the main town, then outward | A patch round each town; the main town is 1, the rest outwards |
| London numbers | Rings by distance | 1 is the head district, the rest alphabetical by locality | Head district nearest the centre, the rest alphabetical by town name |
| City and its towns | Inner towns demoted to local places | Towns keep their identity | Towns rank as any town; only the hub looks at the city as a whole |
| Road named after a city | "Greater Lewes Road" | "London Road" | The city's plain name |
| Zone of a road | Where it starts | The furthest-anticlockwise zone it enters | The furthest-anticlockwise zone it enters |
| Three- and four-digit numbers | By length | Lower nearer London | Lower nearer the hub |
| Short motorway off a long one | The parent's own number | A number derived from the parent (M48) | Parent's number plus a digit, when the parent is at least twice as long |

Still different from Britain:
- London's districts are irregular and SW and W have a second head district starting a second series; here
  each direction has one series.
- Districts are one per town; a big real post town has several.
- Central London's letter-suffixed districts (the `A9A` and `AA9A` forms) are not made.
- Ring roads have no number of their own; Station Road, Bypass and junction numbers are not built.
- Slip roads carry their motorway's number here; the sources do not say what they carry in Britain.

## Sources

- https://en.wikipedia.org/wiki/Postcodes_in_the_United_Kingdom
- https://en.wikipedia.org/wiki/London_postal_district
- https://en.wikipedia.org/wiki/Post_town
- https://en.wikipedia.org/wiki/City_status_in_the_United_Kingdom
- https://en.wikipedia.org/wiki/Great_Britain_road_numbering_scheme
- https://en.wikipedia.org/wiki/A4053_road (Coventry ring road)
- The user's own note on British road naming (not in this repository)
