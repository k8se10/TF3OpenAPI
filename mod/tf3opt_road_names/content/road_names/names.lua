-- TF3 Optimizations - road names: the words street names are made from. Edit freely; a street's name only
-- changes if its entry here changes (names already saved in a game are kept).

local names = {}

-- Motorway-like roads get route numbers: M1, M2, ...
names.motorwayPrefix = "M"

-- A street counts as "in town" when it is within this distance of a town centre (metres).
names.townRadius = 900
-- Streets shorter than this get the "short street" endings (metres).
names.shortStreet = 160

names.suffixTown = { "Street", "Road", "Street", "Avenue", "Road", "Street", "Way", "Drive", "Street", "Row" }
names.suffixCountry = { "Road", "Lane", "Road", "Way", "Road", "Hill", "Road", "Lane" }
names.suffixShort = { "Lane", "Close", "Court", "Place", "Walk", "Mews", "Yard", "Passage", "Row", "Terrace" }
names.suffixMainTown = { "Avenue", "Boulevard", "Road", "Parade", "Avenue", "Broadway" }
names.suffixMainCountry = { "Road", "Highway", "Road", "Turnpike", "Way" }

names.base = {
	-- trees and plants
	"Oak", "Elm", "Maple", "Birch", "Cedar", "Willow", "Ash", "Beech", "Chestnut", "Hazel", "Holly", "Juniper",
	"Larch", "Linden", "Poplar", "Rowan", "Spruce", "Sycamore", "Walnut", "Alder", "Aspen", "Cherry", "Hawthorn",
	"Laurel", "Magnolia", "Myrtle", "Olive", "Pine", "Rose", "Thistle", "Clover", "Fern", "Heather", "Ivy", "Lavender",
	"Bramble", "Briar", "Orchard", "Meadow", "Garden",
	-- landscape
	"Hill", "Valley", "River", "Lake", "Brook", "Spring", "Forest", "Field", "Ridge", "Cliff", "Glen", "Dale", "Moor",
	"Marsh", "Heath", "Grove", "Park", "Bridge", "Ford", "Harbour", "Quarry", "Mill", "Stone", "Sand", "Shore", "Bay",
	"Summit", "Hollow", "Water", "Fountain", "Wood", "Green", "Common", "Warren", "Pond",
	-- town life
	"Church", "Chapel", "Abbey", "Castle", "Market", "Station", "Railway", "Canal", "Mill Pond", "School", "College",
	"Library", "Hospital", "Court", "Guild", "Exchange", "Foundry", "Forge", "Tannery", "Brewery", "Granary", "Dock",
	"Wharf", "Depot", "Tower", "Gate", "Wall", "Cross", "Bell", "Crown", "Anchor", "Lantern", "Clock", "Fair",
	"Cathedral", "Priory", "Manor", "Barracks", "Arsenal", "Mint", "Custom House", "Old Post", "Tramway", "Viaduct",
	-- directions and order
	"North", "South", "East", "West", "High", "Upper", "Lower", "Middle", "Long", "Broad", "Narrow", "New", "Old",
	"First", "Second", "Third", "Fourth", "Fifth", "King", "Queen", "Prince", "Duke", "Bishop", "Abbot", "Mayor",
	"Union", "Liberty", "Victory", "Commerce", "Industry", "Progress", "Unity", "Concord", "Charter", "Jubilee",
	-- people
	"Albert", "Alfred", "Arthur", "Charles", "Edward", "George", "Henry", "James", "John", "Richard", "Robert",
	"Thomas", "William", "Anne", "Catherine", "Charlotte", "Eleanor", "Elizabeth", "Margaret", "Mary", "Victoria",
	"Adams", "Baker", "Barton", "Bennett", "Carter", "Clarke", "Cooper", "Dawson", "Ellis", "Fletcher", "Foster",
	"Gardner", "Grant", "Harper", "Hayes", "Hudson", "Jackson", "Lambert", "Lawson", "Marshall", "Mason", "Mercer",
	"Miller", "Morgan", "Nelson", "Palmer", "Parker", "Porter", "Reed", "Sawyer", "Shepherd", "Spencer", "Stanley",
	"Sutton", "Taylor", "Thatcher", "Turner", "Walker", "Warner", "Webster", "Wheeler", "Whitaker", "Wright",
	-- places
	"Ashford", "Barrow", "Carlton", "Denton", "Easton", "Fairfax", "Garrick", "Hampton", "Kingsley", "Langley",
	"Milton", "Norton", "Oakley", "Preston", "Radley", "Stanton", "Thornton", "Upton", "Weston", "Windsor",
	"Arlington", "Belmont", "Clifton", "Dover", "Exeter", "Falmouth", "Grafton", "Hereford", "Kendal", "Lincoln",
	"Marlow", "Newbury", "Oxford", "Pembroke", "Richmond", "Salisbury", "Tiverton", "Wexford", "York", "Bristol",
	-- birds and animals
	"Swan", "Heron", "Falcon", "Raven", "Robin", "Finch", "Lark", "Kestrel", "Swallow", "Wren", "Fox", "Stag",
	"Badger", "Otter", "Hare", "Beaver", "Lion", "Eagle", "Dove", "Kingfisher",
}

return names
