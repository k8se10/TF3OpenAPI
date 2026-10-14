-- Run from the repository root:  lua tools/tests/boards_test.lua
-- Every text file of the departure boards mod must be Lua the game can load, and say what the game
-- expects of its kind. (A single wrong character makes the game skip the file without a word on screen.)
local root = "mod/tf3api_departure_boards/"
local files = {
	"content/asset/tf3api_departure_boards/board_modern_pole.con.lua",
	"content/asset/tf3api_departure_boards/board_modern_pole.con.script.lua",
	"content/tf3api_departure_boards/board_modern_pole_00.mdl",
	"content/models/mesh/tf3api_departure_boards/board_modern_pole.msh",
	"content/models/mesh/tf3api_departure_boards/board_modern_screen_00.msh",
	"content/models/material/tf3api_departure_boards/screen_00.mtl",
	"texture_metadata_cache.lua",
	"content/tf3api_departure_boards/boards.gs.lua",
	"content/tf3api_departure_boards/boards.script.lua",
}
local function load(path)
	local chunk, problem = loadfile(root .. path)
	assert(chunk, "not Lua: " .. tostring(problem))
	local env = setmetatable({ _ = function(s) return s end }, { __index = _G })
	setfenv(chunk, env)
	chunk()
	assert(type(env.data) == "function", path .. ": no data()")
	local value = env.data()
	assert(type(value) == "table", path .. ": data() gives no table")
	return value
end
local loaded = {}
for _, path in ipairs(files) do loaded[path] = load(path) end

