-- TF3 Optimizations - road names: the words street names are made from, following British practice.
-- Edit freely; a street's name only changes if its entry here changes (names already saved in a game are kept).

local names = {}

-- Road numbers, British style (see the notes at core.name).
names.zones = 6                      -- numbering zones fanning out clockwise from north around the hub town
names.motorwayPrefix = "M"
names.aRoadPrefix = "A"
names.aRoadLength = 1500             -- a main road at least this long gets an A number (metres)
names.bRoadPrefix = "B"
names.bRoadLength = 2500             -- a country road at least this long gets a B number (metres)

-- Every town gets a High Street: the longest ordinary street within this distance of its centre (metres).
names.highStreet = "High Street"
names.highStreetRadius = 350

-- "London Road": a main road (or any road at least destinationMinLength long) is named after the town it leads
-- to, when its far end is at least destinationMinReach from its own town and points within destinationAngle
-- degrees of another town.
names.destinationSuffix = "Road"
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
