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
local built = loaded[files[2]].updateFn({}, {})
local model = built.subconstructions[1].models[1]
assert(model.id == "tf3api_departure_boards::/tf3api_departure_boards/board_modern_pole_00.mdl" and #model.transf == 16)
-- no settings for the player: a board joins its station by itself. The screen it uses is put into its
-- settings by the boards' script, counted from 1.
assert(#con.params == 0, "a board has nothing to set")
local arrivals = load("content/asset/tf3api_departure_boards/board_modern_pole_arrivals.con.lua")
assert(arrivals.constructionType == nil and #arrivals.params == 0 and arrivals.updateScript.fileName == con.updateScript.fileName)
assert(arrivals.description.name ~= con.description.name)
local function modelFor(params) return loaded[files[2]].updateFn({}, params).subconstructions[1].models[1].id end
assert(modelFor({ screen = 1 }):find("pole_00.mdl", 1, true) and modelFor({ screen = 32 }):find("pole_31.mdl", 1, true))
assert(modelFor({ screen = 0 }):find("pole_00.mdl", 1, true) and modelFor({ screen = 33 }):find("pole_00.mdl", 1, true) and modelFor(nil):find("pole_00.mdl", 1, true))
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
	assert(#r == 5 and r[1] == "<2 13:44	<36 Falmouth Docks	>200 1	>238 Due" and r[2]:find("13:50", 1, true) and r[2]:find("On time", 1, true))
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
print("boards test: ALL OK")
