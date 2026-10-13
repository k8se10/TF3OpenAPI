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
assert(con.constructionType == "ASSET_DEFAULT" and type(con.updateScript) == "table" and con.updateScript.fileName:find("@updateFn", 1, true))
assert(type(con.menuCategory.categories[1].filterCategories) == "table" and type(con.params) == "table")
local built = loaded[files[2]].updateFn({}, {})
local model = built.subconstructions[1].models[1]
assert(model.id == "tf3api_departure_boards::/tf3api_departure_boards/board_modern_pole_00.mdl" and #model.transf == 16)
-- the screen number picks the model; the game hands the chosen value over counted from 1
assert(con.params[1].key == "screen" and #con.params[1].values == 32 and con.params[1].defaultIndex == 1)
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
	-- which station a screen number shows: the first board placed with the number decides, nearest station
	local stations = { { id = 10, name = "North", x = 0, y = 0 }, { id = 11, name = "South", x = 0, y = 2000 } }
	local a = core.assign({ { id = 7, slot = 0, x = 50, y = 30 }, { id = 5, slot = 0, x = 20, y = 1990 }, { id = 9, slot = 3, x = 0, y = 5000 },
		{ id = 8, slot = 4, x = 100, y = 100 }, { id = 2, slot = 99, x = 0, y = 0 } }, stations)
	assert(a[0].name == "South", "board 5 came first: its station")
	assert(a[3] == nil, "no station within reach")
	assert(a[4].name == "North" and a[99] == nil)

	-- when a vehicle is at a stop: a line of 4 stops, each section 100 s
	local s = { 100, 100, 100, 100 }
	assert(core.eta(4, s, { stop = 2, atStop = true }, 2) == 0, "standing at the stop")
	assert(core.eta(4, s, { stop = 2, atStop = false, since = 30 }, 2) == 70, "on its way there")
	assert(core.eta(4, s, { stop = 2, atStop = false, since = 500 }, 2) == 0, "late: never a negative time")
	assert(core.eta(4, s, { stop = 2, atStop = true }, 4) == 2 * (100 + core.DWELL), "two stops further on")
	assert(core.eta(4, s, { stop = 4, atStop = false, since = 0 }, 1) == 100 + core.DWELL + 100, "round the end of the line")
	assert(core.eta(4, { 100, 0, 100, 100 }, { stop = 2, atStop = true }, 4) == nil, "a section never driven: not known")
	assert(core.eta(4, s, { stop = 9, atStop = true }, 1) == nil and core.eta(1, s, { stop = 1, atStop = true }, 1) == nil)

	-- where it is bound for
	assert(core.destination({ "A", "B" }, 1, "A") == "B")
	assert(core.destination({ "A", "B", "C", "B" }, 1, "A") == "C", "there and back: the far end")
	assert(core.destination({ "A", "B", "C", "B" }, 3, "C") == "A")
	assert(core.destination({ "A", "A" }, 1, "A") == "A" and core.destination({}, 1, "A") == "")

	-- the lines of a screen
	assert(core.lines(0, nil, {}, true) == nil, "no station: the screen is left alone")
	local l = core.lines(0, { name = "Penryn" }, {}, true)
	assert(l[1] == "" and l[2] == "Welcome To Penryn" and l[3] == "", "nothing due")
	l = core.lines(0, { name = "Penryn" }, {}, false)
	assert(l[1] == "" and l[2] == "" and l[3] == "", "no line calls: dark")
	l = core.lines(13 * 3600 + 44 * 60, { name = "Penryn" }, {
		{ eta = 400, destination = "Truro", platform = "2" }, { eta = 30, destination = "Falmouth Docks", platform = "1" },
		{ eta = 5000, destination = "Truro", platform = "2" }, { eta = 9000, destination = "Truro", platform = "2" },
		{ eta = 99999, destination = "Nowhere", platform = "9" } }, true)
	assert(l[1] == "13:44\tFalmouth Docks\t1\tDue", l[1])
	assert(l[2] == "13:50\tTruro\t2\t7 min", l[2])
	assert(l[3] == "15:07\tTruro\t2\t83 min", l[3])
	l = core.lines(23 * 3600 + 59 * 60, { name = "X" }, { { eta = 120, destination = "Tab\there", platform = "1" } }, true)
	assert(l[1] == "00:01\tTab here\t1\t2 min" and l[2] == "" and l[3] == "", "past midnight; a tab in a name cannot break the line")
end
print("boards test: ALL OK")
