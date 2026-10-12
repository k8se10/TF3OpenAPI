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
assert(default and #default == 128 + 64 + 16 + 4 and default:sub(1, 4) == "DDS ", "the plain texture is a 4x4 uncompressed DDS with its two smaller levels")
assert(written["DST/content/textures/converter/default_normal.dds"] == nil, "only the plain textures that are used are written")
assert(copied["DST/content/textures/models/vehicle/waggon/red.dds"] == "res/textures/models/vehicle/waggon/red.dds")
local cache = read("DST/texture_metadata_cache.lua")
local listed = cache["textures/models/vehicle/waggon/red.dds"]
assert(listed.channels == 4 and listed.extent[1] == 256 and listed.extent[2] == 128 and listed.numMipmaps == 9 and listed.numStrippedMipmaps == 0, "the texture list has each texture's size and mip levels")
assert(cache["textures/converter/default_mga.dds"].extent[1] == 4 and cache["textures/converter/default_mga.dds"].numMipmaps == 3)
assert(cache["textures/models/vehicle/waggon/glass.tga"] == nil, "a texture it cannot read the size of is left out of the list")

-- 6. the model that already was a tree: only its references move
local new = read("DST/content/vehicle/waggon/new_wagon.mdl")
local part = new.lods[1].node.children[1]
assert(part.mesh == "/models/mesh/vehicle/waggon/old/body.msh" and part.materials[2] == "/models/material/converter/missing.mtl", "a material that is not in the mod gets a plain stand-in")
assert(read("DST/content/models/material/converter/missing.mtl").type == "PHYSICAL" and written["DST/content/textures/converter/missing_grey.dds"])
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
assert(text:find("Models: 2 (1 of them in the old group form)   Meshes: 4   Materials: 4   Textures: 4", 1, true), text)
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
assert(lights.params.map_emissive.fileName == "converter/missing_light.dds" and written["DST/content/res/textures/converter/missing_light.dds"], "a texture that is not in the mod is replaced by a plain one")
assert(written["DST/conversion_report.txt"]:find("texture models/vehicle/stock_lights.tga (material vehicle/waggon/old_lights.mtl); a plain lamp-coloured texture stands in", 1, true))
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

-- 11. sound sets: the old update function is followed and written as curves and built-in behaviours
C.layout = "content"
source["res/config/sound_set/wagon_sound.lua"] = [[
local soundeffectsutil = require "soundeffectsutil"
function data()
return {
	tracks = {
		{ name = "vehicle/wagon/idle.wav", refDist = 8.0 },
		{ name = "vehicle/wagon/drive.wav", refDist = 12.5 },
		{ name = "vehicle/train/wheels_ringing1.wav", refDist = 12.5 },
		{ name = "vehicle/train_gone/_brakes.wav", refDist = 10.0 },
		{ name = "vehicle/wagon/not_there.wav", refDist = 10.0 },
	},
	events = {
		clacks = { names = { "vehicle/clack/modern/part_1.wav", "vehicle/clack/modern/part_2.wav" }, refDist = 2.8 },
		openDoors = { names = { "vehicle/wagon/open.wav" }, refDist = 10.0 },
		whistle = { names = { "vehicle/wagon/open.wav" }, refDist = 10.0 },
	},
	updateFn = function(input)
		return {
			tracks = {
				{ gain = 1.0, pitch = 1.0 },
				{ gain = soundeffectsutil.sampleCurve({ { 0.0, 0.0 }, { 0.2, 0.0 }, { 1.0, 1.0 } }, input.power01), pitch = input.speed01 },
				soundeffectsutil.squeal(input.speed, input.sideForce, input.maxSideForce),
				soundeffectsutil.brake(input.speed, input.brakeDecel, 0.3),
				{ gain = 1.0, pitch = 1.0 },
			},
			events = {
				clacks = soundeffectsutil.clacks(input.speed, input.weight, input.numAxles, 6.0, input.gameSpeedUp),
				openDoors = { gain = 1.0, pitch = 1.0 },
			},
		}
	end,
}
end]]
source["res/audio/effects/vehicle/wagon/idle.wav"] = "WAV1"
source["res/audio/effects/vehicle/wagon/Drive.wav"] = "WAV2"
source["res/audio/effects/vehicle/wagon/open.wav"] = "WAV3"
source["res/models/model/vehicle/waggon/Old_Wagon.mdl"] = source["res/models/model/vehicle/waggon/Old_Wagon.mdl"]:gsub("railVehicle = { topSpeed = 90,", 'railVehicle = { soundSet = "wagon_sound", topSpeed = 90,', 1)
written, copied = {}, {}
local soundReport = C.convertMod(host, "SRC", "DST", "Old Wagon_1")
local withSound = read("DST/content/vehicle/waggon/old_wagon.mdl")
assert(withSound.metadata.soundConfig.soundSet.name == "/sound_set/wagon_sound.snd" and withSound.metadata.railVehicle.soundSet == nil, "the model points at the converted sound set")
local snd = assert(written["DST/content/sound_set/wagon_sound.snd.lua"], "the sound set is written")
local function has(part) assert(snd:find(part, 1, true), "missing from the sound set: " .. part .. "\n" .. snd) end
has('require "::/scripts/soundsetutil.lua"')
has('soundsetutil.addTrackParam01(data, "/audio/effects/vehicle/wagon/idle.wav", 8, { { 0, 1 }, { 1, 1 } }, { { 0, 1 }, { 1, 1 } }, { "vehicle", "speed01" }, { "vehicle", "speed01" })')
has('soundsetutil.addTrackParam01(data, "/audio/effects/vehicle/wagon/drive.wav", 12.5, { { 0, 0 }, { 0.2, 0 }, { 1, 1 } }, { { 0, 0 }, { 1, 1 } }, { "vehicle", "power01" }, { "vehicle", "speed01" })')
has('soundsetutil.addTrackSqueal(data, "::/vehicle/train/shared/sound/train/wheels_ringing1.wav", 12.5)')
has('soundsetutil.addTrackBrake(data, "::/vehicle/train/shared/sound/train_electric_modern/_brakes.wav", 10, 0.3)')
has('soundsetutil.addEventClacks(data, { "::/vehicle/train/shared/sound/clack/modern/part_1.wav", "::/vehicle/train/shared/sound/clack/modern/part_2.wav" }, 2.8, 6000)')
has('soundsetutil.addEvent(data, "openDoors", { "/audio/effects/vehicle/wagon/open.wav" }, 10)')
assert(not snd:find("not_there", 1, true) and not snd:find("whistle", 1, true))
assert(copied["DST/content/audio/effects/vehicle/wagon/drive.wav"] == "res/audio/effects/vehicle/wagon/Drive.wav", "the mod's own sound files come along")
assert(soundReport.text:find("sound vehicle/wagon/not_there.wav is not in the mod and has no stand-in", 1, true) and soundReport.text:find("event whistle left out", 1, true))
assert(not soundReport.text:find("res/config/sound_set/wagon_sound.lua\n", 1, true), "a converted sound set is not listed as left over")
-- the file is real Lua for the newer game: run it against a stand-in for the game's helper
do
	local calls = {}
	local helper = setmetatable({ makeSoundSet = function() return {} end }, { __index = function(_, name) return function(...) calls[#calls + 1] = name end end })
	local chunk = assert(loadstring and loadstring(snd) or load(snd))
	local env = setmetatable({ require = function() return helper end }, { __index = _G })
	if setfenv then setfenv(chunk, env) else chunk = load(snd, "snd", "t", env) end
	chunk()
	assert(type(env.data()) == "table" and #calls == 6, "the written sound set runs: " .. #calls .. " calls")
end

-- 12. light sources at the lamps, and the side-view pictures beside the model
do
	-- 32-bit floats, little-endian, for the few values the lamp mesh needs
	local floats = { [0] = "\0\0\0\0", [1] = "\0\0\128\63", [-1] = "\0\0\128\191", [0.5] = "\0\0\0\63", [1.5] = "\0\0\192\63" }
	local function point(x, y, z) return floats[x] .. floats[y] .. floats[z] end
	-- one lamp each side of the centre line, 1.5 m up, at the mesh's own origin lengthways
	local blob = "pad!" .. point(0, 1, 1.5) .. point(0, -1, 1.5) .. point(0.5, 1, 1.5) .. point(0.5, -1, 1.5)
	C.layout = "content"
	source["res/models/mesh/vehicle/waggon/old/lamps.msh"] = [[function data() return { matConfigs = { { 0 } },
		subMeshes = { { indices = {}, materials = { "vehicle/waggon/old_lights.mtl" } } },
		vertexAttr = { position = { count = 48, numComp = 3, offset = 4 } } } end]]
	source["res/models/mesh/vehicle/waggon/old/lamps.msh.blob"] = blob
	-- a front group 8 m ahead and a back group 8 m behind, turned half round, each holding the lamp mesh
	source["res/models/group/vehicle/waggon/old/end.grp"] = [[function data() return {
		children = { { id = "vehicle/waggon/old/lamps.msh", type = "MESH", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } } },
		matConfigs = { { 0 } } } end]]
	source["res/models/model/vehicle/train/Lit.mdl"] = [[function data() return {
		lods = { {
			children = {
				{ id = "vehicle/waggon/old/end.grp", type = "GROUP", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 8, 0, 0, 1 } },
				{ id = "vehicle/waggon/old/end.grp", type = "GROUP", transf = { -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, -8, 0, 0, 1 } },
			},
			matConfigs = { { 0, 0 } }, static = false, visibleFrom = 0, visibleTo = 500,
		} },
		metadata = { description = { name = "Lit" }, transportVehicle = { carrier = "RAIL" }, railVehicle = { topSpeed = 90 } },
	} end]]
	-- a real picture header this time: 84 x 20, 32 bits
	local tga = string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 84, 0, 20, 0, 32, 0) .. "pixels"
	source["res/textures/ui/models_20/vehicle/train/lit.tga"] = tga
	written, copied = {}, {}
	local litReport = C.convertMod(host, "SRC", "DST", "Old Wagon_1")
	local lit = read("DST/content/vehicle/train/lit.mdl")
	local lights = lit.metadata.lightSourceList.lights
	assert(#lights == 4, "two beams at each end: " .. #lights)
	local function near(a, b) return math.abs(a - b) < 1e-6 end
	local head, tail = lights[1], lights[3]
	assert(head.meshId == "lamps" and tail.meshId == "lamps_2", "each light is tied to its lamp node")
	assert(head.type == "SPOT" and head.radius == 25 and head.fromTime == 18 and head.toTime == 7, "headlights, at night")
	assert(tail.radius == 5 and tail.color[1] > tail.color[2] * 5, "red lights at the back")
	assert(tail.fromTime == 0 and tail.toTime == 24, "rear lights are lit round the clock")
	-- placed at the lamps, in the node's own space: mid-way between the two points of that side
	assert(near(head.transf[13], 0.25) and near(math.abs(head.transf[14]), 1) and near(head.transf[15], 1.5), "a headlight sits at its lamp")
	assert(head.transf[14] * lights[2].transf[14] < 0, "one each side")
	-- the front node is not turned: its beam points along +x and a little down
	assert(near(head.transf[1], math.cos(math.rad(10))) and near(head.transf[3], -math.sin(math.rad(10))), "the headlight points forward and down")
	-- the back node is turned half round, so "backwards in the model" is +x in the node's own space
	assert(near(tail.transf[1], math.cos(math.rad(15))) and near(tail.transf[3], -math.sin(math.rad(15))), "the rear light points backward, seen from its turned node")
	assert(lit.lods[1].node.children[1].children[1].oldMesh == nil, "no working notes are left in the model")
	-- the lamp picture is not in the mod: the front lamps keep the stand-in material, the rear ones get its red twin
	assert(lit.lods[1].node.children[1].children[1].materials[1] == "/models/material/vehicle/waggon/old_lights.mtl")
	assert(lit.lods[1].node.children[2].children[1].materials[1] == "/models/material/vehicle/waggon/old_lights_rear.mtl", "rear lamps glow red")
	-- lamps the old model left on all the time are switched: head lamps when their end leads, rear lamps at the tail
	local headLamp, rearLamp = lit.lods[1].node.children[1].children[1], lit.lods[1].node.children[2].children[1]
	assert(headLamp.animations.front_forward_parts_on.params.id == "::/vehicle/shared/ani/front_forward_parts_on.ani" and headLamp.animations.front_forward_parts_off)
	assert(rearLamp.animations.back_forward_parts_on and rearLamp.animations.front_forward_parts_on == nil)
	local rear = read("DST/content/models/material/vehicle/waggon/old_lights_rear.mtl")
	assert(rear.type == "EMISSIVE" and rear.params.map_emissive.fragmentSamplers.emissiveTex.fileName == "/textures/converter/lamp_red.dds" and written["DST/content/textures/converter/lamp_red.dds"])
	assert(litReport.text:find("4 light sources placed at its lamps", 1, true))
	-- the side view goes beside the model, with its blank colour mask, and into the texture list
	assert(copied["DST/content/vehicle/train/icons/lit_icon20.tga"] == "res/textures/ui/models_20/vehicle/train/lit.tga")
	local mask = written["DST/content/vehicle/train/icons/lit_icon20_cblend.tga"]
	assert(mask and #mask == 18 + 84 * 20 and mask:byte(3) == 3 and mask:byte(17) == 8, "a one-channel mask of the same size")
	local cache = read("DST/texture_metadata_cache.lua")
	assert(cache["vehicle/train/icons/lit_icon20.tga"].extent[1] == 84 and cache["vehicle/train/icons/lit_icon20_cblend.tga"].channels == 1)
	assert(copied["DST/content/textures/ui/models_20/vehicle/train/lit.tga"] == nil, "and is not copied a second time as a texture")
	assert(litReport.text:find("model vehicle/waggon/new_wagon.mdl: the mod has no side%-view pictures for it"), "a vehicle without pictures is said so")
end

-- 13. the stand-in for a stock lamp of the older games: a small disc the mesh reader can read back
do
	local text, blob = C.lampMesh(0.09, 12, 0.25, 0.75, 0.2)
	local d = assert(C.readData(text, "lamp.msh"))
	local pts = C.meshPoints(d, blob)
	assert(#pts == 13 and math.abs(pts[2][2] - 0.09) < 1e-6 and math.abs(pts[2][1]) < 1e-9 and math.abs(pts[5][3] - 0.09) < 1e-6, "a disc in the y-z plane")
	local i = d.subMeshes[1].indices
	assert(i.position.count == 12 * 2 * 3 * 4 and i.position.offset + i.position.count == #blob, "both faces; the index lists fill the rest of the blob")
	assert(d.vertexAttr.uv0.count == 13 * 8 and i.uv0.count == i.position.count, "a texture point per corner")
	-- the texture points go round the chosen spot on the texture: read them back like positions
	local uvs = C.meshPoints({ vertexAttr = { position = { count = 13 * 8, numComp = 2, offset = 0 } } }, blob)
	assert(#uvs == 0, "(the point reader wants three numbers a point)")
	-- a tree model that uses a stock lamp gets the disc, a glowing material and a light source
	C.layout = "content"
	source["res/models/model/vehicle/train/Lamped.mdl"] = [[function data() return {
		lods = { { node = { children = {
			{ mesh = "vehicle/asset/lod_0_light_round_white.msh", materials = { "vehicle/asset/lights.mtl" }, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 9, 1, 2, 1 } },
			{ mesh = "vehicle/asset/lod_0_light_round_red.msh", materials = { "vehicle/asset/lights.mtl" }, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 9, -1, 2, 1 } },
			{ mesh = "vehicle/asset/some_other_stock_part.msh", materials = { "vehicle/asset/lights.mtl" }, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } },
		}, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } }, static = false, visibleFrom = 0, visibleTo = 800 } },
		metadata = { transportVehicle = { carrier = "RAIL", groupFileName = "vehicle/train/never_there.mdl" },
			railVehicle = { topSpeed = 40, configs = { { frontForwardParts = { 1 }, backBackwardParts = { 2 }, brakeLights = { }, axles = { } } } } },
		version = 1 } end]]
	written, copied = {}, {}
	local lampReport = C.convertMod(host, "SRC", "DST", "Old Wagon_1")
	local lamped = read("DST/content/vehicle/train/lamped.mdl")
	local parts = lamped.lods[1].node.children
	assert(parts[1].mesh == "/models/mesh/converter/lamp_white.msh" and parts[1].name == "converter_lamp_1" and parts[1].standIn == nil)
	assert(parts[1].materials[1] == "::/vehicle/train/emissive/train_all_lights.mtl", "a rail vehicle's lamp uses the newer game's own lamp material")
	assert(parts[2].mesh == "/models/mesh/converter/lamp_red.msh" and parts[2].materials[1] == "::/vehicle/train/emissive/train_red_lights.mtl")
	assert(parts[3].mesh == nil and parts[3].materials == nil, "another stock part is left empty in its place")
	assert(written["DST/content/models/mesh/converter/lamp_white.msh.blob"] and written["DST/content/models/mesh/converter/lamp_red.msh.blob"])
	assert(written["DST/content/models/material/converter/lamp_red.mtl"] == nil, "and needs no material of its own")
	local lights = lamped.metadata.lightSourceList.lights
	assert(#lights == 2 and lights[1].meshId == "converter_lamp_1" and lights[1].radius == 25 and lights[2].radius == 5, "a headlight at the white lamp, a rear light at the red one")
	assert(lamped.metadata.transportVehicle.groupFileName == nil and lampReport.text:find("its variant group vehicle/train/never_there.mdl is not a model of the mod", 1, true))
	-- the white lamp shows at the front going forward, the red one at the back going backward: as animations on the parts
	local on = parts[1].animations.front_forward_parts_on
	assert(on.type == "FILE_REF" and on.params.id == "::/vehicle/shared/ani/front_forward_parts_on.ani" and parts[1].animations.front_forward_parts_off, "the head lamp is switched by direction")
	assert(parts[2].animations.back_backward_parts_on and parts[2].animations.front_forward_parts_on == nil and parts[3].animations == nil)
	assert(lamped.metadata.maintenance.lifespan == 29220, "a vehicle with no lifespan of its own gets a usual one")
	local config = lamped.metadata.railVehicle.configs[1]
	assert(config.frontForwardParts == nil and config.backBackwardParts == nil and config.axles ~= nil, "the old lists are used up; the rest stays")
	assert(lampReport.text:find("2 parts set to show by the vehicle's state", 1, true))
	source["res/models/model/vehicle/train/Lamped.mdl"] = nil
end

-- 14. where the host can make mip levels, a .tga texture becomes a .dds and its material follows
do
	C.layout = "content"
	local made = {}
	host.makeMips = function(from, to) made[to] = from:sub(5) return 64, 32, 7 end
	written, copied = {}, {}
	local mipReport = C.convertMod(host, "SRC", "DST", "Old Wagon_1")
	host.makeMips = nil
	assert(made["DST/content/textures/models/vehicle/waggon/glass.dds"] == "res/textures/models/vehicle/waggon/glass.tga")
	assert(copied["DST/content/textures/models/vehicle/waggon/glass.tga"] == nil, "the .tga itself is not carried over as well")
	local glass = read("DST/content/models/material/vehicle/waggon/old_glass.mtl")
	assert(glass.params.map_albedo_opacity.fragmentSamplers.albedoOpacityTex.fileName == "/textures/models/vehicle/waggon/glass.dds")
	local listed = read("DST/texture_metadata_cache.lua")["textures/models/vehicle/waggon/glass.dds"]
	assert(listed.extent[1] == 64 and listed.numMipmaps == 7)
	for path in pairs(made) do assert(not path:find("/icons/", 1, true) and not path:find("/ui/", 1, true), "side-view pictures are left as they are") end
	assert(mipReport.text:find(".tga textures written as .dds with mip levels", 1, true))
end

-- A kind of track of the older games: one file becomes a style and two templates
do
	local old = assert(C.readData([[function data()
		local t = {}
		t.name = _("Slab track")
		t.desc = _("Fast")
		t.yearFrom = 1964
		t.shapeWidth = 4.0
		t.shapeStep = 4.0
		t.railBase = 0.38
		t.railHeight = 0.15
		t.speedLimit = 100
		t.cost = 150
		t.ballastMaterial = "mine/bed.mtl"
		t.railMaterial = "track/rail.mtl"
		t.sleeperModel = "railroad/mine/sleeper.mdl"
		t.bumperModel = "railroad/bumper.mdl"
		t.trackStraightModel = { "railroad/mine/2m.mdl", "railroad/gone.mdl" }
		return t
	end]], "slab.lua"))
	local own = { ["railroad/mine/sleeper.mdl"] = true, ["railroad/mine/2m.mdl"] = true, ["mine/bed.mtl"] = true }
	local refs = {
		model = function(name) return own[name] and ("/" .. name) or nil end,
		material = function(name) return own[name] and ("/models/material/" .. name) or nil end,
		icon = function(file) return file == "slab.tga" and "/textures/ui/tracks/slab.tga" or nil end,
	}
	local style, plain, wired = C.trackFiles(old, "slab", refs)
	assert(style.sleeperModel == "/railroad/mine/sleeper.mdl", "the mod's own model is named as the mod's")
	assert(style.bumperModel == "::/infrastructure/track/high_speed/bumper_high_speed.mdl", "a model of the older game: the newer game's stands in")
	assert(#style.trackStraightModel == 1 and style.trackStraightModel[1] == "/railroad/mine/2m.mdl", "a straight piece that is not there is left out")
	assert(style.materials.ballast.name == "/models/material/mine/bed.mtl" and style.materials.ballast.size[1] == 4)
	assert(style.materials.railMaterial == "::/infrastructure/track/shared/mat/rail_tileable.mtl")
	assert(plain.streetStyle == "/track/slab.street" and wired.streetStyle == "/track/slab.street")
	assert(plain.catenaryAdd == "/track/slab_catenary.street_template" and wired.catenaryRemove == "/track/slab.street_template")
	assert(plain.laneConfigs[1].speed == 100 and math.abs(plain.laneConfigs[1].height - 0.53) < 1e-6)
	assert(#plain.laneConfigs[1].transportModes == 2 and #wired.laneConfigs[1].transportModes == 4, "only the wired form takes electric trains")
	assert(plain.cost == 540 and plain.availability.yearFrom == 1964)
	assert(wired.description.icon == "/textures/ui/tracks/slab.tga", "no picture of its own for the wired form: the plain one")
	local text = C.dataFileText(plain)
	assert(text:find('name = _("Slab track")', 1, true), "the name stays a text to be translated")
	assert(C.dataFileText(wired):find('"Slab track (catenary)"', 1, true))
end

-- A remaster: changes for one particular mod, made to the model before the general rules run
do
	local data = { metadata = { railVehicle = { engines = { { type = "DIESEL", power = 470 } } } } }
	local label = { type = "NEXT_STOP", size = { 0.9, 0.16 }, transf = { 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 13, 0, 3, 1 } }
	C.remasterModel(data, { { engineType = "ELECTRIC" }, { labels = { label } } })
	assert(data.metadata.railVehicle.engines[1].type == "ELECTRIC" and data.metadata.railVehicle.engines[1].power == 470)
	assert(#data.metadata.labelList.labels == 1 and data.metadata.labelList.labels[1] ~= label, "the label is a copy: the remaster's own table is not changed by the rules")
	assert(data.metadata.labelList.labels[1].size[1] == 0.9)
end

print("converter test: ALL OK")
