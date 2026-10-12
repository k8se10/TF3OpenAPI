-- Offline test of the mod converter's rules. Run from the repository root:
--   lua tools/tests/converter_test.lua
-- The old mod below is made up for the test (no real mod's files); it has one model in the old group form
-- (Transport Fever 1) and one that already is a node tree (Transport Fever 2).

local C = dofile("converter/convert.lua")
C.layout = "content"   -- sections 1 to 8 check Transport Fever 3's own layout; section 9 the old layout, which is what is used

-- the start of a 256 x 128 texture with 9 mip levels
local function ddsHead(fourCC)
	return "DDS " .. string.rep("\0", 8) .. "\128\0\0\0" .. "\0\1\0\0" .. string.rep("\0", 8) .. "\9\0\0\0" .. string.rep("\0", 52) .. fourCC .. string.rep("\0", 44)
end

local source = {
	["mod.lua"] = [[
function data()
return {
	info = { minorVersion = 0, severityAdd = "NONE", name = _("mod_name"), description = _("mod_desc"), authors = { { name = "Someone" } } },
	runFn = function(settings) addModifier("loadModel", function(f, d) return d end) end,
}
end]],
	["strings.lua"] = [[
function data()
return { en = { mod_name = "A wagon", mod_desc = "Says \"hello\"", wagon_name = "Wagon" }, de = { mod_name = "Ein Wagen" } }
end]],
	["res/models/model/vehicle/waggon/Old_Wagon.mdl"] = [[
local helper = require "some_helper"
local seats = require "wagon_seats"
function data()
return {
	lods = {
		{
			children = {
				{ id = "vehicle/waggon/old/Body.msh", type = "MESH", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } },
				{ id = "vehicle/waggon/old/door.grp", type = "GROUP", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1 } },
				{ id = "vehicle/waggon/old/cargo.msh", type = "MESH", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } },
				{ id = "vehicle/waggon/old/axle.msh", type = "MESH", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2, 0, 0, 1 } },
				{ id = "vehicle/waggon/old/axle.msh", type = "MESH", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -2, 0, 0, 1 } },
			},
			events = { open_doors = { [1] = nil, [2] = { name = "open", forward = true } }, close_doors = { [2] = { name = "open", forward = false } } },
			matConfigs = { { 1, 0, 0, 0, 0 } },
			static = false, visibleFrom = 0, visibleTo = 500,
		},
	},
	metadata = {
		description = { name = _("wagon_name"), description = helper.text() },
		maintenance = { lifespan = 30, runningCosts = 1000 },
		cost = { price = 50000 },
		seatList = seats.make(2),
		railVehicle = { topSpeed = 90, weight = 20, configs = { { axles = { "vehicle/waggon/old/axle.msh" } } } },
		transportVehicle = { carrier = "RAIL", capacities = { { type = "COAL", capacity = 20, loadIndicator = { type = "LEVEL", params = { id = 4 } } } } },
	},
}
end]],
	-- the door group: one leaf, animated by the group's own event table
	["res/models/group/vehicle/waggon/old/door.grp"] = [[
function data()
return {
	children = { { id = "vehicle/waggon/old/leaf.msh", type = "MESH", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } } },
	events = { open = { [1] = { name = "swing", forward = true } } },
	matConfigs = { { 0 } },
}
end]],
	["res/models/mesh/vehicle/waggon/old/body.msh"] = [[
function data()
return {
	matConfigs = { { 0, 0 }, { 1, 0 } },
	subMeshes = {
		{ indices = { position = { count = 12, offset = 0 } }, materials = { "vehicle/waggon/old_red.mtl", "vehicle/waggon/old_blue.mtl" } },
		{ indices = { position = { count = 12, offset = 12 } }, materials = { "vehicle/waggon/old_glass.mtl" } },
	},
	vertexAttr = { position = { count = 36, numComp = 3, offset = 24 } },
}
end]],
	["res/models/mesh/vehicle/waggon/old/body.msh.blob"] = "BLOB",
	["res/models/mesh/vehicle/waggon/old/leaf.msh"] = [[
function data()
return {
	animations = { swing = { type = "KEYFRAME", params = { origin = { 0, 0, 0 }, keyframes = { { time = 0, rot = { 0, 0, 0 }, transl = { 0, 0, 0 } }, { time = 1000, rot = { 90, 0, 0 }, transl = { 0, 0, 0 } } } } } },
	matConfigs = { { 0 } },
	subMeshes = { { indices = {}, materials = { "vehicle/waggon/old_red.mtl" } } },
	vertexAttr = {},
}
end]],
	["res/models/mesh/vehicle/waggon/old/cargo.msh"] = [[function data() return { matConfigs = { { 0 } }, subMeshes = { { indices = {}, materials = { "vehicle/waggon/old_red.mtl" } } }, vertexAttr = {} } end]],
	["res/models/mesh/vehicle/waggon/old/axle.msh"] = [[function data() return { matConfigs = { { 0 } }, subMeshes = { { indices = {}, materials = { "vehicle/waggon/old_red.mtl" } } }, vertexAttr = {} } end]],
	["res/models/material/vehicle/waggon/old_red.mtl"] = [[
function data()
return { order = 0, type = "REFLECTIVE_NRML_MAP", params = {
	map_color_reflect = { fileName = "models/vehicle/waggon/Red.dds", type = "TWOD", wrapS = "REPEAT", wrapT = "REPEAT" },
	map_normal = { fileName = "models/vehicle/waggon/red_nrml.dds", type = "TWOD" },
	map_env = { fileName = "c.tga", type = "CUBE" },
	two_sided = { twoSided = false },
} }
end]],
	["res/models/material/vehicle/waggon/old_blue.mtl"] = [[
function data()
return { order = 0, type = "PHYSICAL", params = {
	map_albedo = { fileName = "models/vehicle/waggon/blue.dds", type = "TWOD" },
	fade_out_range = { fadeOutEndDist = 20000, fadeOutStartDist = 10000 },
} }
end]],
	["res/models/material/vehicle/waggon/old_lights.mtl"] = [[
function data()
return { order = 0, type = "EMISSIVE", params = { map_emissive = { fileName = "models/vehicle/stock_lights.tga", type = "TWOD" } } }
end]],
	["res/models/material/vehicle/waggon/old_glass.mtl"] = [[
function data()
return { order = 1, type = "TRANSPARENT", params = { map_color_alpha = { fileName = "models/vehicle/waggon/glass.tga", type = "TWOD" } } }
end]],
	["res/textures/models/vehicle/waggon/red.dds"] = ddsHead("DXT1"),
	["res/textures/models/vehicle/waggon/red_nrml.dds"] = ddsHead("ATI2"),
	["res/textures/models/vehicle/waggon/blue.dds"] = ddsHead("DXT1"),
	["res/textures/models/vehicle/waggon/glass.tga"] = "TGA",
	["res/textures/ui/models_small/vehicle/waggon/old_wagon.tga"] = "TGA",
	-- a Transport Fever 2 model: already a tree
	["res/models/model/vehicle/waggon/new_wagon.mdl"] = [[
function data()
return {
	collider = { params = {}, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }, type = "MESH" },
	lods = { { node = { name = "RootNode", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }, children = {
		{ name = "body", mesh = "vehicle/waggon/old/body.msh", materials = { "vehicle/waggon/old_blue.mtl", "vehicle/stock_glass.mtl" },
			transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
			animations = { open_all_doors = { type = "FILE_REF", params = { id = "vehicle/waggon/open.ani" } } } },
	} }, static = false, visibleFrom = 0, visibleTo = 800 } },
	metadata = { railVehicle = { topSpeed = 25, configs = { { axles = { "vehicle/waggon/old/axle.msh" } } } },
		transportVehicle = { carrier = "RAIL", compartments = { { { { type = "GOODS", capacity = 8 }, { type = "MARBLE", capacity = 8 } } } } } },
	version = 1,
}
end]],
	["res/models/animation/vehicle/waggon/open.ani"] = "function data() return { times = { 0 }, transfs = { { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } } } end",
	["res/config/something.lua"] = "x",
	-- a script of the mod's own, using the older games' libraries and an old Lua function
	["res/scripts/wagon_seats.lua"] = [[
local vec3 = require "vec3"
local transf = require "transf"
local seats = {}
function seats.make(n)
	local out = {}
	for i = 1, n do
		table.insert(out, { group = 1, power = math.pow(2, i), transf = transf.rotZYXTransl(transf.degToRad(90, 0, 0), vec3.new(i, 2, 3)) })
	end
	return out
end
return seats]],
}

