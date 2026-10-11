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
	edges[#edges + 1] = e
	return #edges + 5000
end
local small = { { width = 3, speed = 11 }, { width = 3, speed = 11 } }
local wide = { { width = 4.5, speed = 16 }, { width = 4.5, speed = 16 }, { width = 4.5, speed = 16 }, { width = 4.5, speed = 16 } }
local fast = { { width = 4, speed = 33 }, { width = 4, speed = 33 } }
local grid = {}
for ix = 0, 5 do grid[ix] = {} for iy = 0, 5 do grid[ix][iy] = node(ix * 100, iy * 100 + ((iy == 3) and (ix % 2) * 6 or 0)) end end
for ix = 0, 5 do for iy = 0, 5 do
	if ix < 5 then edge(grid[ix][iy], grid[ix + 1][iy], iy == 3 and wide or small, iy == 3 and { tmpl = "avenue" } or nil) end
	if iy < 5 then edge(grid[ix][iy], grid[ix][iy + 1], small) end
end end
local m = {}
for i = 0, 8 do m[i] = node(-200 + i * 150, -150) end
for i = 0, 7 do edge(m[i], m[i + 1], fast, { tmpl = "motorway" }) end
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

local saved
app = { saveUserdata = function(dir, file, t) saved = { dir = dir, file = file, t = t } end }
api = { type = { ComponentType = { BASE_EDGE = 1, BASE_EDGE_STREET = 2, TOWN = 3, BOUNDING_VOLUME = 4 } }, engine = { util = {} } }
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
-- 4. every street has a name
local seen = {}
for _, s in ipairs(t.streets) do assert(type(s[1]) == "string" and #s[1] >= 2); seen[s[1]] = (seen[s[1]] or 0) + 1 end
-- 4b. British touches
local highStreets = 0
for _, st in ipairs(t.streets) do if st[1] == "High Street" then highStreets = highStreets + 1 end end
assert(highStreets >= 1, "a town has a High Street")
--     the main road east of the grid lies due east of the hub = zone 2; as the longest A road there it is the A2,
--     it is named after the town it leads to, and its motorway-standard middle is the A2(M)
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

for _, l in ipairs(logs) do print(l) end
print(string.format("streets by segment count: 1 -> %d, 5 -> %d, 8 -> %d", sizes[1] or 0, sizes[5] or 0, sizes[8] or 0))
print("ALL OK")
