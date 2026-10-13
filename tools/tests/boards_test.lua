-- Run from the repository root:  lua tools/tests/boards_test.lua
-- Every text file of the departure boards mod must be Lua the game can load, and say what the game
-- expects of its kind. (A single wrong character makes the game skip the file without a word on screen.)
local root = "mod/tf3api_departure_boards/"
local files = {
	"content/asset/tf3api_departure_boards/board_modern_pole.con.lua",
	"content/asset/tf3api_departure_boards/board_modern_pole.con.script.lua",
	"content/tf3api_departure_boards/board_modern_pole.mdl",
	"content/models/mesh/tf3api_departure_boards/board_modern_pole.msh",
	"content/models/mesh/tf3api_departure_boards/board_modern_screen.msh",
	"content/models/material/tf3api_departure_boards/screen_00.mtl",
	"texture_metadata_cache.lua",
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
assert(model.id == "tf3api_departure_boards::/tf3api_departure_boards/board_modern_pole.mdl" and #model.transf == 16)
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
print("boards test: ALL OK")
