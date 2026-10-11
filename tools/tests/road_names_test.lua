-- Offline test for the road-name mod: stubs the game API with a small synthetic town and runs the real script.
-- Usage: lua road_names_test.lua <path to mod content folder>
local content = arg[1]
local logs = {}
function debugPrint(t) logs[#logs + 1] = t end
local now = 0
os.clock = function() return now end
local ignoreSavedData = false   -- the development switch in names.lua, set by the test
local devCities = {}            -- likewise the development cities
function ug_require(path)
	local file = path:match("::/(.+)$")
	local module = dofile(content .. "/" .. file)
	if file:match("names%.lua$") then
		assert(type(module.ignoreSavedData) == "boolean", "names.lua has the ignoreSavedData switch")
		module.ignoreSavedData = ignoreSavedData
		assert(type(module.devCities) == "table", "names.lua has the development cities list")
		module.devCities = devCities
	end
	return module
end

-- Synthetic network: a 5 x 5 grid of 100 m blocks (ordinary streets), one wide avenue through the middle built
-- from slightly bent pieces, a fast motorway passing by with a slip road, and a cul-de-sac.
local nodes, edges = {}, {}
local function node(x, y) local id = #nodes + 1000; nodes[#nodes + 1] = { id = id, x = x, y = y }; return id end
local function edge(a, b, lanes, opts)
	local na, nb
	for _, n in ipairs(nodes) do if n.id == a then na = n end if n.id == b then nb = n end end
	local e = { node0 = a, node1 = b, position0 = { x = na.x, y = na.y, z = 0 }, position1 = { x = nb.x, y = nb.y, z = 0 },
		tangent0 = { x = nb.x - na.x, y = nb.y - na.y, z = 0 }, tangent1 = { x = nb.x - na.x, y = nb.y - na.y, z = 0 },
		laneConfigs = lanes, roadTemplate = opts and opts.tmpl or "street_small", type = "NORMAL",
		distance = math.sqrt((nb.x - na.x) ^ 2 + (nb.y - na.y) ^ 2) }
	-- routing data as the game keeps it: one-way car lanes with their own geometry, plus a pavement lane
	if opts and opts.drive then
		local from, to = na, nb
		if opts.drive < 0 then from, to = nb, na end
		local function lane(modes) return { geometry = { straight = { pos = { { x = from.x, y = from.y }, { x = to.x, y = to.y } } } }, transportModes = modes, forwardOnly = true } end
		e.network = { edges = { lane({ [3] = true }), lane({ [3] = true }), lane({ [1] = true }) } }
	end
	edges[#edges + 1] = e
	return #edges + 5000
end
local small = { { width = 3, speed = 11 }, { width = 3, speed = 11 } }
local wide = { { width = 5.5, speed = 16 }, { width = 5.5, speed = 16 }, { width = 5.5, speed = 16 }, { width = 5.5, speed = 16 } }  -- 22 m: a main road by width
local fast = { { width = 4, speed = 33 }, { width = 4, speed = 33 } }
local fastOneWay = { { width = 4, speed = 33, forward = true }, { width = 4, speed = 33, forward = true } }
local grid = {}
for ix = 0, 5 do grid[ix] = {} for iy = 0, 5 do grid[ix][iy] = node(ix * 100, iy * 100 + ((iy == 3) and (ix % 2) * 6 or 0)) end end
for ix = 0, 5 do for iy = 0, 5 do
	if ix < 5 then edge(grid[ix][iy], grid[ix + 1][iy], iy == 3 and wide or small, iy == 3 and { tmpl = "avenue" } or nil) end
	if iy < 5 then edge(grid[ix][iy], grid[ix][iy + 1], small) end
end end
local m = {}
for i = 0, 8 do m[i] = node(-200 + i * 150, -150) end
for i = 0, 7 do edge(m[i], m[i + 1], fastOneWay, { tmpl = "motorway" }) end
-- the motorway's other carriageway, 25 m to the south and running the other way, with a short slip road off it
local mb = {}
for i = 0, 8 do mb[i] = node(-200 + i * 150, -175) end
for i = 0, 7 do edge(mb[i + 1], mb[i], fastOneWay, { tmpl = "motorway_b" }) end
edge(mb[4], node(300, -375), fastOneWay, { tmpl = "motorway_slip" })
-- a motorway-standard link that leaves the motorway and has an ordinary street joining it half-way: too much
-- of a road to be a slip road, but it is built to motorway standard and joined to the motorway, so it is
-- part of it all the same
local linkMid, linkEnd = node(-50, -435), node(-200, -695)
edge(mb[2], linkMid, fastOneWay, { tmpl = "motorway_link" }); edge(linkMid, linkEnd, fastOneWay, { tmpl = "motorway_link" })
edge(linkMid, node(250, -435), small, { tmpl = "side_street" })
-- a second motorway far to the north whose lanes carry no direction (as the game reports them): two
-- carriageways 30 m apart, both drawn west to east
local na, nb = {}, {}
for i = 0, 12 do na[i] = node(-400 + i * 150, 2000); nb[i] = node(-400 + i * 150, 2030) end
for i = 0, 11 do edge(na[i], na[i + 1], fast, { tmpl = "motorway_n1", drive = 1 }); edge(nb[i], nb[i + 1], fast, { tmpl = "motorway_n2", drive = -1 }) end
edge(m[3], grid[2][0], small, { tmpl = "sliproad" })          -- slip road joins the grid
local cul = node(560, 240); edge(grid[5][2], cul, small)      -- cul-de-sac off the east edge
-- a second town 3 km to the east, joined by a wide main road that starts at the avenue's east end; its middle
-- kilometre is built to motorway standard (the A road's motorway section)
local prev, mainRoad, section = grid[5][3], {}, {}
for i = 1, 12 do
	local nx = node(500 + i * 200, 300 + (i % 2) * 4)
	local isSection = i >= 5 and i <= 9
	local e = edge(prev, nx, isSection and fast or wide, { tmpl = isSection and "motorway_section" or "main" })
	if isSection then section[#section + 1] = #edges else mainRoad[#mainRoad + 1] = #edges end
	prev = nx
end

-- a main road far to the north-west that passes through a roundabout: three 200 m pieces on each side, an
-- eight-piece one-way ring of 30 m radius between them, and a small side street off the ring's north side
local ringNodes = {}
for k = 0, 7 do ringNodes[k] = node(-3000 + 30 * math.cos(k * math.pi / 4), 3000 + 30 * math.sin(k * math.pi / 4)) end
for k = 0, 7 do edge(ringNodes[k], ringNodes[(k + 1) % 8], small, { tmpl = "ring", drive = 1 }) end
local westPrev, eastPrev = ringNodes[4], ringNodes[0]
for k = 1, 3 do
	local w, e = node(-3030 - k * 200, 3000), node(-2970 + k * 200, 3000)
	edge(westPrev, w, wide, { tmpl = "ring_west" }); edge(eastPrev, e, wide, { tmpl = "ring_east" })
	westPrev, eastPrev = w, e
end
edge(ringNodes[2], node(-3000, 3200), small, { tmpl = "ring_side" })
-- an ordinary one-way link from the end of the motorway slip road on to a side road
local slipEnd
for _, n in ipairs(nodes) do if n.x == 300 and n.y == -375 then slipEnd = n.id end end
local linkRoadEnd = node(420, -520)
edge(slipEnd, linkRoadEnd, small, { tmpl = "slip_link", drive = 1 })
edge(linkRoadEnd, node(420, -700), small, { tmpl = "beyond_link" }); edge(linkRoadEnd, node(600, -520), small, { tmpl = "beyond_link2" })

-- an ordinary country road 2 km long, well away from both towns: a B road
local bPrev = node(1500, -3000)
for k = 1, 10 do
	local nx = node(1500 + k * 200, -3000 + (k % 2) * 5)
	edge(bPrev, nx, small, { tmpl = "country_byway" })
	bPrev = nx
end

-- the main road to Farley has a second carriageway for 600 m near its far end: a one-way road that leaves it,
-- runs 80 m to the north and joins it again, with a short two-way connector half-way
local splitFrom, splitMid, splitTo
for _, n in ipairs(nodes) do
	local onMainRoad = n.y >= 300 and n.y <= 304
	if onMainRoad and n.x == 500 + 10 * 200 then splitFrom = n end
	if onMainRoad and n.x == 500 + 11 * 200 then splitMid = n end
	if onMainRoad and n.x == 500 + 12 * 200 then splitTo = n end
end
do
	local c1, c2, c3 = node(splitFrom.x + 100, splitFrom.y + 80), node(splitMid.x, splitMid.y + 80), node(splitTo.x - 100, splitTo.y + 80)
	edge(splitFrom.id, c1, wide, { tmpl = "second_carriageway", drive = 1 })
	edge(c1, c2, wide, { tmpl = "second_carriageway", drive = 1 })
	edge(c2, c3, wide, { tmpl = "second_carriageway", drive = 1 })
	edge(c3, splitTo.id, wide, { tmpl = "second_carriageway", drive = 1 })
	edge(c2, splitMid.id, small, { tmpl = "carriageway_connector" })
end

local saved
app = { saveUserdata = function(dir, file, t) saved = { dir = dir, file = file, t = t } end }
api = { type = { ComponentType = { BASE_EDGE = 1, BASE_EDGE_STREET = 2, TOWN = 3, BOUNDING_VOLUME = 4, TRANSPORT_NETWORK = 5 },
	enum = { TransportMode = { PERSON = 1, CAR = 3 } } }, engine = { util = {} } }
-- as in the game: street segments cannot be enumerated by component type; the street system's node map can
api.engine.system = { streetSystem = { getNode2StreetEdgeMap = function()
	local map = {}
	for i, e in ipairs(edges) do
		for _, n in ipairs({ e.node0, e.node1 }) do
			map[n] = map[n] or {}
			table.insert(map[n], i + 5000)
		end
	end
	return map
end } }
api.engine.getEntitiesWithComponent = function(c)
	if c == 2 then error("Cannot loop over this component type") end
	if c == 3 then return { 9001, 9002 } end
	return {}
end
api.engine.getComponent = function(e, c)
	if c == 1 then return edges[e - 5000] end
	if c == 5 then return edges[e - 5000] and edges[e - 5000].network end
	if c == 4 and e == 9002 then return { bbox = { min = { x = 2800, y = 100, z = 0 }, max = { x = 3200, y = 500, z = 50 } } } end
	if c == 4 then return { bbox = { min = { x = 0, y = 0, z = 0 }, max = { x = 500, y = 500, z = 50 } } } end
end
api.engine.util.getEntityName = function(e) return e == 9002 and "Farley" or "Testville" end

local M = dofile(content .. "/road_names/road_names.script.lua")
for frame = 1, 400 do now = now + 0.02; M.guiUpdate() end
assert(saved ~= nil, "export was written")
local t = saved.t
assert(#t.segments == #edges, "every segment exported")

local byName, segOfStreet = {}, {}
for i, s in ipairs(t.streets) do byName[s[1]] = i end
local function streetOfEdge(i) return t.segments[i][1] end
-- 1. each grid row and column is one street of 5 segments (rows 0-5 except the avenue row; columns 0-5)
local sizes = {}
for _, s in ipairs(t.streets) do sizes[s[6]] = (sizes[s[6]] or 0) + 1 end
-- 2. the avenue (row 3, bent by 6 m every block) is ONE street of 5 segments, class 2
local avenue
for i, e in ipairs(edges) do if e.roadTemplate == "avenue" then avenue = avenue or streetOfEdge(i); assert(streetOfEdge(i) == avenue, "avenue stays one street through its bends") end end
-- it carries straight on out of town as the main road, up to where the motorway-standard section starts: 5 + 4
assert(t.streets[avenue][2] == 2 and t.streets[avenue][6] == 9, "avenue + main road: class 2, 9 segments, got " .. t.streets[avenue][6])
assert(streetOfEdge(mainRoad[1]) == avenue, "the avenue and the main road out of town are one street")
-- 3. the motorway is one street of 8 segments, class 3, with a route number; the slip road is not part of it
local mway, slip
for i, e in ipairs(edges) do
	if e.roadTemplate == "motorway" then mway = mway or streetOfEdge(i); assert(streetOfEdge(i) == mway, "motorway is one street") end
	if e.roadTemplate == "sliproad" then slip = streetOfEdge(i) end
end
assert(t.streets[mway][2] == 3 and t.streets[mway][6] == 8, "motorway: class 3, 8 segments")
-- British numbering: the hub is Testville (most road); the motorway runs from the south-west round to the east of it,
-- through zones 4, 3 and 2 of 6; a road takes the furthest-anticlockwise zone it enters, which is 2,
-- and as the longest motorway of its zone it gets the bare zone digit
assert(t.hub == "Testville", "hub town is the one with the most road, got " .. tostring(t.hub))
assert(t.streets[mway][1] == "M2" and t.streets[mway][7] == "M2", "motorway is known by its number, M2; got " .. t.streets[mway][1])
assert(slip ~= mway, "slip road is its own street")
-- 3b. the opposite carriageway is a street of its own but the same road: it carries the same number, and the
--     short motorway-standard slip road off it carries the motorway's number
local other, mslip, mslipEdge
for i, e in ipairs(edges) do
	if e.roadTemplate == "motorway_b" then other = other or streetOfEdge(i); assert(streetOfEdge(i) == other, "second carriageway is one street") end
	if e.roadTemplate == "motorway_slip" then mslip = streetOfEdge(i); mslipEdge = i end
end
assert(other ~= mway and t.streets[other][7] == "M2", "both carriageways carry one number, got " .. tostring(t.streets[other][7]))
assert(mslip ~= other and mslip ~= mway, "motorway slip road is its own street")
assert(t.streets[mslip][1] == "M2" and t.streets[mslip][7] == "M2",
	"a motorway slip road is part of its motorway, got '" .. tostring(t.streets[mslip][1]) .. "' / " .. tostring(t.streets[mslip][7]))
local n1, n2
for i, e in ipairs(edges) do
	if e.roadTemplate == "motorway_n1" then n1 = streetOfEdge(i) end
	if e.roadTemplate == "motorway_n2" then n2 = streetOfEdge(i) end
end
local n1Edge, n2Edge
for i, e in ipairs(edges) do
	if e.roadTemplate == "motorway_n1" then n1Edge = i end
	if e.roadTemplate == "motorway_n2" then n2Edge = i end
end
assert(t.segments[n1Edge][14] == 1 and t.segments[n2Edge][14] == -1, "direction of travel read from the routing data")
assert(n1 ~= n2 and t.streets[n1][7] ~= "" and t.streets[n1][7] == t.streets[n2][7] and t.streets[n1][7] ~= "M2",
	"the two carriageways share one number, got " .. tostring(t.streets[n1][7]) .. " / " .. tostring(t.streets[n2][7]))
-- 3c. the roundabout is one street, and it and both sides of the main road through it carry one number; the
--     ring has the main road's name, and the side street is not part of any of it
local ringStreet, westStreet, eastStreet, sideStreet, slipLink
for i, e in ipairs(edges) do
	if e.roadTemplate == "ring" then ringStreet = ringStreet or streetOfEdge(i); assert(streetOfEdge(i) == ringStreet, "the roundabout is one street") end
	if e.roadTemplate == "ring_west" then westStreet = streetOfEdge(i) end
	if e.roadTemplate == "ring_east" then eastStreet = streetOfEdge(i) end
	if e.roadTemplate == "ring_side" then sideStreet = streetOfEdge(i) end
	if e.roadTemplate == "slip_link" then slipLink = streetOfEdge(i) end
end
assert(ringStreet ~= westStreet and ringStreet ~= eastStreet and ringStreet ~= sideStreet, "no road is merged into the ring")
local ringRef = t.streets[ringStreet][7]
assert(ringRef ~= "" and ringRef:sub(1, 1) == "A", "the roundabout carries an A number, got '" .. tostring(ringRef) .. "'")
assert(t.streets[westStreet][7] == ringRef and t.streets[eastStreet][7] == ringRef,
	"the main road keeps its number across the roundabout, got " .. tostring(t.streets[westStreet][7]) .. " / " .. ringRef .. " / " .. tostring(t.streets[eastStreet][7]))
assert(t.streets[ringStreet][1] == t.streets[westStreet][1] or t.streets[ringStreet][1] == t.streets[eastStreet][1], "the roundabout has the main road's name")
assert(t.streets[sideStreet][7] ~= ringRef, "the side street does not take the main road's number")
-- 3d. where the slip road ends, the motorway ends: the ordinary road that carries on from it (one-way here)
--     has no motorway number, and is named like any other road
assert((t.streets[slipLink][7] or ""):sub(1, 1) ~= "M" and #t.streets[slipLink][1] >= 2 and t.streets[slipLink][1] ~= t.streets[mway][1],
	"an ordinary road beyond a slip road is not part of the motorway, got " .. tostring(t.streets[slipLink][7]) .. " '" .. tostring(t.streets[slipLink][1]) .. "'")
-- no motorway number anywhere on a road that is not built to motorway standard
for i, e in ipairs(edges) do
	local st = t.streets[streetOfEdge(i)]
	local template = e.roadTemplate
	if not template:find("motorway") then
		assert(not (st[7] or ""):match("^M%d") and not (st[7] or ""):match("%(M%)$"), "the " .. template .. " road carries a motorway number: " .. tostring(st[7]))
	end
end
-- 3e. the long ordinary country road is a B road with a four-digit number (under 4 km), and keeps a name
local lane
for i, e in ipairs(edges) do if e.roadTemplate == "country_byway" then lane = streetOfEdge(i) end end
assert(t.streets[lane][7]:match("^B%d%d%d%d$"), "a 2 km country road gets a four-digit B number, got '" .. tostring(t.streets[lane][7]) .. "'")
assert(t.streets[lane][1] ~= t.streets[lane][7] and #t.streets[lane][1] >= 2, "a B road still has a street name")
-- 3f. the second carriageway and the connector across to it are the A2 too, with the A2's street name
for i, e in ipairs(edges) do
	if e.roadTemplate == "second_carriageway" or e.roadTemplate == "carriageway_connector" then
		local st = t.streets[streetOfEdge(i)]
		assert(st[7] == "A2", e.roadTemplate .. " carries the main road's number, got " .. tostring(st[7]))
		assert(st[1] == t.streets[streetOfEdge(mainRoad[#mainRoad])][1], e.roadTemplate .. " has the main road's name, got " .. tostring(st[1]))
	end
end
local link
for i, e in ipairs(edges) do if e.roadTemplate == "motorway_link" then link = streetOfEdge(i) end end
assert(t.streets[link][7] == "M2" and t.streets[link][1] == "M2",
	"a motorway-standard road joined to a motorway carries the motorway's number, got " .. tostring(t.streets[link][7]))
assert(t.segments[1][14] == 0 and t.segments[mslipEdge][14] == 1, "one-way flag exported per segment")
-- 4. every street has a name
local seen = {}
for i, s in ipairs(t.streets) do assert(type(s[1]) == "string" and #s[1] >= 2); seen[s[1]] = (seen[s[1]] or 0) + 1 end
-- 4a. names and numbers are unique on the map: two streets only share a name when they are one road (they
--     then share its number too: carriageways, roundabouts, a motorway's slip roads), and a number is never
--     on two roads with different names unless it is a numbered route running along named streets
do
	local byName = {}
	for _, st in ipairs(t.streets) do
		local name, ref = st[1], st[7] or ""
		if byName[name] == nil then
			byName[name] = ref
		else
			assert(ref ~= "" and byName[name] == ref, "the name '" .. name .. "' is on two different roads (numbers '" .. tostring(byName[name]) .. "' and '" .. ref .. "')")
		end
	end
end
-- 4b. British touches
local highStreets = 0
for _, st in ipairs(t.streets) do if st[1] == "High Street" then highStreets = highStreets + 1 end end
assert(highStreets == 1, "exactly one road on the map is plain High Street (the hub's), got " .. highStreets)

--     the main road east of the grid lies due east of the hub = zone 2; it is the road from the hub to the
--     next town, a radial, so it carries the zone's single digit: the A2. It is named after the town it leads
--     to, and its motorway-standard middle is the A2(M)
local mainStreet = streetOfEdge(mainRoad[#mainRoad])
assert(t.streets[mainStreet][7] == "A2", "main road number A2, got " .. tostring(t.streets[mainStreet][7]))
assert(t.streets[mainStreet][1] == "Testville Road" or t.streets[mainStreet][1] == "Farley Road",
	"main road is named after the town it leads to, got " .. t.streets[mainStreet][1])
local sectionStreet = streetOfEdge(section[1])
assert(t.streets[sectionStreet][7] == "A2(M)" and t.streets[sectionStreet][1] == "A2(M)",
	"motorway-standard section of the A2 is the A2(M), got " .. tostring(t.streets[sectionStreet][7]))
-- 5. grid: 5 plain rows + 6 columns + the avenue = 12 streets. Two of them pick up one extra segment that
--    continues them in a nearly straight line (row 2 + the cul-de-sac, column 2 + the slip road): 10 x 5, 2 x 6.
assert(sizes[5] == 10, "expected 10 five-segment streets, got " .. tostring(sizes[5]))
-- 6. deterministic: a second run gives identical names
local first = {}
for i, s in ipairs(t.streets) do first[i] = s[1] end
saved = nil; now = 0
M = dofile(content .. "/road_names/road_names.script.lua")
for frame = 1, 400 do now = now + 0.02; M.guiUpdate() end
for i, s in ipairs(saved.t.streets) do assert(s[1] == first[i], "names are stable between runs") end
-- 7. segment key ignores direction
local core = dofile(content .. "/road_names/core.lua")
assert(core.segKey({ x0 = 1, y0 = 2, z0 = 3, x1 = 4, y1 = 5, z1 = 6 }) == core.segKey({ x0 = 4, y0 = 5, z0 = 6, x1 = 1, y1 = 2, z1 = 3 }))

-- 7a. what a road connects decides its number, and how many lanes it has limits how short that number may be:
--     two towns 3 km apart joined by one road. With two lanes each way it is the single-digit radial; with one
--     lane each way it is an A road of three digits.
do
	local names = dofile(content .. "/road_names/names.lua")
	local function build(lanesEachWay)
		local list = {}
		for k = 0, 14 do
			list[#list + 1] = { n0 = k, n1 = k + 1, x0 = k * 200, y0 = 0, z0 = 0, x1 = (k + 1) * 200, y1 = (k % 2) * 3, z1 = 0,
				tx0 = 200, ty0 = 0, tx1 = 200, ty1 = 0, len = 200, w = 14, sp = 22, tmpl = "country_old_small", oneway = 0, dirLanes = lanesEachWay }
		end
		-- a few side streets so each end is a town with some road in it
		for k = 1, 6 do
			list[#list + 1] = { n0 = 0, n1 = 100 + k, x0 = 0, y0 = 0, z0 = 0, x1 = -40 * k, y1 = 60 * k - 200, z1 = 0, tx0 = 1, ty0 = 1, tx1 = 1, ty1 = 1,
				len = 150, w = 12, sp = 11, tmpl = "town_old_small", oneway = 0, dirLanes = 1 }
			list[#list + 1] = { n0 = 15, n1 = 200 + k, x0 = 3000, y0 = 3, z0 = 0, x1 = 3000 + 30 * k, y1 = 60 * k - 200, z1 = 0, tx0 = 1, ty0 = 1, tx1 = 1, ty1 = 1,
				len = 100, w = 12, sp = 11, tmpl = "town_old_small", oneway = 0, dirLanes = 1 }
		end
		local townList = { { name = "Westham", x = 0, y = 0 }, { name = "Eastham", x = 3000, y = 0 } }
		local streets, _, joints = core.group(list)
		local job = core.startLinks(list, townList, names)
		local guard = 0
		while not job.done do job:step(); guard = guard + 1; assert(guard < 50) end
		assert(#job.links >= 1 and job.links[1].kind == "A" and job.links[1].radial, "the two towns are linked by a radial")
		core.name(streets, townList, names, nil, list, joints, job)
		local main
		for _, st in ipairs(streets) do if #st.segs >= 10 then main = st end end
		return main
	end
	local dual, single = build(2), build(1)
	assert(dual.ref ~= nil and dual.ref:match("^A%d$"), "two lanes each way between the towns: a single-digit A road, got " .. tostring(dual.ref))
	assert(single.ref ~= nil and single.ref:match("^A%d%d%d+$"), "one lane each way: an A road of three digits or more, got " .. tostring(single.ref))
	assert(dual.cls == 2 and single.cls == 2, "a road between towns is a main road whatever it was built from")
	assert(dual.name ~= dual.ref and #dual.name >= 2, "and it has a street name as well")
end

-- 7a2. a dual carriageway between two towns built as two one-way roads 100 m apart, with a road to a third
--      town crossing both half-way. Drives between the towns use one carriageway each way and different
--      halves; all of it is one road with one number.
do
	local names = dofile(content .. "/road_names/names.lua")
	local list = {}
	local function seg(n0, x0, y0, n1, x1, y1, oneway, tmpl, lanes)
		list[#list + 1] = { n0 = n0, n1 = n1, x0 = x0, y0 = y0, z0 = 0, x1 = x1, y1 = y1, z1 = 0, tx0 = x1 - x0, ty0 = y1 - y0, tx1 = x1 - x0, ty1 = y1 - y0,
			len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), w = 16, sp = 22, tmpl = tmpl, oneway = oneway, dirLanes = lanes }
	end
	-- eastbound along y = 0 (nodes 1000 + k), westbound along y = 100 (nodes 2000 + k), k = 0..10 every 300 m
	for k = 0, 9 do
		seg(1000 + k, k * 300, 0, 1001 + k, (k + 1) * 300, 0, 1, "country_new_medium_one_way", 2)
		seg(2001 + k, (k + 1) * 300, 100, 2000 + k, k * 300, 100, 1, "country_new_medium_one_way", 2)
	end
	-- the towns' junctions at each end join both carriageways
	seg(1, -100, 50, 1000, 0, 0, 0, "town_old_small", 1); seg(1, -100, 50, 2000, 0, 100, 0, "town_old_small", 1)
	seg(2, 3100, 50, 1010, 3000, 0, 0, "town_old_small", 1); seg(2, 3100, 50, 2010, 3000, 100, 0, "town_old_small", 1)
	-- the crossing road at x = 1500, on to the third town in the north
	seg(1005, 1500, 0, 2005, 1500, 100, 0, "country_old_small", 1)
	for k = 0, 6 do seg(k == 0 and 2005 or 3000 + k, 1500, 100 + k * 200, k == 6 and 3 or 3001 + k, 1500, 300 + k * 200, 0, "country_old_small", 1) end
	-- some road in each town; the western one is the biggest (the hub)
	for k = 1, 8 do seg(1, -100, 50, 100 + k, -100 - 40 * k, 50 + 70 * k - 300, 0, "town_old_small", 1) end
	for k = 1, 4 do seg(2, 3100, 50, 200 + k, 3100 + 40 * k, 50 + 70 * k - 200, 0, "town_old_small", 1) end
	for k = 1, 4 do seg(3, 1500, 1500, 300 + k, 1500 + 70 * k - 200, 1500 + 40 * k, 0, "town_old_small", 1) end
	local townList = { { name = "Westham", x = -100, y = 50 }, { name = "Eastham", x = 3100, y = 50 }, { name = "Northam", x = 1500, y = 1500 } }
	local streets, streetOf, joints = core.group(list)
	local job = core.startLinks(list, townList, names)
	while not job.done do job:step() end
	core.name(streets, townList, names, nil, list, joints, job)
	local refs, count = {}, 0
	for i, sg in ipairs(list) do
		if sg.tmpl == "country_new_medium_one_way" then
			local ref = tostring(streets[streetOf[i]].ref)
			if refs[ref] == nil then refs[ref] = 0; count = count + 1 end
			refs[ref] = refs[ref] + 1
		end
	end
	local seen = {}
	for ref, n in pairs(refs) do seen[#seen + 1] = ref .. " x" .. n end
	table.sort(seen)
	assert(count == 1 and refs["nil"] == nil, "both carriageways carry one number along their whole length, got " .. table.concat(seen, ", "))
	local nameSeen, nameCount = {}, 0
	for i, sg in ipairs(list) do
		if sg.tmpl == "country_new_medium_one_way" then
			local name = streets[streetOf[i]].name
			if not nameSeen[name] then nameSeen[name] = true; nameCount = nameCount + 1 end
		end
	end
	assert(nameCount <= 2, "the carriageways share the road's names (one each side of the crossing at most), got " .. nameCount)
end

-- 7p. postcodes, the British way: a few major towns head an area, every town is a post town with a district
--     of its own, and a spot has the postcode of its nearest post town
do
	local names = dofile(content .. "/road_names/names.lua")
	local townList = { { name = "Lewes", x = 0, y = 0 }, { name = "Leigh-on-Sea", x = 30000, y = 0 }, { name = "Ringmer", x = 3000, y = 0 },
		{ name = "Glynde", x = 0, y = 6000 }, { name = "Benfleet", x = 30000, y = 4000 }, { name = "Barcombe", x = -1500, y = 500 } }
	names.postAreaShare = 0.3   -- two of the six head an area
	local plan = core.postcodePlan(townList, { 50, 40, 5, 4, 3, 2 }, names)
	local outward = {}
	for _, place in ipairs(plan.places) do outward[place.name] = place.outward end
	assert(outward["Lewes"] == "LE1" and outward["Leigh-on-Sea"] == "LI1", "the major towns are district 1 of their areas, with different letters, got "
		.. tostring(outward["Lewes"]) .. " / " .. tostring(outward["Leigh-on-Sea"]))
	assert(outward["Barcombe"] == "LE2" and outward["Ringmer"] == "LE3" and outward["Glynde"] == "LE4",
		"the other towns join the nearest area and are numbered outwards from its main town, got "
		.. tostring(outward["Barcombe"]) .. " " .. tostring(outward["Ringmer"]) .. " " .. tostring(outward["Glynde"]))
	assert(outward["Benfleet"] == "LI2", "a town near the second major town is in its area")
	local centre, out, town = core.postcode(plan, 10, 10)
	assert(centre:match("^LE1 %d%u%u$") and out == "LE1" and town == "Lewes", "a spot in the main town, got " .. centre)
	assert(select(3, core.postcode(plan, 2600, 100)) == "Ringmer" and select(2, core.postcode(plan, 2600, 100)) == "LE3", "a spot has its nearest post town's district")
	assert(core.postcode(plan, 10, 10) == core.postcode(plan, 12, 14), "two spots a few metres apart share a postcode")
	assert(core.postcode(plan, 10, 10) ~= core.postcode(plan, 60, 10), "40 m on, the unit has changed")
	assert(core.postcode(plan, -250000, 180000):match("^%u%u?%d+ %d%u%u$"), "a spot 300 km out still has a well-formed postcode")
	local sectors = {}
	local count = 0
	for kx = -1, 1 do
		for ky = -1, 1 do
			for step = 0, 19 do
				-- around Leigh-on-Sea, which has no other town within reach of these squares
				local code = core.postcode(plan, 30000 + kx * 667 + (step - 9.5) * 33, 4000 * 0 + ky * 667 + (step - 9.5) * 33)
				local sector, unit = code:match("^LI1 (%d)(%u%u)$")
				assert(sector ~= nil and sector ~= "0" and not unit:find("[CIKMOV]"), "sectors are 1 to 9 and unit letters leave out C I K M O V, got " .. code)
				if not sectors[sector] then sectors[sector] = true; count = count + 1 end
			end
		end
	end
	assert(count == 9, "the nine squares round a town are the nine sectors, got " .. count)
	local copy = core.postcodePlanFromText(core.postcodePlanToText(plan))
	assert(copy ~= nil and core.postcode(copy, 3456, -789) == core.postcode(plan, 3456, -789), "the plan gives the same postcodes after being sent as text")
	assert(core.postcode(core.postcodePlan({}, nil, names), 5, 5):match("^TF1 %d%u%u$"), "a map without towns still has postcodes")
	-- every postcode is unique: no two different unit squares anywhere share a code. Checked over 30 km x 14 km
	-- at 151 m steps (well over a unit apart), which takes in both areas and land far from any town.
	local seen, clashes, points = {}, 0, 0
	for ix = 0, 300 do
		for iy = 0, 90 do
			local code = core.postcode(plan, -6000 + ix * 151, -5000 + iy * 151)
			points = points + 1
			if seen[code] then clashes = clashes + 1 end
			seen[code] = true
		end
	end
	assert(clashes == 0, "postcodes are unique: " .. clashes .. " of " .. points .. " sampled spots shared a code with another")
	local _, beyond = core.postcode(plan, 30000, -9000)
	assert(beyond ~= "LI1" and beyond:match("^LI%d+$"), "land beyond a town's nine sectors is a further district of that post town, got " .. beyond)
end

-- 7c. cities: an outline round several towns. The towns stay places in their own right; the city gives them
--     one set of postcodes and its name to the roads that lead to it.
do
	local names = dofile(content .. "/road_names/names.lua")
	local townList = { { name = "Lewes", x = 0, y = 0 }, { name = "Kingston", x = 500, y = 800 }, { name = "Offham", x = 300, y = 3000 },
		{ name = "Cooksbridge", x = -400, y = 2600 }, { name = "Ringmer", x = 2500, y = -1500 }, { name = "Seaford", x = 12000, y = 0 },
		{ name = "Hailsham", x = 0, y = 15000 } }
	local sizes = { 40, 30, 6, 5, 5, 50, 20 }   -- Seaford is the biggest single town
	local cities = { { name = "%s", around = "Lewes", radius = 3500, scheme = "compass" } }
	local resolved, cityOfTown = core.resolveCities(cities, townList, sizes)
	assert(#resolved == 1 and resolved[1].name == "Lewes" and #resolved[1].towns == 5, "the circle takes in the five towns near Lewes")
	assert(cityOfTown[1] == 1 and cityOfTown[5] == 1 and cityOfTown[6] == nil, "towns inside belong to the city, the others do not")
	assert(resolved[1].centre == 1, "the city's centre is its biggest town")
	assert(core.pointInPolygon({ { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } }, 5, 5) and not core.pointInPolygon({ { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } }, 15, 5), "point in outline")
	local drawn = core.resolveCities({ { name = "Docklands", polygon = { { 11000, -1000 }, { 13000, -1000 }, { 13000, 1000 }, { 11000, 1000 } } } }, townList, sizes)
	assert(#drawn == 1 and #drawn[1].towns == 1 and drawn[1].scheme == "grid", "a drawn outline takes in the town inside it")

	-- postcodes the London way: the code is the direction from the centre, 1 is the head district (the town
	-- nearest the centre in that direction), and the rest follow alphabetically, not by distance
	names.postAreaShare = 1
	local plan = core.postcodePlan(townList, sizes, names, cities)
	local outward = {}
	for _, place in ipairs(plan.places) do outward[place.name] = place.outward end
	assert(outward["Lewes"] == "EC1", "the centre town is EC1, got " .. tostring(outward["Lewes"]))
	assert(outward["Kingston"] == "EC2", "another town in the middle is the next EC district, got " .. tostring(outward["Kingston"]))
	assert(outward["Cooksbridge"] == "N1" and outward["Offham"] == "N2",
		"north: the nearer town is the head district N1, the other N2, got " .. tostring(outward["Cooksbridge"]) .. " / " .. tostring(outward["Offham"]))
	assert(outward["Ringmer"] == "SE1", "the town to the south-east is SE1, got " .. tostring(outward["Ringmer"]))
	assert(outward["Seaford"]:match("^S[A-Z]?1$") and not outward["Seaford"]:match("^S[EW]1$"),
		"a town outside the city heads an ordinary area, and never takes a compass code, got " .. outward["Seaford"])
	local spot, district, town = core.postcode(plan, 250, 2900)
	assert(district == "N2" and town == "Offham" and spot:match("^N2 %d%u%u$"), "a spot in the city has its nearest city town's district, got " .. spot)
	assert(select(2, core.postcode(plan, 3400, 0)) ~= outward["Seaford"], "inside the outline a spot stays with the city's towns even near the edge")
	assert(select(3, core.postcode(plan, 9000, 0)) == "Seaford" and select(2, core.postcode(plan, 11800, 100)) == outward["Seaford"],
		"outside it the nearest town outside the city counts")
	local copy = core.postcodePlanFromText(core.postcodePlanToText(plan))
	assert(copy ~= nil and core.postcode(copy, 250, 2900) == core.postcode(plan, 250, 2900) and core.postcode(copy, 12000, 10) == core.postcode(plan, 12000, 10),
		"a plan with a city gives the same postcodes after being sent as text")
	-- alphabetical, not by distance: with three towns to the north the two beyond the head district go by name
	local three = { { name = "Mid", x = 0, y = 0 }, { name = "Near", x = 0, y = 2000 }, { name = "Zeal", x = 100, y = 2600 }, { name = "Abbey", x = -100, y = 3300 } }
	local planThree = core.postcodePlan(three, { 9, 1, 1, 1 }, names, { { name = "%s", around = "Mid", radius = 4000, scheme = "compass" } })
	local byName = {}
	for _, place in ipairs(planThree.places) do byName[place.name] = place.outward end
	assert(byName["Near"] == "N1" and byName["Abbey"] == "N2" and byName["Zeal"] == "N3",
		"after the head district, districts are alphabetical: Abbey is N2 although it is furthest out, got " .. byName["Abbey"] .. " / " .. byName["Zeal"])

	-- one set of London postcodes per map: a second city that asks for them gets an ordinary area instead
	local two = core.postcodePlan(townList, sizes, names, { cities[1], { name = "Seaford City", around = "Seaford", radius = 2000, scheme = "compass" } })
	local outwards, shared = {}, false
	for _, place in ipairs(two.places) do
		if outwards[place.outward] then shared = true end
		outwards[place.outward] = true
	end
	assert(#two.demoted == 1 and two.demoted[1] == "Seaford City", "the second compass city is reported")
	assert(not shared, "no two post towns share a district code")
	for _, place in ipairs(two.places) do
		if place.name == "Seaford" then assert(place.outward:match("^S[A-Z]?1$") and place.outward ~= "SE1" and place.outward ~= "SW1", "the second city has its own area letters, got " .. place.outward) end
	end

	-- roads: the city's towns stay destinations; the city as a whole decides the hub
	local list = {}
	local function road(n0, x0, y0, n1, x1, y1)
		list[#list + 1] = { n0 = n0, n1 = n1, x0 = x0, y0 = y0, z0 = 0, x1 = x1, y1 = y1, z1 = 0, tx0 = x1 - x0, ty0 = y1 - y0, tx1 = x1 - x0, ty1 = y1 - y0,
			len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), w = 14, sp = 22, tmpl = "country_old_small", oneway = 0, dirLanes = 1 }
	end
	road(1, 0, 0, 2, 500, 800); road(2, 500, 800, 3, 2500, -1500); road(3, 2500, -1500, 9, 6000, 3000); road(9, 6000, 3000, 4, 12000, 0)
	road(1, 0, 0, 8, 0, 7000); road(8, 0, 7000, 5, 0, 15000)
	local roadTowns = { townList[1], townList[2], townList[5], townList[6], townList[7] }
	local job = core.startLinks(list, roadTowns, names, cities)
	while not job.done do job:step() end
	assert(job.hubTown == 1, "the city's centre is the hub: together its towns have more road than Seaford")
	assert(job.primary[1] and job.primary[2] and job.primary[4], "towns inside a city stay destinations in their own right")
	assert(job.cityOfTown[2] == 1 and #job.cities == 1, "the job carries the cities for the naming")
	local streets, _, joints = core.group(list)
	core.name(streets, roadTowns, names, nil, list, joints, job)
	local found, all = false, {}
	for _, st in ipairs(streets) do
		all[#all + 1] = st.name
		if st.name == "Lewes Road" then found = true end
	end
	assert(found, "a road leading to the city from outside is named after the city, plainly: got " .. table.concat(all, "; "))
	local plain, named = 0, 0
	for _, st in ipairs(streets) do
		if st.name == "High Street" then plain = plain + 1 end
		if st.name:match(" High Street$") then named = named + 1 end
	end
	assert(plain <= 1, "at most one road on the map is plain High Street, got " .. plain)
	local seenNames = {}
	for _, st in ipairs(streets) do
		assert(st.partOf ~= nil or not seenNames[st.name], "the name '" .. st.name .. "' is used for two roads")
		seenNames[st.name] = true
	end
end

-- 7d. road numbers the British way: lower numbers nearer the hub; a short motorway off a long one takes a
--     number derived from it
do
	local names = dofile(content .. "/road_names/names.lua")
	local list = {}
	local function piece(n0, x0, y0, n1, x1, y1, tmpl, sp, lanes)
		list[#list + 1] = { n0 = n0, n1 = n1, x0 = x0, y0 = y0, z0 = 0, x1 = x1, y1 = y1, z1 = 0, tx0 = x1 - x0, ty0 = y1 - y0, tx1 = x1 - x0, ty1 = y1 - y0,
			len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), w = 12, sp = sp, tmpl = tmpl, oneway = 0, dirLanes = lanes }
	end
	-- two lone country roads due north-north-east of the only town, the far one listed first
	for k = 0, 9 do piece(900 + k, 1000 + k * 200, 9000 + (k % 2) * 4, 901 + k, 1200 + k * 200, 9000 + ((k + 1) % 2) * 4, "country_old_small", 16, 1) end
	for k = 0, 9 do piece(800 + k, 1000 + k * 200, 3000 + (k % 2) * 4, 801 + k, 1200 + k * 200, 3000 + ((k + 1) % 2) * 4, "country_old_small", 16, 1) end
	-- a motorway 8 km long running east-west to the south, and a 2 km motorway branching off its middle
	for k = 0, 15 do piece(100 + k, -4000 + k * 500, -5000, 101 + k, -3500 + k * 500, -5000, "::/infrastructure/street/highway/highway_new_large.street_template", 33, 2) end
	for k = 0, 3 do piece(k == 0 and 108 or 200 + k, 0 + k * 300, -5000 - k * 400, 201 + k, 300 + k * 300, -5400 - k * 400, "::/infrastructure/street/highway/highway_new_large.street_template", 33, 2) end
	local townList = { { name = "Onlytown", x = 0, y = 0 } }
	local streets, streetOf, joints = core.group(list)
	core.name(streets, townList, names, nil, list, joints, nil)
	local far, near, main, spur = streets[streetOf[1]], streets[streetOf[11]], streets[streetOf[21]], streets[streetOf[#list]]
	assert(near.ref ~= nil and far.ref ~= nil and near.ref:match("^B%d%d%d%d$") and far.ref:match("^B%d%d%d%d$"), "both lone roads are B roads")
	assert(near.ref:sub(1, 2) == far.ref:sub(1, 2) and tonumber(near.ref:sub(2)) < tonumber(far.ref:sub(2)),
		"in one zone the road nearer the hub has the lower number, got " .. near.ref .. " (near) and " .. far.ref .. " (far)")
	assert(main.ref ~= nil and main.ref:match("^M%d$"), "the long motorway has a number of its own, got " .. tostring(main.ref))
	assert(spur ~= main and spur.ref == main.ref .. "1", "the short motorway off it takes a derived number, got " .. tostring(spur.ref) .. " off " .. tostring(main.ref))
	for _, st in ipairs(streets) do assert(st.ref == nil or not st.ref:find("~", 1, true), "no stand-in number is left: " .. tostring(st.ref)) end
	-- where the motorway ends it ends: a dirt road running straight on from its east end, with a side road at
	-- the same point, is not the motorway
	do
		local list2 = {}
		for i, sg in ipairs(list) do list2[i] = sg end
		local function extra(n0, x0, y0, n1, x1, y1)
			list2[#list2 + 1] = { n0 = n0, n1 = n1, x0 = x0, y0 = y0, z0 = 0, x1 = x1, y1 = y1, z1 = 0, tx0 = x1 - x0, ty0 = y1 - y0, tx1 = x1 - x0, ty1 = y1 - y0,
				len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), w = 8, sp = 11, tmpl = "::/infrastructure/street/country/country_old_small.street_template", oneway = 0, dirLanes = 1 }
		end
		extra(116, 4000, -5000, 300, 4600, -5000); extra(300, 4600, -5000, 301, 5200, -5010)   -- straight on, dirt
		extra(116, 4000, -5000, 302, 4000, -5600)                                              -- a side road
		-- two ordinary roads meeting the motorway part-way along: junctions
		extra(104, -2000, -5000, 310, -2000, -4400); extra(112, 2000, -5000, 311, 2000, -4400)
		local streets3, streetOf3, joints3 = core.group(list2)
		core.name(streets3, townList, names, nil, list2, joints3, nil)
		local dirt, motorway = streets3[streetOf3[#list + 1]], streets3[streetOf3[21]]
		assert(dirt ~= motorway, "a road running straight on from the end of a motorway is a street of its own")
		assert(dirt.ref == nil or not dirt.ref:match("^M"), "and has no motorway number, got " .. tostring(dirt.ref))
		assert(#dirt.name >= 2 and dirt.name ~= motorway.ref, "it is named like any other road, got '" .. tostring(dirt.name) .. "'")
		-- a slip road ending at a roundabout: the roundabout belongs to the ordinary road through it, not to
		-- the motorway
		do
			local list4 = {}
			for i, sg in ipairs(list) do list4[i] = sg end
			local function add(n0, x0, y0, n1, x1, y1, tmpl, oneway, sp)
				list4[#list4 + 1] = { n0 = n0, n1 = n1, x0 = x0, y0 = y0, z0 = 0, x1 = x1, y1 = y1, z1 = 0, tx0 = x1 - x0, ty0 = y1 - y0, tx1 = x1 - x0, ty1 = y1 - y0,
					len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), w = 10, sp = sp, tmpl = tmpl, oneway = oneway, dirLanes = 2 }
			end
			local cx, cy = -2000, -4300
			for k = 0, 7 do
				local a0, a1 = k * math.pi / 4, (k + 1) * math.pi / 4
				add(700 + k, cx + 30 * math.cos(a0), cy + 30 * math.sin(a0), 700 + (k + 1) % 8, cx + 30 * math.cos(a1), cy + 30 * math.sin(a1), "country_new_small", 1, 14)
			end
			-- the slip road up from the motorway to the ring's south side, and an ordinary road east and west
			add(104, -2000, -5000, 706, cx + 30 * math.cos(6 * math.pi / 4), cy + 30 * math.sin(6 * math.pi / 4), "::/infrastructure/street/highway/highway_new_small.street_template", 0, 30)
			add(700, cx + 30, cy, 720, cx + 700, cy, "country_new_small", 0, 14); add(704, cx - 30, cy, 721, cx - 700, cy, "country_new_small", 0, 14)
			local streets4, streetOf4, joints4 = core.group(list4)
			core.name(streets4, townList, names, nil, list4, joints4, nil)
			local ring = streets4[streetOf4[#list + 1]]
			assert(ring.roundabout and (ring.ref == nil or not ring.ref:match("^M")), "a roundabout at the end of a slip road has no motorway number, got " .. tostring(ring.ref))
		end
		-- junction numbers: counted along the motorway from the end nearer the hub, one per interchange
		local junctions = core.junctions(streets3, list2, { x = -9000, y = -5000 }, names)
		local own = {}
		for _, j in ipairs(junctions) do
			if j.ref == motorway.ref then own[#own + 1] = j end
		end
		assert(#own >= 3, "the motorway's junctions are found, got " .. #own)
		for k, j in ipairs(own) do
			assert(j.number == k, "junctions are numbered 1 upwards")
			if k > 1 then assert(j.x > own[k - 1].x, "in order along the motorway from the hub end (west here)") end
		end
		assert(math.abs(own[1].x - -2000) < 1 and own[1].number == 1, "the first junction from the west is where the first road joins, got x " .. own[1].x)
		assert(own[1].of == #own and #own[1].connects >= 1 and own[1].toPrevious == nil and own[1].toNext ~= nil and math.abs(own[1].toNext - 2000) < 5,
			"a junction knows what it connects and how far the next one is, got " .. tostring(own[1].toNext))
		for _, road in ipairs(own[1].connects) do assert(road ~= motorway.ref and #road >= 2, "the roads it connects are named: " .. road) end
		local fromEast = core.junctions(streets3, list2, { x = 9000, y = -5000 }, names)
		local firstEast
		for _, j in ipairs(fromEast) do
			if j.ref == motorway.ref and j.number == 1 then firstEast = j end
		end
		assert(firstEast and firstEast.x > 3000, "with the hub at the other end the numbering starts there")
	end
	-- what a road can carry: two lanes each way at 33 m/s
	local stats = core.streetStats(main, list)
	assert(stats and stats.lanes == 2 and not stats.oneWay and stats.perDirection > 3500 and stats.perDirection < 4500 and stats.total == 2 * stats.perDirection,
		"theoretical throughput from lanes and speed, got " .. tostring(stats and stats.perDirection))
	assert(core.streetStats({ segs = { 1 } }, { { x0 = 0, y0 = 0, x1 = 10, y1 = 0, len = 10, sp = 10 } }) == nil, "no figure without a lane count")
	-- the road a station stands on is Station Road; a second one carries its town's name
	local streets2, streetOf2, joints2 = core.group(list)
	streets2[streetOf2[1]].station, streets2[streetOf2[11]].station = true, true
	core.name(streets2, townList, names, nil, list, joints2, nil)
	local stationNames = { streets2[streetOf2[1]].name, streets2[streetOf2[11]].name }
	table.sort(stationNames)
	assert(stationNames[1] == "Onlytown Station Road" and stationNames[2] == "Station Road",
		"station roads: one plain, the other with its town's name, got " .. stationNames[1] .. " / " .. stationNames[2])
end

-- 7e. roads named for what they do: a bypass, a ring road, a link road
do
	local names = dofile(content .. "/road_names/names.lua")
	local function build(arcDegrees)
		local list = {}
		local function piece(n0, x0, y0, n1, x1, y1, tmpl)
			list[#list + 1] = { n0 = n0, n1 = n1, x0 = x0, y0 = y0, z0 = 0, x1 = x1, y1 = y1, z1 = 0, tx0 = x1 - x0, ty0 = y1 - y0, tx1 = x1 - x0, ty1 = y1 - y0,
				len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), w = 14, sp = 22, tmpl = tmpl, oneway = 0, dirLanes = 1 }
		end
		-- a wide road on an arc of 900 m radius round the town at the origin, in 15 degree pieces
		local steps = arcDegrees / 15
		for k = 0, steps - 1 do
			local a0, a1 = math.rad(k * 15), math.rad((k + 1) * 15)
			piece(k, 900 * math.cos(a0), 900 * math.sin(a0), (arcDegrees == 360 and k == steps - 1) and 0 or k + 1, 900 * math.cos(a1), 900 * math.sin(a1), "country_new_medium")
		end
		-- the town's own streets, and a second town so that there is somewhere to go
		for k = 1, 5 do piece(500 + k, -100 + k * 40, -150, 600 + k, -100 + k * 40, 150, "town_old_small") end
		local streets, streetOf, joints = core.group(list)
		core.name(streets, { { name = "Wickham", x = 0, y = 0 }, { name = "Farside", x = 20000, y = 0 } }, names, nil, list, joints, nil)
		return streets[streetOf[1]]
	end
	local bypass, ring = build(150), build(360)
	assert(bypass.ref ~= nil and bypass.name == "Wickham Bypass", "a numbered road round part of a town is its bypass, got " .. tostring(bypass.name))
	assert(ring.name == "Wickham Ring Road", "one that goes all the way round is its ring road, got " .. tostring(ring.name))
end

-- 7b. road classes from the game's real template names (widths include pavements, so names come first)
local function cls(tmpl, w, sp) return core.classOf({ tmpl = tmpl, w = w, sp = sp }) end
assert(cls("::/infrastructure/street/town/town_old_small.street_template", 16, 11.1) == 1, "a small town street is an ordinary street")
assert(cls("::/infrastructure/street/country/country_new_small.street_template", 14, 22.2) == 1)
assert(cls("::/infrastructure/street/town/town_new_medium.street_template", 24, 13.9) == 2)
assert(cls("::/infrastructure/street/town/town_new_large.street_template", 32, 16.7) == 2)
assert(cls("yoshi_road_plus::/infrastructure/street/country/country_new_five_lane_asymmetric.street_template", 26, 22.2) == 2)
assert(cls("::/infrastructure/street/highway/highway_new_small.street_template", 9, 27.8) == 3)
assert(cls("some_mod::/roads/unnamed.street_template", 30, 14) == 2 and cls("some_mod::/roads/unnamed.street_template", 12, 14) == 1)

-- 8. with the native bridge present the export goes out as JSON through tf3api.writeFile
local bridgeFile, bridgeText, labelText
local messages = {}
tf3api = { version = 1, log = function() return true end,
	writeFile = function(name, text) bridgeFile, bridgeText = name, text; return true end,
	setRoadLabels = function(text) labelText = text; return 1 end,
	post = function(channel, text) messages[#messages + 1] = { channel, text }; return true end,
	take = function(channel)
		for i, m in ipairs(messages) do
			if m[1] == channel then table.remove(messages, i); return m[2] end
		end
		return false
	end }
saved = nil; now = 0
M = dofile(content .. "/road_names/road_names.script.lua")
for frame = 1, 400 do now = now + 0.02; M.guiUpdate() end
assert(bridgeFile == "road_export.json" and type(bridgeText) == "string", "export written through the bridge")
assert(saved == nil, "the userdata fallback is not used when the bridge wrote the file")
assert(bridgeText:sub(1, 1) == "{" and bridgeText:find('"streets":[[', 1, true) and bridgeText:find('"name":"Testville"', 1, true), "JSON shape")
if arg[2] then
	local jf = assert(io.open(arg[2] .. ".json", "w"))
	jf:write(bridgeText)
	jf:close()
end
-- 9. the roads to draw in the world go to the native side: motorway with its sign and no separate name,
--    the A road with sign and name, and segments with heights
assert(type(labelText) == "string", "labels handed to the native layer")
assert(labelText:find("S\tM\t3\tM2\t\t%d+\t\t[^\t\n]*\n"), "motorway label: blue sign, number only, with the road's id")
assert(labelText:find("S\tA\t2\tA2\t", 1, true), "A road label: green sign with its name")
assert(labelText:find("\nG %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+"), "segment rows")
assert(not labelText:find("\t\t\t%d+\t[ia]*\t[^\t\n]*\n"), "no road is sent without a number or a name")
-- 9b. abandoning a road. One that is cut off from the main network (the lone country road) can be marked
--     abandoned through a message from the road window: it then has a grey "Abandoned" badge in place of its
--     number and keeps its name. One that is still joined on (the first motorway) cannot.
do
	local function labelOf(pattern)
		for line in labelText:gmatch("[^\n]+") do
			local short = line:gsub("\t[^\t]*$", "")
			if line:sub(1, 2) == "S\t" and short:find(pattern) then return short end
		end
	end
	-- the naming script has sent the postcode plan for the road window, and sends it again when asked
	local function planMessages()
		local n = 0
		for _, m in ipairs(messages) do
			if m[1] == "tf3api_road_names.ui" and m[2]:match("^postcodes\t%d+;%u") then n = n + 1 end
		end
		return n
	end
	assert(planMessages() >= 1, "the postcode plan is sent to the road window")
	local junctionLine, junctionMessage
	for line in labelText:gmatch("[^\n]+") do
		if line:match("^S\tJ\t3\t%d+\t\t%d+\tJ\t") then junctionLine = line end
	end
	for _, m in ipairs(messages) do
		if m[1] == "tf3api_road_names.ui" and m[2]:match("^junctions\t[AM]%d+|%d+|%d+|") then junctionMessage = m[2] end
	end
	assert(junctionLine and junctionMessage, "junction numbers are drawn as clickable badges and their details are sent to the window: line " .. tostring(junctionLine) .. " / message " .. tostring(junctionMessage and junctionMessage:sub(1, 60)))
	local before = planMessages()
	tf3api.post("tf3api_road_names", "hello")
	for frame = 1, 5 do now = now + 0.02; M.guiUpdate() end
	assert(planMessages() == before + 1, "and again when the window asks for it")
	local lone = labelOf("\tB%d%d%d%d\t[^\t]+\t%d+\ti$")
	assert(lone, "the cut-off country road is flagged as isolated")
	local loneId, loneName = lone:match("\t(%d+)\ti$"), lone:match("^S\t[^\t]*\t[^\t]*\t[^\t]*\t([^\t]*)\t")
	local joined = labelOf("^S\tM\t3\tM2\t\t%d+\t$")
	assert(joined, "the motorway joined to the town is not flagged")
	local joinedId = joined:match("\t(%d+)\t$")
	tf3api.post("tf3api_road_names", "abandon\t" .. loneId .. "\t1")
	tf3api.post("tf3api_road_names", "abandon\t" .. joinedId .. "\t1")
	for frame = 1, 30 do now = now + 0.02; M.guiUpdate() end
	local after = labelOf("\t" .. loneId .. "\tia$")
	assert(after and after:find("^S\tX\t%d\tAbandoned\t") and after:find("\t" .. loneName .. "\t", 1, true),
		"an abandoned road shows the Abandoned badge and keeps its name, got " .. tostring(after))
	assert(labelOf("^S\tM\t3\tM2\t\t" .. joinedId .. "\t$"), "a road still joined to the network is not abandoned")
	tf3api.post("tf3api_road_names", "abandon\t" .. loneId .. "\t0")
	for frame = 1, 30 do now = now + 0.02; M.guiUpdate() end
	assert(labelOf("\tB%d%d%d%d\t[^\t]+\t" .. loneId .. "\ti$"), "un-abandoned, it is a B road again")
end
-- 9c. what the player sets in the road window: the name, the road type, what the label shows, and the map page
do
	local function labelOfId(id)
		for line in labelText:gmatch("[^\n]+") do
			if line:sub(1, 2) == "S\t" and line:match("^S\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t(%d+)") == tostring(id) then return (line:gsub("\t[^\t]*$", "")) end
		end
	end
	local function field(line, n)
		local k = 0
		for value in (line .. "\t"):gmatch("([^\t]*)\t") do
			k = k + 1
			if k == n then return value end
		end
	end
	local function send(text)
		tf3api.post("tf3api_road_names", text)
		for frame = 1, 30 do now = now + 0.02; M.guiUpdate() end
	end
	local function notices()
		local list = {}
		for _, m in ipairs(messages) do
			if m[1] == "tf3api_road_names.ui" and m[2]:match("^notice\t") then list[#list + 1] = m[2] end
		end
		return list
	end
	-- two ordinary named roads to work on
	local first, second
	for line in labelText:gmatch("[^\n]+") do
		local short = line:gsub("\t[^\t]*$", "")
		if short:match("^S\t%-\t1\t\t[^\t]+\t%d+\t$") then
			if first == nil then first = short elseif second == nil then second = short end
		end
	end
	assert(first and second, "two ordinary roads to edit")
	local id1, id2 = field(first, 6), field(second, 6)
	local name2 = field(second, 5)
	-- rename
	send("rename\t" .. id1 .. "\t  Savage Row  ")
	assert(field(labelOfId(id1), 5) == "Savage Row", "the road carries the name the player typed, got " .. tostring(labelOfId(id1)))
	local before = #notices()
	send("rename\t" .. id2 .. "\tsavage row")
	assert(field(labelOfId(id2), 5) == name2 and #notices() == before + 1, "a name another road has is refused, and the player is told")
	send("rename\t" .. id1 .. "\t")
	assert(field(labelOfId(id1), 5) ~= "Savage Row" and #field(labelOfId(id1), 5) >= 2, "an empty name gives the automatic name back")
	-- road type
	send("type\t" .. id1 .. "\tA")
	assert(field(labelOfId(id1), 4):match("^A%d+$") and field(labelOfId(id1), 5) ~= "" and field(labelOfId(id1), 7):find("TA", 1, true),
		"chosen as an A road: an A number, still a name, and the choice comes back in the flags, got " .. tostring(labelOfId(id1)))
	send("type\t" .. id1 .. "\tM")
	assert(field(labelOfId(id1), 2) == "M" and field(labelOfId(id1), 4):match("^M%d+$") and field(labelOfId(id1), 5) == "",
		"chosen as a motorway: a blue sign with an M number and no separate name, got " .. tostring(labelOfId(id1)))
	send("type\t" .. id1 .. "\tAM")
	assert(field(labelOfId(id1), 4):match("^A%d+%(M%)$") and field(labelOfId(id1), 7):find("TX", 1, true), "chosen as A(M), got " .. tostring(labelOfId(id1)))
	send("type\t" .. id1 .. "\tB")
	assert(field(labelOfId(id1), 4):match("^B%d+$"), "chosen as a B road, got " .. tostring(labelOfId(id1)))
	send("type\t" .. id1 .. "\tN")
	assert(field(labelOfId(id1), 4) == "" and field(labelOfId(id1), 5) ~= "", "chosen as an ordinary road: no number, a name")
	-- no number is on two roads after all that
	local refs = {}
	for line in labelText:gmatch("[^\n]+") do
		if line:sub(1, 2) == "S\t" and field(line, 4) ~= "" and field(line, 4) ~= "Abandoned" then refs[field(line, 4)] = (refs[field(line, 4)] or 0) + 1 end
	end
	-- label style
	send("type\t" .. id1 .. "\tB")
	send("style\t" .. id1 .. "\tnumber")
	assert(field(labelOfId(id1), 4):match("^B%d+$") and field(labelOfId(id1), 5) == "" and field(labelOfId(id1), 7):find("Sn", 1, true), "number only")
	send("style\t" .. id1 .. "\tname")
	assert(field(labelOfId(id1), 4) == "" and field(labelOfId(id1), 2) == "-" and field(labelOfId(id1), 5) ~= "", "name only")
	send("style\t" .. id1 .. "\tauto")
	assert(field(labelOfId(id1), 4):match("^B%d+$") and field(labelOfId(id1), 5) ~= "", "back to number and name")
	send("type\t" .. id1 .. "\tauto")
	assert(field(labelOfId(id1), 4) == "" and field(labelOfId(id1), 7) == "", "back to the automatic type")
	-- the map page
	bridgeFile, bridgeText = nil, nil
	send("export")
	assert(bridgeFile == "road_map.html" and bridgeText:find("<!doctype html>", 1, true) and bridgeText:find('"streets":[[', 1, true)
		and not bridgeText:find("__DATA__", 1, true) and not bridgeText:find("__TITLE__", 1, true), "the street map page is written from the game")
	-- the checks further down compare against the map as it is now: take a fresh export (without the bridge's
	-- file writer the script falls back to the game's own, which the test can read)
	tf3api.writeFile = nil
	saved = nil
	send("style	" .. id1 .. "	auto")
	assert(saved ~= nil, "a fresh export after the edits")
	t = saved.t
end
tf3api = nil
saved = { t = t }

-- optional: write the export the way the game does (function data() return {...} end) for tools/road_map.py
if arg[2] then
	local function ser(v, indent)
		if type(v) == "table" then
			local parts = {}
			local n = #v
			for i = 1, n do parts[#parts + 1] = indent .. "	" .. ser(v[i], indent .. "	") .. "," end
			for k, x in pairs(v) do
				if not (type(k) == "number" and k >= 1 and k <= n) then
					parts[#parts + 1] = indent .. "	" .. tostring(k) .. " = " .. ser(x, indent .. "	") .. ","
				end
			end
			return "{ \n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
		elseif type(v) == "string" then
			return string.format("%q", v)
		end
		return tostring(v)
	end
	local f = assert(io.open(arg[2], "w"))
	f:write("function data()\nreturn " .. ser(saved.t, "") .. "\nend\n")
	f:close()
end

-- 10. a road is demolished after the names are up: the change is noticed and the network is read again
do
	local before = #edges
	local namesBefore = {}
	for i = 1, before - 1 do
		local st = t.streets[t.segments[i][1]]
		namesBefore[i] = st[1] .. "|" .. tostring(st[7])
	end
	table.remove(edges)
	saved = nil
	for frame = 1, 900 do now = now + 0.02; M.guiUpdate() end
	assert(saved ~= nil and #saved.t.segments == before - 1, "the road network is read again after a change")
	for i = 1, before - 1 do
		local st = saved.t.streets[saved.t.segments[i][1]]
		assert(st[1] .. "|" .. tostring(st[7]) == namesBefore[i], "roads keep their names and numbers when the network is read again: segment " .. i
			.. " was " .. namesBefore[i] .. ", now " .. st[1] .. "|" .. tostring(st[7]))
	end
	saved = nil
	for frame = 1, 900 do now = now + 0.02; M.guiUpdate() end
	assert(saved == nil, "nothing is read again while the network stays the same")
end

-- 9d. saved with the game: after an edit the interface side sends the names and choices to the simulation side;
--     that stores them in the game script's state; after a "load" a new interface state reads them back, so
--     the renamed road has its name before anything else happens
do
	local sent = {}
	api.cmd = { sendCommand = function(command) sent[#sent + 1] = command end,
		makeScriptingSendEventCmd = function(src, id, name, param) return { src = src, id = id, name = name, param = param } end }
	local messagesSeen, labels = {}, nil
	tf3api = { version = 5, log = function() return true end, writeFile = function() return true end,
		setRoadLabels = function(text) labels = text; return 1 end,
		post = function(channel, text) messagesSeen[#messagesSeen + 1] = { channel, text }; return true end,
		take = function(channel)
			for i, m in ipairs(messagesSeen) do
				if m[1] == channel then table.remove(messagesSeen, i); return m[2] end
			end
			return false
		end }
	-- a fresh game: names read once, then one road renamed and made a B road
	saved = nil; now = 0
	M = dofile(content .. "/road_names/road_names.script.lua")
	for frame = 1, 400 do now = now + 0.02; M.guiUpdate(nil, { get = function() return nil end }, nil) end
	local target
	for line in labels:gmatch("[^\n]+") do
		if target == nil and line:match("^S\t%-\t1\t\t[^\t]+\t%d+\t\t") then target = line:match("^S\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t(%d+)") end
	end
	assert(target, "a road to rename")
	tf3api.post("tf3api_road_names", "rename\t" .. target .. "\tKeepsake Lane")
	for frame = 1, 30 do now = now + 0.02; M.guiUpdate(nil, { get = function() return nil end }, nil) end
	tf3api.post("tf3api_road_names", "type\t" .. target .. "\tB")
	for frame = 1, 30 do now = now + 0.02; M.guiUpdate(nil, { get = function() return nil end }, nil) end
	assert(#sent >= 1 and sent[#sent].id == "tf3api_road_names" and sent[#sent].name == "setChoices" and type(sent[#sent].param.text) == "string",
		"the names and choices are sent to the simulation side")
	-- the simulation side stores what it is sent, and subscribes to the event first
	local stored, subscribed = nil, {}
	local state = { hasEventSubscriptions = function() return next(subscribed) ~= nil end, subscribeToEvent = function(_, name) subscribed[name] = true end,
		set = function(_, value) stored = value end, get = function() return stored end }
	M.update(nil, state, 0.1)
	assert(subscribed["setChoices"], "the simulation side subscribes to its event")
	M.handleEvent(nil, state, "", "SomeoneElse", "setChoices", { text = "nonsense" })
	assert(stored == nil, "events for other scripts are ignored")
	M.handleEvent(nil, state, "", sent[#sent].id, sent[#sent].name, sent[#sent].param)
	assert(type(stored) == "table" and stored.text:find("n\t[^\t]+\tKeepsake Lane") and stored.text:find("\nt\t[^\t]+\tB"), "the choices are in the saved state")
	-- load: a new interface state, given that saved state
	labels = nil; now = 0
	local reloaded = dofile(content .. "/road_names/road_names.script.lua")
	for frame = 1, 400 do now = now + 0.02; reloaded.guiUpdate(nil, state, nil) end
	local found
	for line in labels:gmatch("[^\n]+") do
		if line:find("\tKeepsake Lane\t", 1, true) then found = line end
	end
	assert(found and found:match("^S\tB\t%d\tB%d+\tKeepsake Lane\t%d+\tTB\t"), "after loading, the road has the player's name and type again, got " .. tostring(found))
	tf3api = nil
	M = reloaded
end

-- 10b. a city arrives as a message (as the drawing tool will send it): the links are worked out again and the
--      postcode plan sent to the road window has the city in it
do
	local messagesSeen = {}
	tf3api = { version = 5, log = function() return true end, writeFile = function() return true end, setRoadLabels = function() return 1 end,
		post = function(channel, text) messagesSeen[#messagesSeen + 1] = { channel, text }; return true end,
		take = function(channel)
			for i, m in ipairs(messagesSeen) do
				if m[1] == channel then table.remove(messagesSeen, i); return m[2] end
			end
			return false
		end }
	tf3api.post("tf3api_road_names", "city\tTestville City\tcompass\t-500 -500 1000 -500 1000 1000 -500 1000")
	for frame = 1, 900 do now = now + 0.02; M.guiUpdate() end
	local plan
	for _, m in ipairs(messagesSeen) do
		if m[1] == "tf3api_road_names.ui" and m[2]:sub(1, 9) == "postcodes" then plan = m[2] end
	end
	assert(plan and plan:find("@Testville City|", 1, true), "the plan sent to the window carries the city, got " .. tostring(plan))
	tf3api.post("tf3api_road_names", "city-remove\tTestville City")
	do local pendingOnly = {} for _, m in ipairs(messagesSeen) do if m[1] == "tf3api_road_names" then pendingOnly[#pendingOnly + 1] = m end end messagesSeen = pendingOnly end
	for frame = 1, 900 do now = now + 0.02; M.guiUpdate() end
	local after
	for _, m in ipairs(messagesSeen) do
		if m[1] == "tf3api_road_names.ui" and m[2]:sub(1, 9) == "postcodes" then after = m[2] end
	end
	assert(after and not after:find("Testville City", 1, true), "removed, the city is gone from the plan")
	tf3api = nil
end

-- 11. with the development switch on, a re-read remembers nothing: the log says so and no road is reported kept
do
	ignoreSavedData = true
	saved = nil; now = 0
	local firstLog = #logs + 1
	M = dofile(content .. "/road_names/road_names.script.lua")
	for frame = 1, 400 do now = now + 0.02; M.guiUpdate() end
	table.remove(edges)
	for frame = 1, 900 do now = now + 0.02; M.guiUpdate() end
	local announced, kept = false, false
	for i = firstLog, #logs do
		if logs[i]:find("ignoreSavedData is ON", 1, true) then announced = true end
		if logs[i]:find("kept their names", 1, true) then kept = true end
	end
	assert(announced and not kept, "ignoreSavedData: names are worked out from scratch on every read")
	ignoreSavedData = false
end

-- 12. spread over frames: with a clock that really runs, the naming is done a slice at a time over many frames,
--     and the result is exactly what one uninterrupted pass gives
do
	local function run(tick)
		saved = nil; now = 0
		os.clock = function() now = now + tick; return now end
		local instance = dofile(content .. "/road_names/road_names.script.lua")
		local frames = 0
		while saved == nil and frames < 200000 do
			now = now + 0.016
			instance.guiUpdate(nil, { get = function() return nil end }, nil)
			frames = frames + 1
		end
		assert(saved ~= nil, "the naming finishes")
		local rows = {}
		for i, st in ipairs(saved.t.streets) do rows[i] = st[1] .. "|" .. tostring(st[7]) .. "|" .. tostring(st[2]) end
		return table.concat(rows, ";"), frames
	end
	local straight, framesStraight = run(0)
	local slicedResult = run(0.004)
	os.clock = function() return now end
	assert(slicedResult == straight, "sliced naming gives the same names and numbers as one pass")
	local announced = false
	for _, l in ipairs(logs) do if l:find("naming spread over", 1, true) then announced = true end end
	assert(announced, "the work really was done over several frames, and the log says how it was spread")
end

-- 13. Station Road is the road by a RAILWAY station: a bus station beside another road does not make one
do
	api.type.ComponentType.STATION_GROUP = 6
	api.type.enum.Carrier = { RAIL = "RAIL", ROAD = "ROAD", AIR = "AIR" }
	local oldEntities, oldComponent = api.engine.getEntitiesWithComponent, api.engine.getComponent
	api.engine.getEntitiesWithComponent = function(c)
		if c == 6 then return { 7001, 7002, 7003 } end
		return oldEntities(c)
	end
	local stationAt = { [7001] = { 540, 240 }, [7002] = { -3000, 3180 }, [7003] = { 250, 480 } }
	api.engine.getComponent = function(e, c)
		if c == 4 and stationAt[e] then
			local p = stationAt[e]
			return { bbox = { min = { x = p[1] - 20, y = p[2] - 20, z = 0 }, max = { x = p[1] + 20, y = p[2] + 20, z = 10 } } }
		end
		return oldComponent(e, c)
	end
	api.engine.system.stationSystem = { getCarriers = function(group)
		if group == 7001 then return { { "RAIL" }, {} } end        -- a railway station by the cul-de-sac
		if group == 7002 then return { { "ROAD" }, {} } end        -- a bus station by the roundabout's side street
		return { { "AIR", "ROAD" }, {} }                           -- an airport with a bus stop, in the town
	end }
	saved = nil; now = 0
	local instance = dofile(content .. "/road_names/road_names.script.lua")
	for frame = 1, 600 do now = now + 0.02; instance.guiUpdate(nil, { get = function() return nil end }, nil) end
	assert(saved ~= nil, "a read with stations on the map")
	local stationRoads, culName = {}, nil
	for _, st in ipairs(saved.t.streets) do
		if st[1]:find("Station", 1, true) then stationRoads[#stationRoads + 1] = st[1] end
	end
	assert(#stationRoads == 1 and stationRoads[1] == "Station Road", "only the road by the railway station is Station Road, got " .. table.concat(stationRoads, ", "))
	local found = false
	for _, l in ipairs(logs) do if l:find("1 railway stations (of 3 stations of all kinds)", 1, true) then found = true end end
	assert(found, "the log says how many of the stations are railway stations")
	api.engine.getEntitiesWithComponent, api.engine.getComponent = oldEntities, oldComponent
end

-- 14. on the worker thread: the same pass, run in a Lua state of its own from text. The worker is stood in for
--     here by a separate environment with only what the real one has (base, string, table, math, tf3api); the
--     labels and the export it produces must be exactly those of the pass run in the game's own state.
do
	local function run(withWorker)
		local labels, exportText, posted = nil, nil, {}
		local env, pendingResult, loaded = nil, nil, {}
		tf3api = { version = 7, log = function() return true end,
			writeFile = function(name, text) if name == "road_export.json" then exportText = text end return true end,
			setRoadLabels = function(text) labels = text; return 1 end,
			post = function(channel, text) posted[#posted + 1] = { channel, text }; return true end,
			take = function(channel)
				for i, m in ipairs(posted) do
					if m[1] == channel then table.remove(posted, i); return m[2] end
				end
				return false
			end }
		if withWorker then
			tf3api.workerAvailable = function() return true end
			tf3api.workerStart = function(files)
				env = { tf3api = tf3api, string = string, table = table, math = math, tostring = tostring, tonumber = tonumber, type = type,
					ipairs = ipairs, pairs = pairs, pcall = pcall, error = error, select = select, next = next, unpack = unpack,
					setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset, assert = assert }
				env._G = env
				for path in files:gmatch("[^\n]+") do
					local chunk = assert(loadfile(path))
					setfenv(chunk, env)
					local name = path:match("([^/\\]+)$"):match("^([^%.]+)")
					env[name] = chunk()
					loaded[#loaded + 1] = name
					-- the same settings as the pass run here gets from the test (no development cities)
					if name == "names" then env.names.devCities, env.names.ignoreSavedData = devCities, ignoreSavedData end
				end
				return true
			end
			tf3api.workerRun = function(input)
				local ok, result = pcall(env.tf3_job, input)
				pendingResult = { 1, ok, tostring(result) }
				return 1
			end
			tf3api.workerTake = function()
				if pendingResult == nil then return false end
				local r = pendingResult
				pendingResult = nil
				return r[1], r[2], r[3]
			end
		end
		saved = nil; now = 0
		local instance = dofile(content .. "/road_names/road_names.script.lua")
		for frame = 1, 700 do now = now + 0.02; instance.guiUpdate(nil, { get = function() return nil end }, nil) end
		local phase = instance.status()
		tf3api = nil
		return labels, exportText, phase, loaded
	end
	local labelsHere, exportHere, phaseHere = run(false)
	local labelsThere, exportThere, phaseThere, loaded = run(true)
	assert(phaseHere == "done" and phaseThere == "done", "both passes finish (" .. tostring(phaseHere) .. " / " .. tostring(phaseThere) .. ")")
	assert(#loaded == 6 and loaded[1] == "worker_pre" and loaded[5] == "road_names" and loaded[6] == "worker", "the worker is given its six files in order")
	assert(labelsHere ~= nil and labelsThere ~= nil and exportHere ~= nil and exportThere ~= nil, "both produce labels and an export")
	assert(labelsThere == labelsHere, "the labels from the worker are those of the pass run here")
	assert(exportThere == exportHere, "and so is the export")
	local announced = false
	for _, l in ipairs(logs) do if l:find("named on the worker thread", 1, true) then announced = true end end
	assert(announced, "the log says the pass ran on the worker")
end

for _, l in ipairs(logs) do print(l) end
print(string.format("streets by segment count: 1 -> %d, 5 -> %d, 8 -> %d", sizes[1] or 0, sizes[5] or 0, sizes[8] or 0))
print("ALL OK")
