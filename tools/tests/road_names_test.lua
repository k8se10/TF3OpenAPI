-- Offline test for the road-name mod: stubs the game API with a small synthetic town and runs the real script.
-- Usage: lua road_names_test.lua <path to mod content folder>
local content = arg[1]
local logs = {}
function debugPrint(t) logs[#logs + 1] = t end
local now = 0
os.clock = function() return now end
function ug_require(path)
	local file = path:match("::/(.+)$")
	return dofile(content .. "/" .. file)
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
-- a motorway-standard link that leaves the motorway and has an ordinary street joining it half-way: a road in
-- its own right, not a slip road
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
-- British numbering: the hub is Testville (most road); the motorway lies south-south-east of it = zone 3 of 6,
-- and as the longest motorway of its zone it gets the bare zone digit
assert(t.hub == "Testville", "hub town is the one with the most road, got " .. tostring(t.hub))
assert(t.streets[mway][1] == "M3" and t.streets[mway][7] == "M3", "motorway is known by its number, M3; got " .. t.streets[mway][1])
assert(slip ~= mway, "slip road is its own street")
-- 3b. the opposite carriageway is a street of its own but the same road: it carries the same number, and the
--     short motorway-standard slip road off it carries the motorway's number
local other, mslip, mslipEdge
for i, e in ipairs(edges) do
	if e.roadTemplate == "motorway_b" then other = other or streetOfEdge(i); assert(streetOfEdge(i) == other, "second carriageway is one street") end
	if e.roadTemplate == "motorway_slip" then mslip = streetOfEdge(i); mslipEdge = i end
end
assert(other ~= mway and t.streets[other][7] == "M3", "both carriageways carry one number, got " .. tostring(t.streets[other][7]))
assert(mslip ~= other and mslip ~= mway, "motorway slip road is its own street")
assert(t.streets[mslip][1] == "M3" and t.streets[mslip][7] == "M3",
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
assert(n1 ~= n2 and t.streets[n1][7] ~= "" and t.streets[n1][7] == t.streets[n2][7] and t.streets[n1][7] ~= "M3",
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
-- 3d. the ordinary one-way link beyond the motorway's slip road is part of the motorway as well
assert(t.streets[slipLink][7] == "M3" and t.streets[slipLink][1] == "M3", "one-way junction link takes the motorway's number, got " .. tostring(t.streets[slipLink][7]))
-- 3e. the long ordinary country road is a B road with a four-digit number (under 4 km), and keeps a name
local lane
for i, e in ipairs(edges) do if e.roadTemplate == "country_byway" then lane = streetOfEdge(i) end end
assert(t.streets[lane][7]:match("^B%d%d%d%d$"), "a 2 km country road gets a four-digit B number, got '" .. tostring(t.streets[lane][7]) .. "'")
assert(t.streets[lane][1] ~= t.streets[lane][7] and #t.streets[lane][1] >= 2, "a B road still has a street name")
local link
for i, e in ipairs(edges) do if e.roadTemplate == "motorway_link" then link = streetOfEdge(i) end end
assert(t.streets[link][7] ~= "M3", "a motorway-standard road with a junction along it is not a slip road, got " .. tostring(t.streets[link][7]))
assert(#t.streets[link][1] >= 2 and t.streets[link][1] ~= t.streets[link][7], "it is named like any other road, got '" .. t.streets[link][1] .. "'")
assert(t.segments[1][14] == 0 and t.segments[mslipEdge][14] == 1, "one-way flag exported per segment")
-- 4. every street has a name
local seen = {}
for i, s in ipairs(t.streets) do assert(type(s[1]) == "string" and #s[1] >= 2); seen[s[1]] = (seen[s[1]] or 0) + 1 end
-- 4b. British touches
local highStreets = 0
for _, st in ipairs(t.streets) do if st[1] == "High Street" then highStreets = highStreets + 1 end end
assert(highStreets >= 1, "a town has a High Street")
--     the main road east of the grid lies due east of the hub = zone 2; at about 3 km it is long enough for a
--     two-digit number but not for the zone's single digit, so it is the A20; it is named after the town it
--     leads to, and its motorway-standard middle is the A20(M)
local mainStreet = streetOfEdge(mainRoad[#mainRoad])
assert(t.streets[mainStreet][7] == "A20", "main road number A20, got " .. tostring(t.streets[mainStreet][7]))
assert(t.streets[mainStreet][1] == "Testville Road" or t.streets[mainStreet][1] == "Farley Road",
	"main road is named after the town it leads to, got " .. t.streets[mainStreet][1])
local sectionStreet = streetOfEdge(section[1])
assert(t.streets[sectionStreet][7] == "A20(M)" and t.streets[sectionStreet][1] == "A20(M)",
	"motorway-standard section of the A20 is the A20(M), got " .. tostring(t.streets[sectionStreet][7]))
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
tf3api = { version = 1, log = function() return true end,
	writeFile = function(name, text) bridgeFile, bridgeText = name, text; return true end,
	setRoadLabels = function(text) labelText = text; return 1 end }
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
assert(labelText:find("S\tM\t3\tM3\t\t%d+\n"), "motorway label: blue sign, number only, with the road's id")
assert(labelText:find("S\tA\t2\tA20\t", 1, true), "A road label: green sign with its name")
assert(labelText:find("\nG %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+ %-?[%d%.]+"), "segment rows")
assert(not labelText:find("\t\t\t%d+\n"), "no road is sent without a number or a name")
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
	table.remove(edges)
	saved = nil
	for frame = 1, 900 do now = now + 0.02; M.guiUpdate() end
	assert(saved ~= nil and #saved.t.segments == before - 1, "the road network is read again after a change")
	saved = nil
	for frame = 1, 900 do now = now + 0.02; M.guiUpdate() end
	assert(saved == nil, "nothing is read again while the network stays the same")
end

for _, l in ipairs(logs) do print(l) end
print(string.format("streets by segment count: 1 -> %d, 5 -> %d, 8 -> %d", sizes[1] or 0, sizes[5] or 0, sizes[8] or 0))
print("ALL OK")
