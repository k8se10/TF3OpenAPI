-- TF3OpenAPI - road names: the words street names are made from, following British practice.
-- Edit freely; a street's name only changes if its entry here changes (names already saved in a game are kept).

local names = {}

-- Road numbers, British style (see the notes at core.name).
-- Development switch. true = every read of the road network names and numbers everything from scratch:
-- nothing remembered from earlier reads (and, once names are stored in the save, nothing from the save) is
-- used. For working on the naming rules, where the rules' own result is what should be seen.
-- MUST be false in a release: with it on, a player's roads are renamed whenever the network changes.
names.ignoreSavedData = true

names.zones = 6                      -- numbering zones fanning out clockwise from north around the hub town
names.motorwayPrefix = "M"
names.motorwayMinLength = 1609      -- a motorway-standard road gets a number of its own from one mile (both carriageways together)
names.slipMaxLength = 1609          -- a motorway-standard street up to one mile long with no junction along it is a slip road:
                                    -- it takes the number of the motorway it joins
names.aRoadPrefix = "A"
names.aRoadLength = 500              -- a main road at least this long gets an A number (metres)
-- How long an A road has to be for each length of number, shortest number first: A1, A10, A100, A1000.
-- The longest roads carry the shortest numbers; a road only gets a number of its tier while that tier has
-- numbers left in its zone (1, 10, 100 and 1000 of them), otherwise it moves to the next longer one.
-- No five-digit numbers: they are extremely rare in real life and are left for the player to set by hand.
names.aRoadTierLength = { 6000, 2500, 1000, 500 }
names.bRoadPrefix = "B"
names.bRoadLength = 1500             -- an ordinary road at least this long gets a B number, in or out of town (metres)
names.carriagewayGap = 200           -- two one-way roads running opposite ways within this distance are one road's two carriageways (metres)
names.parallelGap = 250              -- a second carriageway runs within this distance of the road it belongs to (metres)
names.parallelShare = 0.6            -- ... for at least this share of its length
names.connectorMaxLength = 250       -- a street up to this long that joins a numbered road at both ends is part of it (metres)
-- Development: cities to try the city rules with until there is a tool to draw one. Each is a circle round a
-- town: around = a town's name, or "@hub" for the biggest town; "%s" in the name is that town's name (a city
-- is known by a plain name, like London; roads to it are "London Road");
-- scheme = "grid" (an ordinary postcode area) or "compass" (London-style districts: EC, WC, N, E, SE, SW, W, NW).
-- MUST be empty in a release: cities are for the player to define.
names.devCities = {
	{ name = "%s", around = "@hub", radius = 4000 },
}

names.postAreaShare = 0.04           -- share of the towns (the biggest) that head a postcode area; every other town joins the nearest
names.postcodeSectorSize = 667       -- side of a postcode sector square, counted from the post town (metres); a unit is 1/20 of that
names.postcodeCentralRadius = 1500   -- in a compass city, towns within this distance of the centre are EC or WC (metres)
names.junctionRadius = 450           -- the points where a motorway meets other roads within this distance are one junction (metres)
names.dualShare = 0.6                -- share of a road's length that needs two lanes each way for a short number (A1, A10) or an M number
names.primaryTownShare = 0.12        -- share of the towns (the biggest) that count as primary destinations
names.primaryLinks = 3               -- each primary town is linked to this many of its nearest primary towns by A roads
names.localLinks = 2                 -- every town is linked to this many of its nearest towns by B roads (where no A road does it)
names.linkStretchMinimum = 200       -- a piece of a link shorter than this between two numbered roads gets no number (metres)
names.bRoadCountryLength = 800       -- out of town a road this long is enough for a B number
names.bRoadThreeDigitLength = 4000   -- B roads from this length get a three-digit number (B500), shorter ones four (B5000)

-- Every town gets a High Street: the longest ordinary street within this distance of its centre (metres).
names.highStreet = "High Street"
names.highStreetRadius = 350
names.highStreetMaxLength = 1500   -- a through road many kilometres long is not a High Street

-- "London Road": a main road (or any road at least destinationMinLength long) is named after the town it leads
-- to, when its far end is at least destinationMinReach from its own town and points within destinationAngle
-- degrees of another town.
-- The road a railway station stands on (not a bus stop, harbour or airport); %s is its town. The first free form is used (a name is used once on a map).
names.stationForms = { "Station Road", "%s Station Road", "Station Approach", "%s Station Approach" }
names.stationReach = 120             -- a railway station names the nearest road within this distance (metres)
-- Roads named for what they do; %s is the town. The first free form is used.
names.bypassForms = { "%s Bypass", "%s Relief Road" }
names.ringRoadForms = { "%s Ring Road", "%s Orbital" }
names.linkRoadForms = { "%s Link Road", "%s Link" }
names.bypassInner = 350              -- a bypass or ring road never comes nearer its town's centre than this (metres)
names.bypassOuter = 1800             -- ... and most of it lies within this
names.bypassMinLength = 900          -- shorter numbered roads are not bypasses
names.linkRoadMinLength = 150        -- a link road is this long at least ...
names.linkRoadMaxLength = 700        -- ... and this long at most, and joins two differently numbered roads
names.destinationSuffix = "Road"
-- A road name is used once on a map. The first road to a place gets the first form that is free; %s is the place.
names.destinationForms = { "%s Road", "Old %s Road", "%s New Road", "%s Lane", "%s Way", "Upper %s Road", "Lower %s Road", "%s Hill" }
names.destinationMinLength = 700
names.destinationMinReach = 500
names.destinationAngle = 25