local con = loaded[files[1]]
assert(con.constructionType == nil and type(con.updateScript) == "table" and con.updateScript.fileName:find("@updateFn", 1, true))
assert(type(con.menuCategory.categories[1].filterCategories) == "table" and type(con.params) == "table")
local fn = loaded[files[2]].updateFn
local function modelFor(capture, params) return fn(capture, params).subconstructions[1].models[1].id end
local built = fn({}, {})
assert(#built.subconstructions[1].models[1].transf == 16)
-- built from the menu: the style the construction names, in the casing colour chosen (counted from 1)
assert(modelFor({}, {}) == "tf3api_departure_boards::/tf3api_departure_boards/board_modern_pole_c0.mdl", modelFor({}, {}))
assert(modelFor({ style = "board_heritage_pole" }, { tf3api_casing = 3 }):find("board_heritage_pole_c2.mdl", 1, true))
assert(modelFor({ style = "board_hanging" }, { tf3api_casing = 99 }):find("board_hanging_c0.mdl", 1, true))
assert(modelFor({ style = "nonsense" }, nil):find("board_modern_pole_c0.mdl", 1, true))
-- a board rebuilt by the boards' script with a screen number: that screen's model (modern, first casing)
assert(modelFor({}, { screen = 1 }):find("pole_00.mdl", 1, true) and modelFor({}, { screen = 32 }):find("pole_31.mdl", 1, true))
-- one setting for the player: the casing colour. The station is joined by itself.
assert(#con.params == 1 and con.params[1].key == "tf3api_casing" and con.params[1].uiType == "ComboBox")
local arrivals = load("content/asset/tf3api_departure_boards/board_modern_pole_arrivals.con.lua")
assert(arrivals.constructionType == nil and #arrivals.params == 1 and arrivals.updateScript.fileName == con.updateScript.fileName)
assert(arrivals.description.name ~= con.description.name)
-- every style: departures and arrivals, their pictures, and a model per casing colour that loads
for _, style in ipairs({ "board_modern_pole", "board_heritage_pole", "board_hanging" }) do
	for _, kind in ipairs({ "", "_arrivals" }) do
		local c = load("content/asset/tf3api_departure_boards/" .. style .. kind .. ".con.lua")
		assert(c.updateScript.params.style == style, style .. kind)
		for _, picture in ipairs({ "@2x.tga", "_preview@2x.tga" }) do
			local f = assert(io.open(root .. "content/asset/tf3api_departure_boards/" .. style .. kind .. picture, "rb"), style .. kind .. picture)
			f:close()
		end
	end
	for casing = 0, #con.params[1].values - 1 do
		local m = load("content/tf3api_departure_boards/" .. style .. "_c" .. casing .. ".mdl")
		for _, node in ipairs(m.lods[1].node.children) do
			for _, material in ipairs(node.materials) do
				assert(io.open(root .. "content" .. material, "r"), style .. ": missing material " .. material):close()
			end
		end
	end
end
-- every screen has its model, mesh and material, and each model names its own
for slot = 0, 31 do
	local n = string.format("%02d", slot)
	local m = load("content/tf3api_departure_boards/board_modern_pole_" .. n .. ".mdl")
	local found = false
	local function walk(node)
		if node.mesh and node.mesh:find("board_modern_screen_" .. n .. ".msh", 1, true) then
			found = node.materials[1]:find("screen_" .. n .. ".mtl", 1, true) ~= nil
		end
		for _, child in ipairs(node.children or {}) do walk(child) end
	end
	walk(m.lods[1].node)
	assert(found, "screen " .. n .. ": its model does not name its own mesh and material")
	load("content/models/mesh/tf3api_departure_boards/board_modern_screen_" .. n .. ".msh")
	load("content/models/material/tf3api_departure_boards/screen_" .. n .. ".mtl")
end
-- every screen's texture has a size of its own, still apart at a sixteenth of the size
do
	local cache = loaded["texture_metadata_cache.lua"]
	local seen = {}
	for slot = 0, 31 do
		local entry
		for name, value in pairs(cache) do
			if name:find(string.format("screen_%02d.dds", slot), 1, true) then entry = value end
		end
		assert(entry, "screen " .. slot .. " is not in the texture list")
		local w, h = entry.extent[1], entry.extent[2]
		assert(w == 1920 + 16 * (slot % 8) and h == 400 + 16 * math.floor(slot / 8))
		for level = 0, 4 do
			local key = math.floor(w / 2 ^ level) .. "x" .. math.floor(h / 2 ^ level)
			assert(seen[key] == nil, "two screens share the size " .. key)
			seen[key] = slot
		end
	end
end
local mdl = loaded[files[3]]
assert(mdl.version == 2 and #mdl.lods >= 1 and type(mdl.lods[1].node) == "table")
local function meshes(node, out)
	if node.mesh then out[#out + 1] = node.mesh end
	for _, child in ipairs(node.children or {}) do meshes(child, out) end
	return out
end
assert(#meshes(mdl.lods[1].node, {}) >= 2, "the casing and the screen")
for _, path in ipairs({ files[4], files[5] }) do
	local mesh = loaded[path]
	assert(type(mesh.subMeshes) == "table" and #mesh.subMeshes >= 1 and type(mesh.vertexAttr.position) == "table", path)
end
-- the script that feeds the boards: registered for the interface's update, and quiet without the native layer
assert(loaded[files[8]].guiUpdateScript.fileName == "tf3api_departure_boards::/tf3api_departure_boards/boards.script@guiUpdate")
assert(type(loaded[files[9]].guiUpdate) == "function")
loaded[files[9]].guiUpdate()   -- no tf3api table here: must do nothing and raise nothing

-- ---- the rules -------------------------------------------------------------------------------------------
local core = assert(loadfile(root .. "content/tf3api_departure_boards/boards_core.lua"))()
do
	-- joining: the stations within reach of where the board stands, nearest first; a station's outline counts
	local stations = {
		{ id = 10, name = "North", x = 0, y = 0 },
		{ id = 11, name = "Long", x = 0, y = 1000, x0 = -200, y0 = 990, x1 = 200, y1 = 1010 },
		{ id = 12, name = "Near North", x = 60, y = 0 },
	}
	local near = core.nearby(50, 0, stations)
	assert(#near == 2 and near[1].station.name == "Near North" and near[2].station.name == "North")
	assert(#core.nearby(0, 500, stations) == 0, "nothing in reach: the board joins nothing")
	near = core.nearby(190, 1100, stations)
	assert(#near == 1 and near[1].station.name == "Long" and near[1].distance == 90, "90 m from the end of a long station")
	assert(#core.nearby(190, 1111, stations) == 0)

	-- screens: boards that show the same thing share one; what a board has, it keeps; screen 0 is never given
	local change, content, full = core.allocate({
		{ id = 5, station = 10, kind = "departures" },                 -- new
		{ id = 6, station = 10, kind = "departures" },                 -- new, same content
		{ id = 7, station = 10, kind = "arrivals" },                   -- new, other content
		{ id = 8, station = 11, kind = "departures", slot = 4 },       -- has one: keeps it
		{ id = 9 },                                                    -- joined nothing
		{ id = 10, station = 11, kind = "departures", slot = 9 },      -- same content as 8 on another screen: moves to 8's
	})
	assert(change[5] ~= nil and change[5] == change[6] and change[7] ~= nil and change[7] ~= change[5])
	assert(change[5] >= 1 and change[7] >= 1 and change[5] ~= 4 and change[7] ~= 4, "screen 0 and screens in use are not given out")
	assert(change[8] == nil and change[9] == nil and change[10] == 4)
	assert(content[4].station == 11 and content[change[5]].station == 10 and content[change[7]].kind == "arrivals" and content[0] == nil)
	assert(#full == 0)
	-- a second run with the result built in changes nothing: a board is rebuilt once
	local again = core.allocate({
		{ id = 5, station = 10, kind = "departures", slot = change[5] }, { id = 6, station = 10, kind = "departures", slot = change[6] },
		{ id = 7, station = 10, kind = "arrivals", slot = change[7] }, { id = 8, station = 11, kind = "departures", slot = 4 },
		{ id = 10, station = 11, kind = "departures", slot = 4 } })
	assert(next(again) == nil)
	-- more different boards than screens: the rest are told, not given a wrong screen
	local many = {}
	for i = 1, 40 do many[i] = { id = i, station = 100 + i, kind = "departures" } end
	change, content, full = core.allocate(many)
	assert(#full == 40 - (core.SLOTS - 1) and change[1] == 1 and change[31] == 31 and change[32] == nil)
	-- a board built with the unjoined screen and a station is given a real one
	change = core.allocate({ { id = 1, station = 10, kind = "departures", slot = 0 } })
	assert(change[1] == 1)

	-- the plan view's height follows the station's size, both ways
	do
		local h1, along, across = core.planHeight(400, 40, 0, 1)            -- platforms along the map's x
		assert(math.abs(along - 400) < 0.01 and math.abs(across - 40) < 0.01)
		assert(math.abs(h1 - 400 / (2 * core.PLAN_TAN_H) * core.PLAN_MARGIN) < 0.01, "a long station: its length decides")
		local h2 = core.planHeight(400, 300, 0, 1)
		assert(math.abs(h2 - 300 / (2 * core.PLAN_TAN_V) * core.PLAN_MARGIN) < 0.01, "many platforms: its width decides")
		assert(core.planHeight(800, 40, 0, 1) > h1 * 1.9, "twice as long: twice as high")
		-- the same station turned a quarter gives the same height
		local h3, a3, c3 = core.planHeight(40, 400, 1, 0)
		assert(math.abs(h3 - h1) < 0.01 and math.abs(a3 - 400) < 0.01 and math.abs(c3 - 40) < 0.01)
		-- turned by 30 degrees: the box square to the map is larger, the station is not
		local cos, sin = math.cos(math.rad(30)), math.sin(math.rad(30))
		local h4, a4, c4 = core.planHeight(400 * cos + 40 * sin, 400 * sin + 40 * cos, -sin, cos)
		assert(math.abs(a4 - 400) < 0.5 and math.abs(c4 - 40) < 0.5 and math.abs(h4 - h1) < 0.5)
		-- on the diagonal the box says too little: the safe figure
		local h5 = core.planHeight(311, 311, -0.7071, 0.7071)
		assert(h5 >= 311 / (2 * core.PLAN_TAN_V) * core.PLAN_MARGIN - 0.01)
		-- outline not known, and a tiny station
		assert(core.planHeight(nil, nil, 0, 1) > 100 and core.planHeight(4, 4, 0, 1) == 30)
	end

	-- a line's name as a board shows it
	assert(core.lineLabel("(IC 335) London - Rosenheim") == "IC 335")
	assert(core.lineLabel("Schnellzug (Flieg)ende( Kartof)fel") == "Flieg  Kartof")
	assert(core.lineLabel("Line 4") == "Line 4" and core.lineLabel("Hidden ()") == "" and core.lineLabel(nil) == "")

	-- section times averaged over the line's vehicles; a section nobody has driven stays unknown
	local avg = core.averages(3, { { 100, 0, 50 }, { 200, 0, 0 }, { 0, 0, 70 } })
	assert(avg[1] == 150 and avg[2] == 0 and avg[3] == 60)

	-- when a vehicle is at a stop: a line of 4 stops, each section 100 s
	local s = { 100, 100, 100, 100 }
	assert(core.eta(4, s, { stop = 2, atStop = true }, 2) == 0, "standing at the stop")
	assert(core.eta(4, s, { stop = 2, atStop = false, since = 30 }, 2) == 70, "on its way there")
	assert(core.eta(4, s, { stop = 2, atStop = false, since = 500 }, 2) == 0, "late: never a negative time")
	assert(core.eta(4, s, { stop = 2, atStop = true }, 4) == 2 * (100 + core.DWELL), "two stops further on")
	assert(core.eta(4, s, { stop = 4, atStop = false, since = 0 }, 1) == 100 + core.DWELL + 100, "round the end of the line")
	assert(core.eta(4, { 100, 0, 100, 100 }, { stop = 2, atStop = true }, 4) == nil, "a section never driven: not known")
	assert(core.eta(4, s, { stop = 9, atStop = true }, 1) == nil and core.eta(1, s, { stop = 1, atStop = true }, 1) == nil)

	-- where it is bound for, and where it comes from
	assert(core.destination({ "A", "B" }, 1, "A") == "B" and core.origin({ "A", "B" }, 1, "A") == "B")
	assert(core.destination({ "A", "B", "C", "B" }, 1, "A") == "C", "there and back: the far end")
	assert(core.destination({ "A", "B", "C", "D" }, 2, "B") == "D" and core.origin({ "A", "B", "C", "D" }, 2, "B") == "D")
	assert(core.destination({ "A", "A" }, 1, "A") == "A" and core.destination({}, 1, "A") == "" and core.origin({}, 1, "A") == "")

	-- the rows of a station's board
	local rows = core.rows("departures", 13 * 3600 + 44 * 60, { name = "Penryn" }, {
		{ eta = 400, place = "Truro", line = "(IC 2) Main", platform = "2" }, { eta = 30, place = "Falmouth Docks", line = "Branch", platform = "1" },
		{ eta = 5000, place = "Truro", line = "(IC 2) Main", platform = "2" }, { eta = 9000, place = "Truro", line = "x", platform = "2" },
		{ eta = 99999, place = "Nowhere", line = "x", platform = "9" } })
	assert(#rows == 5)
	assert(rows[1] == "<2 DEPARTURES\t>238 \1", "heading and the running clock")
	assert(rows[2] == "<2 Falmouth Docks\t<124 Branch\t>204 1\t>238 Due", rows[2])
	assert(rows[3] == "<2 Truro\t<124 IC 2\t>204 2\t>238 13:50", rows[3])
	assert(rows[4] == "<2 Truro\t<124 IC 2\t>204 2\t>238 15:07", rows[4])
	assert(rows[5] == "Penryn")
	rows = core.rows("arrivals", 0, { name = "Penryn" }, {})
	assert(rows[1] == "<2 ARRIVALS\t>238 \1" and rows[2] == "<2 Sorry no service\t>238 --:--" and rows[3] == "" and rows[4] == "" and rows[5] == "Penryn")
	rows = core.rows("departures", 23 * 3600 + 59 * 60, { name = "X" }, { { eta = 120, place = "Tab\there\1", line = "L", platform = "1" } })
	assert(rows[2] == "<2 Tab here \t<124 L\t>204 1\t>238 00:01" and rows[3] == "", "past midnight; a tab or the clock's code in a name cannot break a row")
end
-- the layouts
do
	local core2 = assert(loadfile(root .. "content/tf3api_departure_boards/boards_core.lua"))()
	local vs = { { eta = 400, place = "Truro", line = "(IC 2) Main", platform = "2", calling = { "Redruth", "Camborne", "Truro" } },
		{ eta = 30, place = "Falmouth Docks", line = "Branch", platform = "1", calling = { "Falmouth Docks" } } }
	local clock = 13 * 3600 + 44 * 60
	local r = core2.layoutRows("national", "departures", clock, { name = "Penryn" }, vs)
	assert(#r == 5 and r[1] == "<2 13:44	<36 Falmouth Docks	>192 1	>238 Due" and r[2]:find("13:50", 1, true) and r[2]:find("On time", 1, true))
	assert(r[4] == core2.CLOCK)
	r = core2.layoutRows("platform", "departures", clock, { name = "Penryn" }, vs)
	assert(r[2] == "~<2 Calling at: Falmouth Docks only" and r[3]:find("2nd", 1, true) and r[3]:find("Truro", 1, true) and r[5] == core2.CLOCK)
	vs[1].eta, vs[2].eta = 30, 400
	r = core2.layoutRows("platform", "departures", clock, { name = "Penryn" }, vs)
	assert(r[2] == "~<2 Calling at: Redruth, Camborne and Truro", r[2])
	r = core2.layoutRows("metro", "departures", clock, { name = "Penryn" }, vs)
	assert(r[1] == "<2 1	<14 Truro	>238 Due" and r[2] == "<2 2	<14 Falmouth Docks	>238 7mins")
	r = core2.layoutRows("bus", "departures", clock, { name = "Penryn" }, vs)
	assert(r[1] == "<2 IC 2	<34 Truro	>238 Due" and r[4] == ">238 Time " .. core2.CLOCK)
	r = core2.layoutRows("national", "departures", clock, { name = "Penryn" }, {})
	assert(r[2] == "Sorry no service" and r[4] == core2.CLOCK)
	assert(core2.layoutRows("station", "departures", clock, { name = "Penryn" }, {})[5] == "Penryn")
	local names = { "A", "B", "C", "D", "E", "F" }
	local c = core2.callingAt(names, 2)
	assert(#c == 3 and c[1] == "C" and c[3] == "E")
end

-- the list of built boards kept in the save goes out and comes back unchanged
do
	local chunk = assert(loadfile(root .. "content/tf3api_departure_boards/boards.script.lua"))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	local B = env.data()
	local list = { { x = 10.5, y = -20.25, z = 3, kind = "departures", platforms = "1,3", mode = "cycle" },
		{ x = 0, y = 0, z = 0, kind = "arrivals", platforms = "", mode = "merged" } }
	local back = B.placedFromText(B.placedToText(list))
	assert(#back == 2 and back[1].x == 10.5 and back[1].y == -20.25 and back[1].platforms == "1,3" and back[1].mode == "cycle")
	assert(back[2].kind == "arrivals" and back[2].platforms == "" and back[2].mode == "merged")
	assert(#B.placedFromText("") == 0 and #B.placedFromText(nil) == 0)
	assert(type(B.guiHandleEvent) == "function" and type(B.update) == "function" and type(B.handleEvent) == "function")
end
-- the plan of a station: three tracks running east-west, 5 m apart, one platform in two pieces
do
	local core3 = assert(loadfile(root .. "content/tf3api_departure_boards/boards_core.lua"))()
	local segments = {
		{ n = 1, x0 = 1000, y0 = 2000, x1 = 1200, y1 = 2000 },
		{ n = 2, x0 = 1000, y0 = 2005, x1 = 1100, y1 = 2005 },
		{ n = 2, x0 = 1100, y0 = 2005, x1 = 1200, y1 = 2005 },
		{ n = 3, x0 = 1200, y0 = 2010, x1 = 1000, y1 = 2010 },
	}
	local list, ba, bc = core3.diagram(segments, 1100, 2015)
	assert(#list == 3, #list)
	for i, p in ipairs(list) do
		assert(math.abs((p.a1 - p.a0) - 200) < 0.01, "platform " .. p.n .. " length " .. (p.a1 - p.a0))
		if i > 1 then assert(math.abs(math.abs(p.c - list[i - 1].c) - 5) < 0.01) end
	end
	assert(math.abs(ba) < 0.01 and math.abs(math.abs(bc) - 10) < 0.01, tostring(ba) .. " " .. tostring(bc))
	local text = core3.diagramText(list, ba, bc)
	assert(text:find("|", 1, true) and select(2, text:gsub(";", ";")) == 2, text)
	assert(core3.diagram({}, 0, 0) == nil and core3.diagramText(nil) == "")
	-- a board's layout and dot colour, kept together
	local l, c, rgb = core3.splitLayout("metro/white")
	assert(l == "metro" and c == "white" and rgb == "235 240 255")
	l, c, rgb = core3.splitLayout("platform")
	assert(l == "platform" and c == "amber" and rgb == "255 150 24")
	l, c = core3.splitLayout(nil)
	assert(l == "national" and c == "amber")
	l, c = core3.splitLayout("nonsense/purple")
	assert(l == "national" and c == "amber")
end
-- the station plan: a station whose tracks run north-east; everything comes out along x
do
	local core4 = assert(loadfile(root .. "content/tf3api_departure_boards/boards_core.lua"))()
	local d = math.sqrt(0.5)
	local segments = {
		{ n = 1, x0 = 1000, y0 = 1000, x1 = 1000 + 200 * d, y1 = 1000 + 200 * d },
		{ n = 2, x0 = 1000 + 5 * d, y0 = 1000 - 5 * d, x1 = 1000 + 205 * d, y1 = 1000 + 195 * d },
	}
	local frame = core4.planFrame(segments)
	assert(math.abs(frame.ux - d) < 1e-6 and math.abs(frame.uy - d) < 1e-6)
	local a0, c0 = core4.planPoint(frame, segments[1].x0, segments[1].y0)
	local a1, c1 = core4.planPoint(frame, segments[1].x1, segments[1].y1)
	assert(math.abs((a1 - a0) - 200) < 1e-6 and math.abs(c1 - c0) < 1e-6, "a platform track lies along x")
	local fallback = core4.planFrame({}, 50, 60, 0, 2)
	assert(fallback.cx == 50 and fallback.cy == 60 and fallback.ux == 0 and fallback.uy == 1)
	-- what a model is on the plan
	assert(core4.planKind("stations/rail/perron_5.mdl", 100) == "P" and core4.planKind("x/oppie_platform_lamp.mdl", 1) == nil)
	assert(core4.planKind("stations/rail/perron_5_roof.mdl", 100) == nil and core4.planKind("stations/rail/tn_passenger_wait_area.mdl", 100) == nil)
	assert(core4.planKind("stations/rail/perron_5_underpass.mdl", 30) == "S" and core4.planKind("a/stairs_a.mdl", 5) == "S")
	assert(core4.planKind("stations/rail/station_2_main.mdl", 300) == "B" and core4.planKind("assets/bench.mdl", 2) == nil)
	local quads = { { kind = "P", x = { 1000, 1010, 1010, 1000 }, y = { 1000, 1000, 1010, 1010 } } }
	local tracks = { { n = 0, x = { 990, 1100 }, y = { 990, 1100 } } }
	for _, s in ipairs(segments) do tracks[#tracks + 1] = { n = s.n, x = { s.x0, s.x1 }, y = { s.y0, s.y1 } } end
	local scene, bounds, tags = core4.planScene(frame, quads, tracks)
	local lines = {}
	for line in scene:gmatch("[^\n]+") do lines[#lines + 1] = line end
	assert(#lines == 4 and lines[1]:match("^P ") and lines[2]:match("^T 0 ") and lines[3]:match("^T 1 "), scene)
	assert(#tags == 2 and tags[1].n == 1 and tags[2].n == 2 and tags[1].x < 0 and bounds.x1 > bounds.x0)
	local info = core4.planInfoText(bounds, tags, frame)
	local x0, y0, x1, y1, ux, uy, cx, cy, rest = info:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)|(.*)$")
	assert(tonumber(x0) and tonumber(uy) and math.abs(tonumber(cx) - frame.cx) < 0.01 and rest:match("^1:%-?[%d.]+:%-?[%d.]+:%-?[%d.]+;2:"), info)
	local emptyScene, emptyBounds = core4.planScene(frame, {}, {})
	assert(emptyScene == "" and emptyBounds.x1 > emptyBounds.x0)
end
-- the window's script and its styles are Lua the game can read
for _, file in ipairs({ "content/gui/tf3api_boards/boards_ui.script.lua", "content/gui/tf3api_boards/boards_ui.css.lua" }) do
	assert(loadfile(root .. file))
end
for _, picture in ipairs({ "plan_main", "plan_overview", "icon_board_d", "icon_board_d_sel", "icon_board_a", "icon_board_a_sel", "icon_entrance",
		"swatch_platform", "swatch_track", "swatch_building", "arrow_north" }) do
	assert(io.open(root .. "content/gui/tf3api_boards/" .. picture .. ".tga", "rb"), picture .. ".tga is missing: run tools/build_boards.py"):close()
end
-- trains on the plan: in, standing, out
do
	local c = assert(loadfile(root .. "content/tf3api_departure_boards/boards_core.lua"))()
	local a0, a1 = -100, 100
	-- coming in from the left (moving right): far away first, at the stop on time, never past it
	local item = { phase = "in", t = c.ANIM_APPROACH, dir = 1 }
	local f0 = c.animFront(item, 0, a0, a1)
	local f1 = c.animFront(item, c.ANIM_APPROACH / 2, a0, a1)
	local f2, d2 = c.animFront(item, c.ANIM_APPROACH, a0, a1)
	local f3 = c.animFront(item, c.ANIM_APPROACH + 20, a0, a1)
	assert(f0 < f1 and f1 < f2 and f2 == a1 - c.ANIM_MARGIN and f3 == f2 and d2 == 1, string.format("%s %s %s %s", f0, f1, f2, f3))
	assert(f1 - f0 > f2 - f1, "slows down as it comes in")
	assert(c.animFront({ phase = "in", t = c.ANIM_APPROACH + 30, dir = 1 }, 0, a0, a1) == nil, "too far off to be seen")
	-- coming in from the right stops at the left end
	assert(c.animFront({ phase = "stand", dir = -1 }, 99, a0, a1) == a0 + c.ANIM_MARGIN)
	-- leaving: speeding up away from the stop, gone after ANIM_LEAVE
	local out = { phase = "out", t = 0, dir = 1 }
	local o0, o1, o2 = c.animFront(out, 0, a0, a1), c.animFront(out, c.ANIM_LEAVE / 2, a0, a1), c.animFront(out, c.ANIM_LEAVE, a0, a1)
	assert(o0 == a1 - c.ANIM_MARGIN and o0 < o1 and o1 < o2 and (o2 - o1) > (o1 - o0), "speeds up as it leaves")
	assert(c.animFront(out, c.ANIM_LEAVE + 1, a0, a1) == nil and c.animFront({ phase = "x" }, 0, a0, a1) == nil)
	-- as text and back
	local text = c.animText({ { id = 12, phase = "in", platform = 2, t = 30.25, dir = -1,
		cars = { { file = "ui/models_20/p86.tga", length = 14.2, reversed = false }, { file = "ui/models_20/p86.tga", length = 14.2, reversed = true } } },
		{ id = 13, phase = "stand", platform = 1, dir = 1, cars = {} } })
	local back = c.animRead(text)
	assert(#back == 2 and back[1].id == "12" and back[1].phase == "in" and back[1].platform == 2 and math.abs(back[1].t - 30.3) < 0.06 and back[1].dir == -1, text)
	assert(#back[1].cars == 2 and back[1].cars[2].reversed and not back[1].cars[1].reversed and back[1].cars[1].file == "ui/models_20/p86.tga", text)
	assert(back[2].phase == "stand" and #back[2].cars == 0 and #c.animRead("") == 0)
end
-- a platform's track as one path: its pieces in any order and direction, then the track either side
do
	local c = assert(loadfile(root .. "content/tf3api_departure_boards/boards_core.lua"))()
	local scene = table.concat({
		"T 1 50.0 0.0 0.0 0.0",            -- platform 1, its right half, drawn right to left
		"T 1 -50.0 0.0 0.0 0.0",           -- its left half
		"T 0 50.0 0.0 60.0 2.0 70.0 6.0",  -- curving away on the right
		"T 0 -50.0 0.0 -60.0 0.0",         -- straight on the left
		"T 0 -50.0 0.0 -55.0 30.0",        -- points: a sharp branch, not taken
		"T 2 -50.0 -5.0 50.0 -5.0",        -- platform 2
		"P 0 0 1 0 1 1 0 1",
	}, "\n")
	local tracks = c.sceneTracks(scene)
	assert(#tracks == 6, #tracks)
	local path = c.platformPath(tracks, 1)
	assert(path ~= nil and path.points[1][1] == -60 and path.points[#path.points][1] == 70, "joined end to end")
	assert(math.abs(path.length - (10 + 100 + math.sqrt(104) + math.sqrt(116))) < 0.01, path.length)
	for _, q in ipairs(path.points) do assert(q[2] < 25, "the branch was taken") end
	-- distances and places along it
	local s0 = c.pathAt(path, 0)
	assert(math.abs(s0 - 60) < 0.01, s0)
	local x, y, tx, ty = c.pathPoint(path, s0)
	assert(math.abs(x) < 0.01 and math.abs(y) < 0.01 and math.abs(tx - 1) < 0.01 and math.abs(ty) < 0.01)
	local cx, cy, ctx, cty = c.pathPoint(path, path.length - 1)
	assert(cy > 4 and cty > 0.3, "follows the curve")
	local bx, by = c.pathPoint(path, path.length + 10)
	assert(bx > 70, "carries on straight beyond the end")
	assert(c.platformPath(tracks, 3) == nil and c.platformPath(tracks, 2).length == 100)
end
-- which platform a board stands at, and what it serves from its choice
do
	local c = assert(loadfile(root .. "content/tf3api_departure_boards/boards_core.lua"))()
	local tracks = { { n = 1, x = { 0, 200 }, y = { 0, 0 } }, { n = 2, x = { 0, 200 }, y = { 10, 10 } }, { n = 0, x = { 0, 200 }, y = { 4, 4 } } }
	assert(c.nearestPlatform(tracks, 100, 3) == 1 and c.nearestPlatform(tracks, 100, 8) == 2)
	assert(c.nearestPlatform(tracks, 100, 300, 25) == nil, "too far from any platform")
	assert(c.servedPlatforms("", 2) == "2" and c.servedPlatforms("", nil) == "" and c.servedPlatforms("all", 2) == "" and c.servedPlatforms("1,3", 2) == "1,3")
end
-- destinations the player set for the line (the Destination Displays mod): the next one after this stop
do
	local core = dofile("mod/tf3api_departure_boards/content/tf3api_departure_boards/boards_core.lua")
	if type(core) == "function" then core = core() end
	local names = { "Selsey", "Fakenham", "Hungerford", "Woking", "Newton-le-Willows", "Woking", "Hungerford", "Fakenham" }
	local marks = { { index = 1, name = "Selsey" }, { index = 5, name = "Newton-le-Willows" } }
	assert(core.destination(names, 2, "Fakenham", marks) == "Newton-le-Willows", "bound for the next destination set")
	assert(core.destination(names, 5, "Newton-le-Willows", marks) == "Selsey", "leaving a destination: the next one")
	assert(core.destination(names, 7, "Hungerford", marks) == "Selsey", "round the end of the line")
	assert(core.origin(names, 7, "Hungerford", marks) == "Newton-le-Willows", "arriving from the last destination")
	local calling = core.callingAt(names, 2, marks)
	assert(#calling == 3 and calling[3] == "Newton-le-Willows", "calling at up to the destination")
	assert(core.destination(names, 2, "Fakenham", { { index = 5, name = "Liverpool (custom)" } }) == "Liverpool (custom)", "the display text set")
	assert(core.destination(names, 2, "Fakenham", nil) == "Woking", "without the mod: half-way round")
end

print("boards test: ALL OK")