local written, copied = {}, {}
local before = {}
for k, v in pairs(source) do before[k] = v end
local host = {
	list = function(root)
		assert(root == "SRC")
		local out = {}
		for k in pairs(source) do out[#out + 1] = k end
		return out
	end,
	read = function(path) return source[path:sub(5)] end,
	readHead = function(path, n) local t = source[path:sub(5)] return t and t:sub(1, n) end,
	write = function(path, text) written[path] = text end,
	copy = function(from, to) assert(source[from:sub(5)], "copy of a file that is not there: " .. from) copied[to] = from:sub(5) end,
}

local report = C.convertMod(host, "SRC", "DST", "Old Wagon_1")
for k, v in pairs(source) do assert(before[k] == v, "the source was changed: " .. k) end

local function read(path)
	local text = assert(written[path], "not written: " .. path)
	return assert(C.readData(text, path))
end

-- 1. the mod itself
assert(report.modId == "legacy_old_wagon_1")
local modJson = written["DST/mod.json"]
assert(modJson:find('"modId": "legacy_old_wagon_1"', 1, true) and modJson:find('"name": "A wagon"', 1, true), modJson)
assert(written["DST/strings.json"]:find('"mod_desc": "Says \\"hello\\""', 1, true), "texts are written as JSON")

-- 2. the old model became a tree, every part in its old place
local old = read("DST/content/vehicle/waggon/old_wagon.mdl")
assert(old.version == 2 and old.collider.type == "MESH", "written as the newer game's own model version")
assert(old.metadata.transformatorConfig.transformator.name == "::/vehicle/train/shared/default_train.trf" and old.metadata.transformatorConfig.skipFromLod == 1)
assert(old.metadata.railVehicle.soundSet == nil)
local kids = old.lods[1].node.children
assert(#kids == 5, "five parts, as in the old model")
assert(kids[1].name == "Body" and kids[1].mesh == "/models/mesh/vehicle/waggon/old/body.msh")
assert(kids[1].materials[1] == "/models/material/vehicle/waggon/old_blue.mtl", "the model's material choice (second of the first sub-mesh) is applied: " .. tostring(kids[1].materials[1]))
assert(kids[1].materials[2] == "/models/material/vehicle/waggon/old_glass.mtl")
assert(kids[2].name == "door" and kids[2].mesh == nil and #kids[2].children == 1)
local leaf = kids[2].children[1]
assert(leaf.mesh == "/models/mesh/vehicle/waggon/old/leaf.msh")
assert(leaf.animations.open_doors.type == "KEYFRAME" and leaf.animations.open_doors.forward == true, "the door leaf opens on open_doors")
assert(leaf.animations.close_doors.forward == false, "and runs backwards on close_doors")
assert(kids[3].name == "cargo" and kids[3].mesh == nil, "the cargo-level mesh is an empty node")
assert(kids[4].name == "axle" and kids[5].name == "axle_2", "names are unique")
assert(kids[5].mesh == "/models/mesh/vehicle/waggon/old/axle.msh")

-- 3. its metadata: units, automatic prices, parts renamed with the meshes, translation calls kept
local meta = old.metadata
assert(math.abs(meta.railVehicle.topSpeed - 25) < 1e-9, "90 km/h is 25 m/s")
assert(meta.maintenance.lifespan == 30 * 730.5 and meta.maintenance.runningCosts == -1 and meta.cost.price == -1)
assert(meta.railVehicle.configs[1].axles[1] == "/models/mesh/vehicle/waggon/old/axle.msh")
local carried = meta.transportVehicle.capacities[1]
assert(carried.loadIndicator == nil and carried.type == nil and carried.capacity == 20)
assert(carried.cargoTypeSet.cargoTypesIncluded[1] == "::/cargos/coal/coal.cargo", "an old cargo word becomes the newer game's cargo")
assert(written["DST/content/vehicle/waggon/old_wagon.mdl"]:find('name = _("wagon_name")', 1, true), "the name stays a translation call")
assert(meta.description.description == nil, "a value from a missing library is left out")
-- the mod's own script was run, with the older games' vector and transform libraries
assert(#meta.seatList == 2 and meta.seatList[2].power == 4, "the mod's own script built the seat list")
local t = meta.seatList[2].transf
local want = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 2, 2, 3, 1 }
for i = 1, 16 do assert(math.abs(t[i] - want[i]) < 1e-9, "a quarter turn about z, then the move: entry " .. i .. " is " .. tostring(t[i])) end
local m = C.transf.mul(C.transf.transl({ 1, 0, 0 }), C.transf.rotZ(math.pi / 2))
assert(math.abs(m[1]) < 1e-9 and math.abs(m[2] - 1) < 1e-9 and m[13] == 1, "mul applies the second transform first")

-- 4. meshes: geometry only; the blob is copied
local body = read("DST/content/models/mesh/vehicle/waggon/old/body.msh")
assert(body.matConfigs == nil and body.subMeshes[1].materials == nil and body.subMeshes[2].indices.position.offset == 12)
assert(read("DST/content/models/mesh/vehicle/waggon/old/leaf.msh").animations == nil)
assert(copied["DST/content/models/mesh/vehicle/waggon/old/body.msh.blob"] == "res/models/mesh/vehicle/waggon/old/body.msh.blob")
assert(written["DST/content/models/group/vehicle/waggon/old/door.grp"] == nil, "groups are not carried over")

-- 5. materials
local red = read("DST/content/models/material/vehicle/waggon/old_red.mtl")
assert(red.type == "PHYSICAL_NRML_MAP")
assert(red.params.map_albedo.fragmentSamplers.albedoTex.fileName == "/textures/models/vehicle/waggon/red.dds")
assert(red.params.map_normal.fragmentSamplers.normalTex.redGreen == true, "a two-channel normal map is recognised from the file")
assert(red.params.map_metal_gloss_ao.fragmentSamplers.metalGlossAoTex.fileName == "/textures/converter/default_mga.dds")
assert(red.params.map_env == nil and red.params.map_color_reflect == nil)
assert(red.params.two_sided.fragmentProperties[1].twoSided == false)
assert(red.params.light_receiver.fragmentProperties[1].isLegacyMaterial == true)
local blue = read("DST/content/models/material/vehicle/waggon/old_blue.mtl")
assert(blue.type == "PHYSICAL" and blue.params.fade_out_range.vertexProperties[1].fadeOutEndDist == 20000)
assert(blue.params.map_normal == nil, "no normal map is invented for a material type without one")
local glass = read("DST/content/models/material/vehicle/waggon/old_glass.mtl")
assert(glass.type == "PHYS_TRANSPARENT" and glass.order == 1)
assert(glass.params.map_albedo_opacity.fragmentSamplers.albedoOpacityTex.fileName == "/textures/models/vehicle/waggon/glass.tga")
assert(glass.params.alpha_test.fragmentProperties[1].cutout == true)
local default = written["DST/content/textures/converter/default_mga.dds"]
assert(default and #default == 128 + 64 and default:sub(1, 4) == "DDS ", "the plain texture is a 4x4 uncompressed DDS")
assert(written["DST/content/textures/converter/default_normal.dds"] == nil, "only the plain textures that are used are written")
assert(copied["DST/content/textures/models/vehicle/waggon/red.dds"] == "res/textures/models/vehicle/waggon/red.dds")
local cache = read("DST/texture_metadata_cache.lua")
local listed = cache["textures/models/vehicle/waggon/red.dds"]
assert(listed.channels == 4 and listed.extent[1] == 256 and listed.extent[2] == 128 and listed.numMipmaps == 9 and listed.numStrippedMipmaps == 0, "the texture list has each texture's size and mip levels")
assert(cache["textures/converter/default_mga.dds"].extent[1] == 4 and cache["textures/converter/default_mga.dds"].numMipmaps == 1)
assert(cache["textures/models/vehicle/waggon/glass.tga"] == nil, "a texture it cannot read the size of is left out of the list")

-- 6. the model that already was a tree: only its references move
local new = read("DST/content/vehicle/waggon/new_wagon.mdl")
local part = new.lods[1].node.children[1]
assert(part.mesh == "/models/mesh/vehicle/waggon/old/body.msh" and part.materials[2] == "/models/material/vehicle/stock_glass.mtl")
assert(part.animations.open_all_doors.params.id == "/models/animation/vehicle/waggon/open.ani")
assert(new.metadata.railVehicle.topSpeed == 25, "a Transport Fever 2 model's speed is already in m/s")
assert(new.version == 2 and new.metadata.transformatorConfig ~= nil)
assert(new.metadata.railVehicle.configs[1].axles[1] == "/models/mesh/vehicle/waggon/old/axle.msh")
assert(copied["DST/content/models/animation/vehicle/waggon/open.ani"])
local entries = new.metadata.transportVehicle.compartments[1][1]
assert(entries[1].cargoTypeSet.cargoClassesIncluded[1] == "GOODS" and entries[1].type == nil, "a cargo with no equivalent takes the nearest, here a class")
assert(entries[2].type == "MARBLE" and entries[2].cargoTypeSet == nil, "an unknown cargo is left and reported")

-- 7. the report says what happened and what did not
local text = written["DST/conversion_report.txt"]
assert(text == report.text)
assert(text:find("Models: 2 (1 of them in the old group form)   Meshes: 4   Materials: 4   Textures: 5", 1, true), text)
assert(text:find("material vehicle/stock_glass.mtl (model vehicle/waggon/new_wagon.mdl)", 1, true), "a material of the older game itself is listed as missing")
assert(text:find("mod.lua: the mod's own script (runFn) is not carried over", 1, true))
assert(text:find("res/config/something.lua", 1, true), "files the converter does not handle are listed")
assert(text:find("res/scripts/wagon_seats.lua: run during the conversion", 1, true) and not text:find('library "wagon_seats"', 1, true))
assert(text:find('script library "some_helper"', 1, true))
assert(text:find("old type REFLECTIVE_NRML_MAP written as PHYSICAL_NRML_MAP", 1, true))
assert(text:find("cargo GOODS has no equivalent", 1, true) and text:find("cargo MARBLE is unknown", 1, true))

-- 8. the same input gives the same output
local first = {}
for k, v in pairs(written) do first[k] = v end
written = {}
C.convertMod(host, "SRC", "DST", "Old Wagon_1")
for k, v in pairs(first) do assert(written[k] == v, "output differs between runs: " .. k) end

-- 9. the old layout: what a mod is converted to today. Same tree, old places, old references, flat materials.
C.layout = "legacy"
written, copied = {}, {}
C.convertMod(host, "SRC", "DST", "Old Wagon_1")
local legacy = read("DST/content/res/models/model/vehicle/waggon/Old_Wagon.mdl")
assert(legacy.version == 1 and legacy.metadata.transformatorConfig == nil, "the old layout keeps the old model version")
local parts = legacy.lods[1].node.children
assert(parts[1].mesh == "vehicle/waggon/old/Body.msh" and parts[1].materials[1] == "vehicle/waggon/old_blue.mtl", "references stay as the old mod wrote them")
assert(parts[2].children[1].animations.open_doors.forward == true and parts[3].mesh == nil)
assert(legacy.metadata.railVehicle.configs[1].axles[1] == "vehicle/waggon/old/axle.msh")
assert(math.abs(legacy.metadata.railVehicle.topSpeed - 25) < 1e-9)
local flat = read("DST/content/res/models/material/vehicle/waggon/old_red.mtl")
assert(flat.type == "PHYSICAL_NRML_MAP" and flat.params.map_albedo.fileName == "models/vehicle/waggon/Red.dds", "materials stay flat, with the old type mapped")
assert(flat.params.map_normal.redGreen == true and flat.params.map_metal_gloss_ao.fileName == "converter/default_mga.dds")
assert(flat.params.light_receiver == nil and flat.params.map_albedo.fragmentSamplers == nil)
assert(written["DST/content/res/textures/converter/default_mga.dds"], "the plain texture goes where old textures are looked for")
local lights = read("DST/content/res/models/material/vehicle/waggon/old_lights.mtl")
assert(lights.params.map_emissive.fileName == "converter/missing_dark.dds" and written["DST/content/res/textures/converter/missing_dark.dds"], "a texture that is not in the mod is replaced by a plain one")
assert(written["DST/conversion_report.txt"]:find("texture models/vehicle/stock_lights.tga (material vehicle/waggon/old_lights.mtl); a plain dark texture stands in", 1, true))
assert(read("DST/content/res/models/mesh/vehicle/waggon/old/body.msh").subMeshes[1].materials == nil)
assert(copied["DST/content/res/textures/models/vehicle/waggon/red.dds"] and copied["DST/content/res/models/mesh/vehicle/waggon/old/body.msh.blob"])
assert(copied["DST/content/res/config/something.lua"] == "res/config/something.lua", "other files of the old layout are carried over")
assert(copied["DST/content/res/models/model/vehicle/waggon/Old_Wagon.mdl"] == nil, "a converted model is not overwritten by its original")
assert(copied["DST/content/res/scripts/wagon_seats.lua"] == nil, "the mod's scripts are not: their results are in the models")
assert(written["DST/content/vehicle/waggon/old_wagon.mdl"] == nil and written["DST/res/models/model/vehicle/waggon/Old_Wagon.mdl"] == nil, "nothing is written outside content/res")
assert(written["DST/conversion_report.txt"]:find("Carried over unchanged", 1, true))
assert(written["DST/content/vehicle/waggon/Old_Wagon.mu.lua"] == nil and legacy.metadata.transportVehicle.multipleUnitOnly == nil, "an unpowered wagon is not a multiple unit")

-- 10. a powered vehicle that carries passengers is listed as a multiple unit; levels of detail are put in order
C.layout = "content"
local wagon = source["res/models/model/vehicle/waggon/Old_Wagon.mdl"]
local railcarText = wagon:gsub("railVehicle = { topSpeed = 90,", 'railVehicle = { engines = { { type = "DIESEL", power = 300, tractiveEffort = 40 } }, topSpeed = 90,')
-- a second, far level of detail written first, with its own settings entry first
railcarText = railcarText:gsub("lods = {\n", 'lods = {\n\t\t{ children = {}, static = false, visibleFrom = 500, visibleTo = 2000 },\n', 1)
railcarText = railcarText:gsub('configs = { { axles', 'configs = { { tag = "far" }, { tag = "near", axles', 1)
source["res/models/model/vehicle/train/Railcar.mdl"] = railcarText
written, copied = {}, {}
C.convertMod(host, "SRC", "DST", "Old Wagon_1")
local unit = read("DST/content/vehicle/train/railcar.mu.lua")
assert(#unit.vehicles == 1 and unit.vehicles[1].name == "railcar.mdl" and unit.vehicles[1].forward == true and unit.filterTags[1] == "default")
assert(written["DST/content/vehicle/train/railcar.mu.lua"]:find('name = _("wagon_name")', 1, true), "the unit takes the model's name, as a translation call")
local railcar = read("DST/content/vehicle/train/railcar.mdl")
assert(railcar.metadata.transportVehicle.multipleUnitOnly == true, "and the model leaves the single-vehicle lists")
assert(#railcar.lods == 2 and railcar.lods[1].visibleTo == 500 and railcar.lods[2].visibleTo == 2000, "levels of detail are in rising order")
assert(railcar.metadata.railVehicle.configs[1].tag == "near" and railcar.metadata.railVehicle.configs[2].tag == "far", "and the per-level settings moved with them")
source["res/models/model/vehicle/train/Railcar.mdl"] = nil

print("converter test: ALL OK")