-- A street counts as "in town" when it is within this distance of a town centre (metres).
names.townRadius = 900
-- Streets shorter than this get the "short street" endings (metres).
names.shortStreet = 160

names.suffixTown = { "Street", "Road", "Street", "Avenue", "Road", "Gardens", "Way", "Drive", "Crescent", "Grove", "Terrace", "Road" }
names.suffixCountry = { "Road", "Lane", "Road", "Way", "Lane", "Hill", "Road", "Lane", "Rise" }
names.suffixShort = { "Close", "Lane", "Court", "Place", "Walk", "Mews", "Yard", "Passage", "Row", "Terrace", "Close", "Gardens" }
names.suffixMainTown = { "Road", "Avenue", "Road", "Parade", "Way", "Street" }
names.suffixMainCountry = { "Road", "Way", "Road", "Bypass" }

names.base = {
	-- trees and plants
	"Oak", "Elm", "Maple", "Birch", "Cedar", "Willow", "Ash", "Beech", "Chestnut", "Hazel", "Holly", "Juniper",
	"Larch", "Lime", "Poplar", "Rowan", "Yew", "Sycamore", "Walnut", "Alder", "Aspen", "Cherry", "Hawthorn",
	"Laurel", "Magnolia", "Myrtle", "Elder", "Pine", "Rose", "Thistle", "Clover", "Fern", "Heather", "Ivy", "Lavender",
	"Bramble", "Briar", "Orchard", "Meadow", "Primrose", "Bluebell", "Foxglove", "Hollybush", "Mulberry", "Blackthorn",
	-- landscape
	"Hill", "Valley", "River", "Lake", "Brook", "Spring", "Forest", "Field", "Ridge", "Cliff", "Glen", "Dale", "Moor",
	"Marsh", "Heath", "Grove", "Park", "Bridge", "Ford", "Harbour", "Quarry", "Mill", "Stone", "Sand", "Shore", "Bay",
	"Summit", "Hollow", "Water", "Fountain", "Wood", "Green", "Common", "Warren", "Pond", "Beck", "Fell", "Mere",
	"Coppice", "Spinney", "Downs", "Weir", "Lea", "Combe", "Tor",
	-- town life
	"Church", "Chapel", "Abbey", "Castle", "Market", "Station", "Railway", "Canal", "Mill Pond", "School", "College",
	"Library", "Hospital", "Guildhall", "Exchange", "Foundry", "Forge", "Tannery", "Brewery", "Granary", "Dock",
	"Wharf", "Depot", "Tower", "Gate", "Wall", "Cross", "Bell", "Crown", "Anchor", "Lantern", "Clock", "Fair",
	"Cathedral", "Priory", "Manor", "Barracks", "Rectory", "Vicarage", "Tramway", "Viaduct", "Gasworks", "Colliery",
	"Cornmarket", "Butter Market", "Haymarket", "Fish Quay", "Almshouse", "Workhouse", "Toll Bar", "Turnpike",
	-- directions and order
	"North", "South", "East", "West", "Upper", "Lower", "Middle", "Long", "Broad", "Narrow", "New", "Old",
	"King", "Queen", "Prince", "Duke", "Bishop", "Abbot", "Mayor", "Earl", "Baron", "Regent",
	"Union", "Victory", "Jubilee", "Coronation", "Trafalgar", "Waterloo", "Albion", "Britannia", "Commercial",
	-- people
	"Albert", "Alfred", "Arthur", "Charles", "Edward", "George", "Henry", "James", "John", "Richard", "Robert",
	"Thomas", "William", "Anne", "Catherine", "Charlotte", "Eleanor", "Elizabeth", "Margaret", "Mary", "Victoria",
	"Adams", "Baker", "Barton", "Bennett", "Carter", "Clarke", "Cooper", "Dawson", "Ellis", "Fletcher", "Foster",
	"Gardner", "Grant", "Harper", "Hayes", "Hudson", "Jackson", "Lambert", "Lawson", "Marshall", "Mason", "Mercer",
	"Miller", "Morgan", "Nelson", "Palmer", "Parker", "Porter", "Reed", "Sawyer", "Shepherd", "Spencer", "Stanley",
	"Sutton", "Taylor", "Thatcher", "Turner", "Walker", "Warner", "Webster", "Wheeler", "Whitaker", "Wright",
	"Brunel", "Stephenson", "Telford", "Wellington", "Nightingale", "Gladstone", "Palmerston", "Peel", "Cromwell",
	-- places
	"Ashford", "Barrow", "Carlton", "Denton", "Easton", "Fairfax", "Garrick", "Hampton", "Kingsley", "Langley",
	"Milton", "Norton", "Oakley", "Preston", "Radley", "Stanton", "Thornton", "Upton", "Weston", "Windsor",
	"Arlington", "Belmont", "Clifton", "Dover", "Exeter", "Falmouth", "Grafton", "Hereford", "Kendal", "Lincoln",
	"Marlow", "Newbury", "Oxford", "Pembroke", "Richmond", "Salisbury", "Tiverton", "Wexford", "York", "Bristol",
	"Cambridge", "Chester", "Durham", "Lancaster", "Norfolk", "Suffolk", "Devon", "Cornwall", "Kent", "Sussex",
	"Balmoral", "Sandringham", "Buckingham", "Kensington", "Chatsworth", "Blenheim",
	-- birds and animals
	"Swan", "Heron", "Falcon", "Raven", "Robin", "Finch", "Lark", "Kestrel", "Swallow", "Wren", "Fox", "Stag",
	"Badger", "Otter", "Hare", "Nightingale Wood", "Kingfisher", "Curlew", "Plover", "Magpie",
}

return names
