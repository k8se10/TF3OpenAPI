-- Converts a Train Fever / Transport Fever 1 / Transport Fever 2 mod folder into a Transport Fever 3 mod folder.
--
-- Pure rules: every file operation goes through a "host" table, so the same code runs inside the native layer
-- at launch, from the command line, and in the offline test. The source folder is only ever read.
--
--   host.list(root)          -> array of file paths relative to root, with forward slashes
--   host.read(path)          -> the file's contents, or nil
--   host.readHead(path, n)   -> the first n bytes, or nil
--   host.write(path, text)
--   host.copy(from, to)
--   host.resource(name)      -> the text of a file that ships with the converter (station_shim.lua). Optional.
--   host.makeMips(from, to)  -> width, height, levels: writes the picture "from" (a .tga) as a .dds with every
--                               smaller copy of itself; nothing returned when it cannot. Optional.
--
-- Written for Lua 5.1 to 5.4.

local C = { version = "0.3" }

-- Where the result goes.
--   "content": Transport Fever 3's own layout, model version and material form. What a mod is converted to.
--   "legacy":  the older games' own layout (res/models/..., res/textures/...), placed below content/, with models
--              in the node-tree form (version 1). The game's model importer takes a model whose path below
--              content/ starts with res/models/model/ as an old one and accepts it (build 40408, ModelRep.cpp,
--              "legacyLocation || version >= 2"). Such a model is listed in the game, with its metadata
--              upgraded, but the game stops when the vehicle is first put on a line (the renderer finds its
--              model id beyond its model data): the location looks made for the Model Editor to read old
--              models, not for playing with them. Kept for that finding and for comparison; not used.
C.layout = "content"

-- ---------------------------------------------------------------------------------------------------------
-- small helpers

local function lowerPath(p) return (p:gsub("\\", "/"):lower()) end

local function startsWith(s, prefix) return s:sub(1, #prefix) == prefix end

local function endsWith(s, suffix) return suffix == "" or s:sub(-#suffix) == suffix end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta == "number" end
		return a < b
	end)
	return keys
end

local stubs = setmetatable({}, { __mode = "k" })   -- values that came out of a library the converter does not have
local stockLamp   -- defined with the lamp stand-in, further down

local function copyValue(v)
	if type(v) ~= "table" or stubs[v] then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copyValue(x) end
	return setmetatable(out, getmetatable(v))
end

-- ---------------------------------------------------------------------------------------------------------
-- reading old files: they are Lua programs ("function data() return { ... } end")

local Translated = {}   -- metatable of a _("KEY") value, so that it can be written back as _("KEY")
Translated.__concat = function(a, b)
	local function text(x) return getmetatable(x) == Translated and x.key or tostring(x) end
	return text(a) .. text(b)
end

local function makeStub()
	local stub = {}
	stubs[stub] = true
	return setmetatable(stub, {
		__index = function() return makeStub() end,
		__call = function() return makeStub() end,
		__concat = function() return "" end,
	})
end

local function loadChunk(text, name, env)
	if setfenv then
		local fn, err = loadstring(text, "=" .. name)
		if not fn then return nil, err end
		setfenv(fn, env)
		return fn
	end
	return load(text, "=" .. name, "t", env)
end

-- Old files were written for older Lua versions and lean on the older games' script libraries.
local oldMath = {}
for k, v in pairs(math) do oldMath[k] = v end
oldMath.pow = oldMath.pow or function(a, b) return a ^ b end
oldMath.atan2 = oldMath.atan2 or function(y, x) return math.atan(y, x) end
oldMath.mod = oldMath.mod or math.fmod
oldMath.log10 = oldMath.log10 or function(x) return math.log(x) / math.log(10) end
oldMath.cosh = oldMath.cosh or function(x) return (math.exp(x) + math.exp(-x)) / 2 end
oldMath.sinh = oldMath.sinh or function(x) return (math.exp(x) - math.exp(-x)) / 2 end
oldMath.tanh = oldMath.tanh or function(x) return oldMath.sinh(x) / oldMath.cosh(x) end
oldMath.clamp = oldMath.clamp or function(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local oldTable = {}
for k, v in pairs(table) do oldTable[k] = v end
oldTable.getn = oldTable.getn or function(t) return #t end
oldTable.unpack = oldTable.unpack or unpack
local oldString = {}
for k, v in pairs(string) do oldString[k] = v end
oldString.gfind = oldString.gfind or string.gmatch
oldString.starts = function(s, prefix) return s:sub(1, #prefix) == prefix end
oldString.ends = function(s, suffix) return suffix == "" or s:sub(-#suffix) == suffix end

-- The vector and transform libraries of the older games, written here from their conventions: a transform is
-- 16 numbers, the first three fours being the images of the x, y and z axes and the last the translation;
-- angles are radians, given in the order "about z, about y, about x".
local function vec3Library()
	local V = {}
	local meta = {}
	function V.new(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, meta) end
	function V.add(a, b) return V.new(a.x + b.x, a.y + b.y, a.z + b.z) end
	function V.sub(a, b) return V.new(a.x - b.x, a.y - b.y, a.z - b.z) end
	function V.mul(f, v) if type(f) == "table" then f, v = v, f end return V.new(f * v.x, f * v.y, f * v.z) end
	function V.div(v, d) return V.new(v.x / d, v.y / d, v.z / d) end
	function V.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
	function V.cross(a, b) return V.new(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
	function V.length(v) return math.sqrt(V.dot(v, v)) end
	function V.distance(a, b) return V.length(V.sub(a, b)) end
	function V.normalize(v) local l = V.length(v) return l > 0 and V.div(v, l) or V.new(v.x, v.y, v.z) end
	function V.toArray(v) return { v.x, v.y, v.z } end
	function V.fromArray(t) return V.new(t[1], t[2], t[3]) end
	function V.degToRad(a, b, c) return V.new(math.rad(a or 0), math.rad(b or 0), math.rad(c or 0)) end
	meta.__add, meta.__sub, meta.__mul, meta.__div = V.add, V.sub, V.mul, V.div
	meta.__unm = function(v) return V.new(-v.x, -v.y, -v.z) end
	return V
end

local function transfLibrary(V)
	local T = {}
	local function part(v, name, index) return type(v) == "table" and (v[name] or v[index]) or 0 end
	local function xyz(v) return part(v, "x", 1), part(v, "y", 2), part(v, "z", 3) end
	T.degToRad = V.degToRad
	function T.new(a, b, c, d)   -- four axes / columns, each x, y, z, w
		local out = {}
		for _, col in ipairs({ a, b, c, d }) do
			out[#out + 1] = part(col, "x", 1) out[#out + 1] = part(col, "y", 2)
			out[#out + 1] = part(col, "z", 3) out[#out + 1] = part(col, "w", 4)
		end
		return out
	end
	function T.identity() return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } end
	function T.transl(t) local x, y, z = xyz(t) return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 } end
	function T.scale(s) local x, y, z = xyz(s) return { x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1 } end
	function T.rotZYXTransl(rot, t)
		local a, b, c = xyz(rot)   -- about z, about y, about x
		local sa, ca, sb, cb, sc, cc = math.sin(a), math.cos(a), math.sin(b), math.cos(b), math.sin(c), math.cos(c)
		local x, y, z = xyz(t)
		return {
			cb * ca, cb * sa, -sb, 0,
			sc * sb * ca - cc * sa, sc * sb * sa + cc * ca, sc * cb, 0,
			cc * sb * ca + sc * sa, cc * sb * sa - sc * ca, cc * cb, 0,
			x, y, z, 1,
		}
	end
	function T.rotZYTransl(rot, t) local a, b = xyz(rot) return T.rotZYXTransl({ a, b, 0 }, t) end
	function T.rotZY(rot) return T.rotZYTransl(rot, { 0, 0, 0 }) end
	function T.rotZTransl(angle, t) return T.rotZYXTransl({ angle, 0, 0 }, t) end
	function T.rotZ(angle) return T.rotZYXTransl({ angle, 0, 0 }, { 0, 0, 0 }) end
	function T.rotY(angle) return T.rotZYXTransl({ 0, angle, 0 }, { 0, 0, 0 }) end
	function T.rotX(angle) return T.rotZYXTransl({ 0, 0, angle }, { 0, 0, 0 }) end
	function T.mul(m, n)   -- the transform that does n first, then m
		local out = {}
		for col = 0, 3 do
			for row = 1, 4 do
				local sum = 0
				for k = 0, 3 do sum = sum + m[k * 4 + row] * n[col * 4 + k + 1] end
				out[col * 4 + row] = sum
			end
		end
		return out
	end
	function T.scaleRotZTransl(s, angle, t) return T.mul(T.rotZTransl(angle, t), T.scale({ s, s, s })) end
	function T.scaleXYZRotZTransl(s, angle, t) return T.mul(T.rotZTransl(angle, t), T.scale(s)) end
	function T.scaleRotZYXTransl(s, rot, t) return T.mul(T.rotZYXTransl(rot, t), T.scale(s)) end
	function T.getTransl(m) return V.new(m[13], m[14], m[15]) end
	return T
end
C.vec3 = vec3Library()
C.transf = transfLibrary(C.vec3)

-- returns the table the file's data() gives, or nil and the reason.
-- ctx (optional): { used = {}, resolve = function(lib) -> text of the mod's own script of that name, modules = {} }
function C.readData(text, name, ctx)
	if not text then return nil, "file not found" end
	if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
	ctx = ctx or {}
	ctx.modules = ctx.modules or {}
	local env
	local function requireOld(lib)
		lib = tostring(lib)
		local key = lib:lower():gsub("%.lua$", "")
		if key == "vec3" then return C.vec3 end
		if key == "transf" then return C.transf end
		if ctx.libraries and ctx.libraries[key] then return ctx.libraries[key] end
		if ctx.modules[key] ~= nil then return ctx.modules[key] end
		local source = ctx.resolve and ctx.resolve(key)
		if source then
			ctx.modules[key] = makeStub()   -- while it loads, in case scripts require each other
			local chunk = loadChunk(source, key .. ".lua", env)
			local ok, value = false, nil
			if chunk then ok, value = pcall(chunk) end
			if ok and value ~= nil then
				ctx.modules[key] = value
				return value
			end
			if ctx.used then ctx.used[lib .. " (the mod's own script, which does not run here)"] = true end
			return ctx.modules[key]
		end
		if ctx.used then ctx.used[lib] = true end
		ctx.modules[key] = makeStub()
		return ctx.modules[key]
	end
	env = {
		_ = function(key) return setmetatable({ key = tostring(key) }, Translated) end,
		math = oldMath, string = oldString, table = oldTable, pairs = pairs, ipairs = ipairs, next = next, select = select,
		tostring = tostring, tonumber = tonumber, type = type, unpack = unpack or table.unpack,
		setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset, pcall = pcall,
		error = error, assert = assert, print = function() end,
		require = requireOld,
	}
	env._G = env
	local fn, err = loadChunk(text, name, env)
	if not fn then return nil, "does not parse: " .. tostring(err) end
	local ok, problem = pcall(fn)
	if not ok then return nil, "does not run: " .. tostring(problem) end
	if type(env.data) ~= "function" then
		if type(problem) == "table" then return problem end   -- a file that just returns a table
		return nil, "has no data() function"
	end
	local ok2, result = pcall(env.data)
	if not ok2 then return nil, "data() fails: " .. tostring(result) end
	if type(result) ~= "table" then return nil, "data() does not return a table" end
	return result
end

-- ---------------------------------------------------------------------------------------------------------
-- writing files

local function isArray(t)
	local n = #t
	local count = 0
	for _ in pairs(t) do count = count + 1 end
	return count == n, n
end

local function numberText(v)
	if v ~= v or v == math.huge or v == -math.huge then return "0" end
	if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
	return (string.format("%.9g", v))
end

local function quoted(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n"
		elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
		return string.format("\\%d", c:byte())
	end) .. '"'
end

local function serialize(v, indent, out)
	local tv = type(v)
	if tv == "number" then out[#out + 1] = numberText(v)
	elseif tv == "boolean" then out[#out + 1] = tostring(v)
	elseif tv == "string" then out[#out + 1] = quoted(v)
	elseif tv == "table" then
		if getmetatable(v) == Translated then
			out[#out + 1] = "_(" .. quoted(v.key) .. ")"
			return
		end
		local array, n = isArray(v)
		local flat = array
		if array then
			for i = 1, n do if type(v[i]) ~= "number" then flat = false break end end
		end
		if flat then
			out[#out + 1] = "{ "
			for i = 1, n do out[#out + 1] = numberText(v[i]) .. ", " end
			out[#out + 1] = "}"
			return
		end
		local inner = indent .. "\t"
		out[#out + 1] = "{\n"
		if array then
			for i = 1, n do
				if not stubs[v[i]] then
					out[#out + 1] = inner
					serialize(v[i], inner, out)
					out[#out + 1] = ",\n"
				end
			end
		else
			for _, k in ipairs(sortedKeys(v)) do
				local x = v[k]
				if not stubs[x] and type(x) ~= "function" and (type(k) == "string" or type(k) == "number") then
					out[#out + 1] = inner
					if type(k) == "string" and k:match("^[%a_][%w_]*$") then out[#out + 1] = k .. " = "
					elseif type(k) == "string" then out[#out + 1] = "[" .. quoted(k) .. "] = "
					else out[#out + 1] = "[" .. numberText(k) .. "] = " end
					serialize(x, inner, out)
					out[#out + 1] = ",\n"
				end
			end
		end
		out[#out + 1] = indent .. "}"
	else
		out[#out + 1] = "nil"
	end
end

function C.dataFileText(data)
	local out = { "function data()\nreturn " }
	serialize(data, "", out)
	out[#out + 1] = "\nend\n"
	return table.concat(out)
end

local function jsonText(v, indent, out)
	local tv = type(v)
	if tv == "table" and getmetatable(v) == Translated then v, tv = v.key, "string" end
	if tv == "number" then out[#out + 1] = numberText(v)
	elseif tv == "boolean" then out[#out + 1] = tostring(v)
	elseif tv == "string" then
		out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
			if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n"
			elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
			return string.format("\\u%04x", c:byte())
		end) .. '"'
	elseif tv == "table" then
		local array, n = isArray(v)
		local inner = indent .. "    "
		if array and n > 0 then
			out[#out + 1] = "[\n"
			for i = 1, n do
				out[#out + 1] = inner
				jsonText(v[i], inner, out)
				out[#out + 1] = (i < n) and ",\n" or "\n"
			end
			out[#out + 1] = indent .. "]"
		else
			local keys = {}
			for _, k in ipairs(sortedKeys(v)) do
				local tx = type(v[k])
				if type(k) == "string" and (tx == "string" or tx == "number" or tx == "boolean" or tx == "table") and not stubs[v[k]] then
					keys[#keys + 1] = k
				end
			end
			out[#out + 1] = "{\n"
			for i, k in ipairs(keys) do
				out[#out + 1] = inner
				jsonText(k, inner, out)
				out[#out + 1] = ": "
				jsonText(v[k], inner, out)
				out[#out + 1] = (i < #keys) and ",\n" or "\n"
			end
			out[#out + 1] = indent .. "}"
		end
	else
		out[#out + 1] = "null"
	end
end

function C.jsonText(v)
	local out = {}
	jsonText(v, "", out)
	out[#out + 1] = "\n"
	return table.concat(out)
end

-- ---------------------------------------------------------------------------------------------------------
-- where things live: old layout under res/, new layout under content/, new references from the content root

local OLD = {
	model = "res/models/model/",
	mesh = "res/models/mesh/",
	group = "res/models/group/",
	material = "res/models/material/",
	animation = "res/models/animation/",
	texture = "res/textures/",
}
local NEW = {
	model = "",   -- res/models/model/vehicle/train/x.mdl -> content/vehicle/train/x.mdl
	mesh = "models/mesh/",
	material = "models/material/",
	animation = "models/animation/",
	texture = "textures/",
}

local function newRef(kind, id)
	if C.layout == "legacy" then return id end   -- the old layout keeps the old references
	return "/" .. NEW[kind] .. lowerPath(id)
end

-- where a file of the old mod is written in the new one, below the mod's folder
local function newPath(kind, id)
	if C.layout == "legacy" then return "content/" .. OLD[kind] .. id end
	return "content/" .. NEW[kind] .. id
end

-- ---------------------------------------------------------------------------------------------------------
-- materials

-- Transport Fever 3 nests each material parameter: textures under fragmentSamplers.<name>, values under
-- fragmentProperties[1] or vertexProperties[1]. Names as the game defines them (rendering/properties, build 40408).
local SAMPLER = {
	map_albedo = "albedoTex", map_albedo_gloss = "albedoGlossTex", map_albedo_opacity = "albedoOpacityTex",
	map_ao = "aoTex", map_cblend = "cblendTex", map_cblend_dirt_rust = "cblendDirtRustTex", map_color = "colorTex",
	map_dirt = "dirtTex", map_dirt_normal = "dirtNormalTex", map_emissive = "emissiveTex", map_id = "idTex",
	map_lgt = "lightMaskTex", map_metal_gloss_ao = "metalGlossAoTex", map_normal = "normalTex", map_op_1 = "opTex1",
	map_op_2 = "opTex2", map_rust = "rustTex", map_rust_normal = "rustNormalTex",
}
local VERTEX = { billboard = true, billboard2 = true, color = true, fade_out_range = true, fade_out_ranges = true, smooth_lod = true }
local FRAGMENT = {
	albedo_scale = true, albedo_scales = true, alpha_scale = true, alpha_scales = true, alpha_test = true,
	billboard_shadow = true, billboard_shadows = true, color_blend = true, color_blend4 = true, dirt = true,
	dirt_rust = true, emissive_scale = true, light_receiver = true, normal_scale = true, operation = true,
	polygon_offset = true, tex_animation = true, texcoord_scale = true, two_sided = true, window_light_color = true,
}

-- material types Transport Fever 2 dropped, and what stands in for them (what, and which old map is the colour)
local OLD_TYPES = {
	REFLECTIVE = { "PHYSICAL", "map_albedo", "map_color_reflect" },
	REFLECTIVE_OP = { "PHYSICAL", "map_albedo", "map_color_reflect" },
	REFLECTIVE_NRML_MAP = { "PHYSICAL_NRML_MAP", "map_albedo", "map_color_reflect" },
	REFLECTIVE_NRML_MAP_OP = { "PHYSICAL_NRML_MAP", "map_albedo", "map_color_reflect" },
	TRANSPARENT = { "PHYS_TRANSPARENT", "map_albedo_opacity", "map_color_alpha" },
	TRANSPARENT_DETAIL = { "PHYS_TRANSPARENT", "map_albedo_opacity", "map_color_alpha" },
	TRANSPARENT_OP = { "PHYS_TRANSPARENT", "map_albedo_opacity", "map_color_alpha" },
	TRANSPARENT_NRML_MAP = { "PHYS_TRANSPARENT_NRML_MAP", "map_albedo_opacity", "map_color_alpha" },
	TRANSPARENT_NRML_MAP_OP = { "PHYS_TRANSPARENT_NRML_MAP", "map_albedo_opacity", "map_color_alpha" },
	PHYSICAL_ALPHA_NRML_MAP = { "PHYS_TRANSPARENT_NRML_MAP", "map_albedo_opacity", "map_albedo_alpha" },
	PHYSICAL_ALPHA_NRML_MAP_OP = { "PHYS_TRANSPARENT_NRML_MAP", "map_albedo_opacity", "map_albedo_alpha" },
}
local COLOUR_MAPS = { "map_albedo", "map_albedo_alpha", "map_albedo_gloss", "map_albedo_opacity", "map_color_alpha", "map_color_reflect", "map_detail" }

local function u32(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

-- a 4x4 uncompressed texture of one colour, for materials that name no normal or metal/gloss/ambient map
-- (with its smaller copies, 2x2 and 1x1: the newer game wants them on every texture it is to stream)
local function plainTexture(r, g, b)
	local parts = { "DDS ", u32(124), u32(0x2100F), u32(4), u32(4), u32(16), u32(0), u32(3) }
	for _ = 1, 11 do parts[#parts + 1] = u32(0) end
	parts[#parts + 1] = u32(32) .. u32(0x41) .. u32(0) .. u32(32) .. u32(0x00FF0000) .. u32(0x0000FF00) .. u32(0x000000FF) .. u32(0xFF000000)
	parts[#parts + 1] = u32(0x401008) .. u32(0) .. u32(0) .. u32(0) .. u32(0)
	parts[#parts + 1] = string.rep(string.char(b, g, r, 255), 16 + 4 + 1)
	return table.concat(parts)
end
C.defaultTextures = {
	normal = { name = "converter/default_normal.dds", bytes = plainTexture(128, 128, 255) },
	mga = { name = "converter/default_mga.dds", bytes = plainTexture(0, 77, 255) },   -- no metal, some gloss, no shading
	-- for a texture the mod refers to but does not contain (usually a file of the older game itself)
	dark = { name = "converter/missing_light.dds", bytes = plainTexture(255, 236, 200) }, -- an emissive map: a warm lamp
	grey = { name = "converter/missing_grey.dds", bytes = plainTexture(128, 128, 128) }, -- any other map
	lampWhite = { name = "converter/lamp_white.dds", bytes = plainTexture(255, 240, 210) },
	lampRed = { name = "converter/lamp_red.dds", bytes = plainTexture(255, 30, 20) },
}

-- true when a .dds stores a two-channel (red-green) normal map
local function isRedGreen(head)
	if not head or #head < 88 or head:sub(1, 4) ~= "DDS " then return nil end
	local fourCC = head:sub(85, 88)
	if fourCC == "ATI2" or fourCC == "BC5U" then return true end
	if fourCC == "DX10" and #head >= 132 then
		local format = head:byte(129) + head:byte(130) * 256
		return format == 82 or format == 83 or format == 84   -- BC5 typeless / unorm / snorm
	end
	return false
end

-- What the game keeps per texture in a mod's texture_metadata_cache.lua, read from the start of the file:
-- number of channels, size, number of mip levels. Returns nil for a file it cannot read the size of.
function C.textureInfo(name, head)
	local function u16(i) return head:byte(i) + head:byte(i + 1) * 256 end
	local function u32le(i) return u16(i) + u16(i + 2) * 65536 end
	local low = name:lower()
	if endsWith(low, ".dds") and head and #head >= 32 and head:sub(1, 4) == "DDS " then
		return { channels = 4, extent = { u32le(17), u32le(13) }, numMipmaps = math.max(u32le(29), 1), numStrippedMipmaps = 0 }
	elseif endsWith(low, ".tga") and head and #head >= 18 then
		local channels = math.floor(head:byte(17) / 8)
		if channels < 1 then channels = 4 end
		local w, h = u16(13), u16(15)
		if low:find("@2x", 1, true) then w, h = math.floor((w + 1) / 2), math.floor((h + 1) / 2) end   -- listed at their on-screen size
		return { channels = channels, extent = { w, h }, numMipmaps = 1, numStrippedMipmaps = 0 }
	elseif endsWith(low, ".png") and head and #head >= 26 and head:sub(2, 4) == "PNG" then
		local function be(i) return ((head:byte(i) * 256 + head:byte(i + 1)) * 256 + head:byte(i + 2)) * 256 + head:byte(i + 3) end
		local kinds = { [0] = 1, [2] = 3, [3] = 3, [4] = 2, [6] = 4 }
		return { channels = kinds[head:byte(26)] or 4, extent = { be(17), be(21) }, numMipmaps = 1, numStrippedMipmaps = 0 }
	end
	return nil
end

-- job: { host, src, lowerNames = { [lower path] = real path }, report, needDefault = {} }
-- variant "glass": the see-through twin of a cut-out material whose picture holds paint and glass (see below)
function C.convertMaterial(data, id, job, variant)
	local report = job.report
	local params = type(data.params) == "table" and copyValue(data.params) or {}
	local kind = tostring(data.type or "")

	local old = OLD_TYPES[kind]
	if old then
		local colour = params[old[3]]
		if type(colour) ~= "table" then
			for _, name in ipairs(COLOUR_MAPS) do
				if type(params[name]) == "table" then colour = params[name] break end
			end
		end
		for _, name in ipairs(COLOUR_MAPS) do params[name] = nil end
		params[old[2]] = colour
		for name in pairs(params) do
			if name:match("^map_op_") or name:match("^operation") or name == "map_env" or name == "props" then params[name] = nil end
		end
		report.notes[#report.notes + 1] = string.format("material %s: old type %s written as %s", id, kind, old[1])
		kind = old[1]
	end

	if kind == "EMISSIVE" and type(params.emissive_scale) ~= "table" then
		local file = type(params.map_emissive) == "table" and tostring(params.map_emissive.fileName or "") or ""
		local scale = endsWith(file:lower(), ".hdr") and 12 or 45
		params.emissive_scale = { emissiveScale = { scale, scale, scale } }
	end

	if startsWith(kind, "PHYS_TRANSPARENT") then
		-- A material the mod itself marks as cut out (a body side with its window openings, a grille): in the
		-- older game every point was either there or not, at the threshold. The newer game's shader throws away
		-- only what is at or below "a2CThreshold" (nothing, unless it is given) and passes the rest on with its
		-- opacity, which is then drawn as a pattern of dots. Paint is seldom quite 255 in such a picture (240 to
		-- 254 over a whole body side in one mod tried), so the body comes out speckled and see-through. So the
		-- threshold is given as the cut, and the opacity is scaled a little, so that what is nine tenths opaque
		-- or more is solid; glass in the same picture (about 0.7 there) stays see-through.
		local cut = type(params.alpha_test) == "table" and params.alpha_test.cutout == true
		if type(params.alpha_test) ~= "table" then params.alpha_test = { alphaThreshold = 0.5 } end
		params.alpha_test.cutout = true
		if cut then
			local threshold = tonumber(params.alpha_test.alphaThreshold) or 0.5
			-- Paint and glass in one picture (a body side with its windows painted in, the glass about two
			-- thirds opaque): the older game drew such a material without a pattern, the glass evenly thinner
			-- than the paint. The newer game has no such thing in one material; its own trains have the glass
			-- as a part of its own, drawn blended. So the material is written twice: this one draws the paint,
			-- solid, and leaves the glass out; its twin (variant "glass") draws the same picture blended, and
			-- the model gets each such part a second time with the twin (see glassMirror).
			local twin = job and job.glassTwin and job.glassTwin(lowerPath(id))
			if threshold > 0 and threshold < 1 and variant == "glass" then
				params.alpha_test = { alphaThreshold = threshold, cutout = false, sorted = true, disableDepthAndNormalWrite = true }
			elseif threshold > 0 and threshold < 1 then
				if params.alpha_test.a2CThreshold == nil then params.alpha_test.a2CThreshold = twin and C.glassBelow or threshold end
				if type(params.alpha_scale) ~= "table" then params.alpha_scale = {} end
				params.alpha_scale.alphaScale = math.max(tonumber(params.alpha_scale.alphaScale) or 1, 1 / C.solidFrom)
			end
		end
	end

	-- a physical material needs a metal/gloss/ambient map, and a normal-mapped one a normal map
	local function wantDefault(name, which)
		local entry = params[name]
		if type(entry) ~= "table" then entry = { type = "TWOD", wrapS = "REPEAT", wrapT = "REPEAT" } params[name] = entry end
		if tostring(entry.fileName or "") == "" or tostring(entry.fileName) == ".tga" then
			entry.fileName = C.defaultTextures[which].name
			entry.isDefault = true
			job.needDefault[which] = true
			report.notes[#report.notes + 1] = string.format("material %s: no %s named, a plain one is used", id, name)
		end
	end
	if startsWith(kind, "PHYS") and kind ~= "PHYS_TRANSPARENT_DIFFUSE" then
		if not params.map_albedo_gloss then wantDefault("map_metal_gloss_ao", "mga") end
		if kind:find("NRML_MAP", 1, true) then wantDefault("map_normal", "normal") end
	end

	if kind == "EMISSIVE" and type(params.emissive_scale) == "table" then
		local scale = type(params.emissive_scale.emissiveScale) == "table" and params.emissive_scale.emissiveScale or {}
		local r, g, b = tonumber(scale[1]) or 0, tonumber(scale[2]) or 0, tonumber(scale[3]) or 0
		-- A lamp: a glowing material that is red, or that is on a part the vehicle shows by its direction.
		-- The newer game's own lamp materials are lit round the clock (fromTime 0, toTime 24); without the two
		-- values a glowing material follows the time of day, and a rear lamp is dark by day.
		local red = r > 0 and r >= 2 * g and r >= 2 * b
		if (red or (job.lampMaterials and job.lampMaterials[lowerPath(id)])) and params.emissive_scale.fromTime == nil then
			params.emissive_scale.fromTime, params.emissive_scale.toTime = 0, 24
		end
	end

	-- a material whose texture cannot be found may keep the whole model from loading: a plain one stands in
	for _, name in ipairs(sortedKeys(params)) do
		local entry = params[name]
		if type(entry) == "table" and SAMPLER[name] and not entry.isDefault then
			local file = tostring(entry.fileName or "")
			if file ~= "" and not job.lowerNames[lowerPath(OLD.texture .. file)] then
				-- named .dds but shipped as .tga, or the other way round: the older games looked for both
				local stem, ext = file:match("^(.*)%.([^%./]+)$")
				for _, other in ipairs({ "dds", "tga", "png" }) do
					if stem and other ~= (ext or ""):lower() and job.lowerNames[lowerPath(OLD.texture .. stem .. "." .. other)] then
						file = stem .. "." .. other
						entry.fileName = file
						break
					end
				end
			end
			if file ~= "" and not job.lowerNames[lowerPath(OLD.texture .. file)] and job.elsewhere then
				-- a texture of another old mod in the inbox (an add-on mod uses the textures of the mod it adds to)
				local stem, ext = file:match("^(.*)%.([^%./]+)$")
				for _, other in ipairs({ ext or "", "dds", "tga", "png" }) do
					local modId, theirs = job.elsewhere(lowerPath(OLD.texture .. (stem or file) .. "." .. other))
					if modId then
						local theirName = lowerPath((stem or file) .. "." .. other)
						-- that mod's .tga textures are written as .dds with mip levels, as this mod's are
						if other:lower() == "tga" and job.host.makeMips and not startsWith(theirName, "ui/")
							and not theirs.files[OLD.texture .. theirName:gsub("%.tga$", ".dds")] then
							theirName = theirName:gsub("%.tga$", ".dds")
						end
						entry.external = modId .. "::/" .. NEW.texture .. theirName
						break
					end
				end
			end
			if file ~= "" and not job.lowerNames[lowerPath(OLD.texture .. file)] and not entry.external then
				local which = name:find("normal", 1, true) and "normal" or name == "map_metal_gloss_ao" and "mga"
					or name == "map_emissive" and "dark" or "grey"
				if file:lower():match("^default_[%w_]+%.%a+$") or file:lower():match("^unknown_[%w_]+%.%a+$") then
					-- the older game's own "no texture given" textures: nothing is missing from the mod
					report.counts.stockDefaults = (report.counts.stockDefaults or 0) + 1
				else
					report.missing[#report.missing + 1] = string.format("texture %s (material %s); a plain %s texture stands in", file, id, which == "dark" and "lamp-coloured" or which)
				end
				entry.fileName = C.defaultTextures[which].name
				entry.isDefault = true
				job.needDefault[which] = true
			end
		end
	end

	-- A lamp material whose picture is one of the older game's own (not in the mod) glows by a stand-in picture.
	-- The older game's lamp pictures were far brighter than white, and the glow strength was set for them
	-- (0.2 and the like): with a plain picture that strength shows nothing. The colour is kept, the strength
	-- is brought to that of the newer game's own lamp materials (10 to 15).
	if kind == "EMISSIVE" and type(params.map_emissive) == "table" and params.map_emissive.isDefault
		and type(params.emissive_scale) == "table" and type(params.emissive_scale.emissiveScale) == "table" then
		local scale = params.emissive_scale.emissiveScale
		local top = math.max(tonumber(scale[1]) or 0, tonumber(scale[2]) or 0, tonumber(scale[3]) or 0)
		if top > 0 and (top < 3 or top > 40) then
			for i = 1, 3 do scale[i] = (tonumber(scale[i]) or 0) * 12 / top end
		end
	end

	-- ... and likewise one whose own bright picture (.hdr) was written as an ordinary one: the brightness that the
	-- picture no longer carries goes into the glow strength, the colour is kept.
	if kind == "EMISSIVE" and type(params.map_emissive) == "table" and not params.map_emissive.isDefault and job.hdrPeak
		and job.hdrPeak[lowerPath(tostring(params.map_emissive.fileName or ""))]
		and type(params.emissive_scale) == "table" and type(params.emissive_scale.emissiveScale) == "table" then
		local scale = params.emissive_scale.emissiveScale
		local top = math.max(tonumber(scale[1]) or 0, tonumber(scale[2]) or 0, tonumber(scale[3]) or 0)
		if top > 0 then
			for i = 1, 3 do scale[i] = (tonumber(scale[i]) or 0) * 12 / top end
		end
	end

	if C.layout == "legacy" then
		-- the old flat form; the game reads it as an old material
		for _, name in ipairs(sortedKeys(params)) do
			local entry = params[name]
			if type(entry) == "table" and SAMPLER[name] then
				local file = tostring(entry.fileName or "")
				if name:find("normal", 1, true) and not entry.isDefault and endsWith(file:lower(), ".dds") then
					local real = job.lowerNames[lowerPath(OLD.texture .. file)]
					local found = real and isRedGreen(job.host.readHead(job.src .. "/" .. real, 132))
					if found ~= nil then entry.redGreen = found end
				elseif entry.isDefault and name:find("normal", 1, true) then
					entry.redGreen = false
				end
				entry.isDefault = nil
			end
		end
		return { order = tonumber(data.order) or 0, params = params, type = kind }
	end

	local out = {}
	for _, name in ipairs(sortedKeys(params)) do
		local entry = params[name]
		local base = name:gsub("_%d+$", "")
		if type(entry) ~= "table" then
			report.notes[#report.notes + 1] = string.format("material %s: parameter %s is not a table, left out", id, tostring(name))
		elseif SAMPLER[name] then
			local file = tostring(entry.fileName or "")
			if file == "" then
				report.problems[#report.problems + 1] = string.format("material %s: %s names no texture, left out", id, name)
			else
				local sampler = {}
				for k, v in pairs(entry) do
					if type(v) ~= "table" and k ~= "isDefault" and k ~= "external" then sampler[k] = v end
				end
				sampler.fileName = entry.external or newRef("texture", job.mipped and job.mipped[lowerPath(file)] or file)
				if entry.external then
					if name:find("normal", 1, true) then sampler.redGreen = entry.redGreen and true or false end
				elseif name:find("normal", 1, true) then
					local redGreen = entry.redGreen
					if entry.isDefault then
						redGreen = false
					else
						local real = job.lowerNames[lowerPath(OLD.texture .. file)]
						if not real then
							report.missing[#report.missing + 1] = string.format("texture %s (material %s)", file, id)
						elseif endsWith(file:lower(), ".dds") then
							local found = isRedGreen(job.host.readHead(job.src .. "/" .. real, 132))
							if found ~= nil then redGreen = found end
						end
					end
					sampler.redGreen = redGreen and true or false
				elseif not entry.isDefault and not job.lowerNames[lowerPath(OLD.texture .. file)] then
					report.missing[#report.missing + 1] = string.format("texture %s (material %s)", file, id)
				end
				out[name] = { fragmentSamplers = { [SAMPLER[name]] = sampler } }
			end
		elseif VERTEX[name] or VERTEX[base] then
			out[name] = { vertexProperties = { entry } }
		elseif FRAGMENT[name] or FRAGMENT[base] then
			out[name] = { fragmentProperties = { entry } }
		else
			report.notes[#report.notes + 1] = string.format("material %s: parameter %s has no place in Transport Fever 3, left out", id, name)
		end
	end

	-- old textures were painted for the older lighting model
	local receiver = out.light_receiver and out.light_receiver.fragmentProperties[1] or {}
	receiver.isLegacyMaterial = true
	if receiver.lightMask == nil then receiver.lightMask = 2 end
	out.light_receiver = { fragmentProperties = { receiver } }

	return { __version = "", order = tonumber(data.order) or 0, params = out, type = kind }
end

-- ---------------------------------------------------------------------------------------------------------
-- models

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

local function baseName(id)
	local name = id:match("([^/\\]+)$") or id
	return (name:gsub("%.[^%.]*$", ""))
end

-- zero-based configuration indices, as the old files have them, to one-based
local function oneBased(configs)
	local out = {}
	if type(configs) ~= "table" then return out end
	for i, c in ipairs(configs) do
		if type(c) == "table" then
			out[i] = {}
			for j, x in ipairs(c) do out[i][j] = (tonumber(x) or 0) + 1 end
		else
			out[i] = (tonumber(c) or 0) + 1
		end
	end
	return out
end

-- events: for each event, which of the node's animations plays and in which direction.
-- "events" is the group's own table (event -> { [0] = for the group itself, [i] = for child i }),
-- "inherited" what the parent group passed down for this group.
local function eventsFor(index, events, inherited)
	local out = {}
	if type(events) ~= "table" then return out end
	if inherited and next(inherited) ~= nil then
		for event, parent in pairs(inherited) do
			local own = events[parent.name]
			local item = type(own) == "table" and own[index]
			if type(item) == "table" then
				out[event] = { name = item.name, forward = (parent.forward == item.forward) }
			end
		end
	else
		for event, own in pairs(events) do
			local item = type(own) == "table" and own[index]
			if type(item) == "table" then out[event] = { name = item.name, forward = item.forward } end
		end
	end
	return out
end

local function animationsFor(holder, events)
	if type(holder.animations) ~= "table" then return nil end
	local out, found = {}, false
	for event, use in pairs(events) do
		local animation = holder.animations[use.name]
		if type(animation) == "table" then
			animation = copyValue(animation)
			animation.forward = use.forward
			out[event] = animation
			found = true
		end
	end
	return found and out or nil
end

-- Old models (no version): each level of detail is a group of MESH / GROUP children referring to .msh and .grp
-- files; materials sit in the meshes. Result: a node tree with the materials on the nodes.
-- Every child keeps its place in the tree, because the metadata refers to parts by their position.
function C.oldLodToTree(lod, job, modelId)
	local report = job.report
	local counts = {}
	local function uniqueName(id)
		local name = baseName(id)
		counts[name] = (counts[name] or 0) + 1
		return counts[name] == 1 and name or (name .. "_" .. counts[name])
	end
	local position = 0

	local function walk(group, node, index, inherited, chosenConfigs)
		local own = eventsFor(0, group.events, inherited)
		node.animations = animationsFor(group, own)
		local groupConfigs = oneBased(group.matConfigs)
		local configs = groupConfigs[chosenConfigs[index] or 1] or groupConfigs[1] or {}
		for i, child in ipairs(type(group.children) == "table" and group.children or {}) do
			position = position + 1
			local id = tostring(child.id or "")
			local childEvents = eventsFor(i, group.events, inherited)
			local entry = { name = uniqueName(id), transf = child.transf or IDENTITY }
			if child.type == "GROUP" then
				local data, why = job.readOld("group", id)
				entry.children = {}
				if data then
					walk(data, entry, i, childEvents, configs)
				else
					report.missing[#report.missing + 1] = string.format("group %s (model %s): %s", id, modelId, why)
				end
			elseif job.hiddenParts[position] then
				-- a cargo-level mesh of an old load indicator: kept as an empty node so later parts keep their place
				report.notes[#report.notes + 1] = string.format("model %s: cargo display mesh %s left out", modelId, id)
			else
				local mesh, why = job.meshInfo(id)
				if mesh then
					entry.mesh = newRef("mesh", id)
					entry.materials = {}
					entry.oldMesh = id
					local config = mesh.matConfigs[configs[i] or 1] or mesh.matConfigs[1] or {}
					for s, choices in ipairs(mesh.materials) do
						local material = choices[config[s] or 1] or choices[1]
						if material then
							entry.materials[s] = newRef("material", material)
							job.usedMaterials[lowerPath(material)] = true
						end
					end
					entry.animations = animationsFor(mesh, childEvents)
				else
					report.missing[#report.missing + 1] = string.format("mesh %s (model %s): %s", id, modelId, why)
				end
			end
			node.children[#node.children + 1] = entry
		end
	end

	local root = { name = "RootNode", transf = IDENTITY, children = {} }
	walk(lod, root, 1, {}, {})
	-- glowing meshes, with where they sit in the model (for the light sources); the note of the old mesh name goes
	local lamps = {}
	local function find(node, world)
		world = C.transf.mul(world, node.transf or IDENTITY)
		if node.oldMesh then
			local glows = false
			for _, material in ipairs(node.materials or {}) do
				if job.materialKind and job.materialKind(material) == "EMISSIVE" then glows = true end
			end
			if glows and job.meshPoints then
				local points = job.meshPoints(node.oldMesh)
				lamps[#lamps + 1] = { node = node, world = world, points = points }
				-- Where the lamp picture was the older game's own, the stand-in is one colour for the whole
				-- material. Head and rear lamps often share that material, so a lamp at the rear end (or one
				-- named red) is given the material's red twin.
				local along = 0
				for _, p in ipairs(points) do along = along + (world[1] * p[1] + world[5] * p[2] + world[9] * p[3] + world[13]) end
				local name = lowerPath(node.oldMesh)
				local red = name:find("red", 1, true) or (#points > 0 and along / #points < -1 and not name:find("white", 1, true))
				if red and job.rearLampMaterial then
					for i, material in ipairs(node.materials or {}) do
						node.materials[i] = job.rearLampMaterial(material) or material
					end
				end
				-- Many old models leave their lamps on all the time, which shows between coupled units and at
				-- the wrong end. A lamp at one end of the vehicle is switched the way the game's own are: head
				-- lamps when that end leads the train, rear lamps when it is the train's tail. (A model's own
				-- settings for this, where it has them, are applied later and are not overridden.)
				local mean = (#points > 0) and (along / #points) or 0
				if C.layout == "content" and math.abs(mean) > 1 then
					local atFront = mean > 0
					local event
					if red then event = atFront and "back_backward_parts" or "back_forward_parts"
					else event = atFront and "front_forward_parts" or "front_backward_parts" end
					job.lampStates = job.lampStates or {}
					job.lampStates[#job.lampStates + 1] = { node = node, event = event }
					-- A lamp that is switched by direction glows by day as well as by night, as the newer game's
					-- own lamps do and as trains run (head and marker lamps lit at the leading end in daylight).
					-- The beam it throws on the ground stays for the night. (See convertMaterial.)
					job.lampMaterials = job.lampMaterials or {}
					for _, material in ipairs(node.materials or {}) do
						if type(material) == "string" then
							job.lampMaterials[(lowerPath(material):gsub("^/" .. NEW.material, ""))] = true
						end
					end
				end
			end
			node.oldMesh = nil
		end
		for _, child in ipairs(node.children or {}) do find(child, world) end
	end
	find(root, IDENTITY)
	return { node = root, static = lod.static, visibleFrom = lod.visibleFrom, visibleTo = lod.visibleTo }, lamps
end

-- which positions in the tree are cargo-level meshes of an old load indicator
local function hiddenPartsOf(metadata)
	local hidden = {}
	local vehicle = type(metadata) == "table" and metadata.transportVehicle
	if type(vehicle) ~= "table" or type(vehicle.capacities) ~= "table" then return hidden end
	for _, capacity in ipairs(vehicle.capacities) do
		for _, key in ipairs({ "loadIndicator", "loadIndicators" }) do
			local list = capacity[key]
			if type(list) == "table" then
				if list.type then list = { list } end
				for _, indicator in ipairs(list) do
					local p = type(indicator.params) == "table" and indicator.params or {}
					if type(p.id) == "number" then hidden[p.id] = true end
					for _, level in ipairs(type(p.levels) == "table" and p.levels or {}) do
						if type(level) == "table" then
							for _, part in ipairs(level) do if type(part) == "number" then hidden[part] = true end end
						elseif type(level) == "number" then
							hidden[level] = true
						end
					end
				end
			end
			capacity[key] = nil
		end
	end
	return hidden
end

local VEHICLE_KINDS = { "railVehicle", "roadVehicle", "airVehicle", "waterVehicle" }

-- units and defaults that changed after Transport Fever 1; everything else the game upgrades itself on load
local function oldMetadata(metadata)
	if type(metadata) ~= "table" then return end
	if type(metadata.maintenance) == "table" then
		local years = tonumber(metadata.maintenance.lifespan) or 40
		if years <= 0 then years = 40 end
		metadata.maintenance.lifespan = years * 730.5   -- years -> days
		metadata.maintenance.runningCosts = -1
	end
	if type(metadata.transportVehicle) == "table" or type(metadata.cost) == "table" then
		metadata.cost = type(metadata.cost) == "table" and metadata.cost or {}
		metadata.cost.price = -1
	end
	for _, kind in ipairs({ "railVehicle", "roadVehicle" }) do
		local vehicle = metadata[kind]
		if type(vehicle) == "table" and tonumber(vehicle.topSpeed) then vehicle.topSpeed = vehicle.topSpeed / 3.6 end   -- km/h -> m/s
	end
end

-- mesh files named in the metadata (axles, wheels) follow the meshes to their new place
local function movePartNames(metadata)
	if type(metadata) ~= "table" then return end
	for _, kind in ipairs(VEHICLE_KINDS) do
		local vehicle = metadata[kind]
		if type(vehicle) == "table" then
			local configs = {}
			if type(vehicle.configs) == "table" then for _, c in ipairs(vehicle.configs) do configs[#configs + 1] = c end end
			if type(vehicle.config) == "table" then configs[#configs + 1] = vehicle.config end
			for _, config in ipairs(configs) do
				for _, key in ipairs({ "axles", "wheels" }) do
					if type(config[key]) == "table" then
						for i, part in ipairs(config[key]) do
							if C.layout ~= "legacy" and type(part) == "string" and endsWith(part:lower(), ".msh") and not startsWith(part, "/") then
								config[key][i] = newRef("mesh", part)
							end
						end
					end
				end
			end
		end
	end
end

-- a model that already is a node tree (Transport Fever 2): only the references move
local function moveTreeReferences(node, job, modelId)
	local report = job.report
	if type(node) ~= "table" then return end
	if node.standIn then
		node.standIn = nil   -- already given the converter's own lamp, with references in the new form
		for _, child in ipairs(type(node.children) == "table" and node.children or {}) do moveTreeReferences(child, job, modelId) end
		return
	end
	if type(node.mesh) == "string" then
		local theirs = not job.lowerNames[lowerPath(OLD.mesh .. node.mesh)] and job.elsewhere and job.elsewhere(lowerPath(OLD.mesh .. node.mesh))
		if theirs then
			-- a mesh of another old mod in the inbox: that mod, converted, has it
			node.mesh = theirs .. "::/" .. NEW.mesh .. lowerPath(node.mesh)
		elseif not job.lowerNames[lowerPath(OLD.mesh .. node.mesh)] then
			-- a mesh of the older game itself (its stock lamps, for one). A reference that leads nowhere makes the
			-- newer game drop the whole model, so the part is emptied; it keeps its place, name and animations,
			-- because the metadata counts parts by position.
			report.missing[#report.missing + 1] = string.format("mesh %s (model %s); that part is left empty", node.mesh, modelId)
			if C.layout == "content" then node.mesh, node.materials = nil, nil end
		else
			node.mesh = newRef("mesh", node.mesh)
		end
	end
	if type(node.materials) == "table" then
		for i, material in ipairs(node.materials) do
			if type(material) == "string" then
				local theirs = not job.lowerNames[lowerPath(OLD.material .. material)] and job.elsewhere and job.elsewhere(lowerPath(OLD.material .. material))
				if theirs then
					node.materials[i] = theirs .. "::/" .. NEW.material .. lowerPath(material)
				else
					if not job.lowerNames[lowerPath(OLD.material .. material)] then
						report.missing[#report.missing + 1] = string.format("material %s (model %s); a plain grey one stands in", material, modelId)
						if C.layout == "content" then
							job.needStandInMaterial = true
							material = "converter/missing.mtl"
						end
					end
					job.usedMaterials[lowerPath(material)] = true
					node.materials[i] = newRef("material", material)
				end
			end
		end
	end
	if type(node.animations) == "table" then
		for _, animation in pairs(node.animations) do
			if type(animation) == "table" and animation.type == "FILE_REF" and type(animation.params) == "table" and type(animation.params.id) == "string" then
				if not job.lowerNames[lowerPath(OLD.animation .. animation.params.id)] then
					report.missing[#report.missing + 1] = string.format("animation %s (model %s)", animation.params.id, modelId)
				end
				animation.params.id = newRef("animation", animation.params.id)
			end
		end
	end
	for _, child in ipairs(type(node.children) == "table" and node.children or {}) do moveTreeReferences(child, job, modelId) end
end

-- A powered rail vehicle that also carries something is a multiple unit in one piece. Transport Fever 3 lists
-- multiple units from their own small files (.mu.lua, next to the models) and keeps their cars out of the
-- single-vehicle lists; the older games had no such split for a one-model unit. Returns the file's data, or nil.
function C.singleModelUnit(data, modelFile)
	local metadata = type(data.metadata) == "table" and data.metadata or {}
	local vehicle = metadata.transportVehicle
	local rail = metadata.railVehicle
	if type(vehicle) ~= "table" or type(rail) ~= "table" then return nil end
	if vehicle.carrier ~= "RAIL" and vehicle.carrier ~= "TRAM" then return nil end
	local engines = rail.engines or (rail.engine and { rail.engine }) or {}
	if type(engines) ~= "table" or #engines == 0 then return nil end
	local carries = false
	for _, capacity in ipairs(type(vehicle.capacities) == "table" and vehicle.capacities or {}) do
		if (tonumber(capacity.capacity) or 0) > 0 then carries = true end
	end
	if type(vehicle.compartments) == "table" and #vehicle.compartments > 0 then carries = true end
	if type(vehicle.compartmentsList) == "table" and #vehicle.compartmentsList > 0 then carries = true end
	if not carries then return nil end
	local description = type(metadata.description) == "table" and metadata.description or {}
	vehicle.multipleUnitOnly = true
	return {
		vehicles = { { name = modelFile, forward = true } },
		name = description.name,
		desc = description.description,
		filterTags = { "default" },
	}
end

-- Cargo: the older games name a cargo by a word ("PASSENGERS", "COAL"); Transport Fever 3 by its cargo file
-- ("::/cargos/coal/coal.cargo") or by a class of cargo. An old word that is left as it is matches nothing and
-- the vehicle shows a capacity of 0. Where the newer game has no such cargo, the nearest is taken and said so.
C.cargoTypes = {
	PASSENGERS = "passengers", COAL = "coal", IRON_ORE = "iron_ore", STEEL = "steel", LOGS = "logs", PLANKS = "planks",
	STONE = "stone", GRAIN = "grain", CRUDE = "crude_oil", FUEL = "fuel", PLASTIC = "plastic", MACHINES = "machines",
	TOOLS = "tools",
}
C.cargoNearest = {   -- no cargo of that name any more: the converter's own choice of a stand-in
	OIL = { type = "chemicals" }, FOOD = { type = "tinned_food" }, CONSTRUCTION_MATERIALS = { type = "bricks" },
	GOODS = { class = "GOODS" }, LIVESTOCK = { type = "meat" }, SLAG = { type = "stone" },
}

local function newCargo(vehicle, modelId, report)
	local function walk(t, depth)
		if type(t) ~= "table" or stubs[t] or depth > 8 then return end
		if type(t.type) == "string" and tonumber(t.capacity) and t.cargoTypeSet == nil then
			local old = t.type:upper()
			local known, near = C.cargoTypes[old], C.cargoNearest[old]
			if known then
				t.cargoTypeSet = { cargoTypesIncluded = { "::/cargos/" .. known .. "/" .. known .. ".cargo" } }
			elseif near and near.class then
				t.cargoTypeSet = { cargoClassesIncluded = { near.class } }
				report.notes[#report.notes + 1] = string.format("model %s: cargo %s has no equivalent; it carries the class %s instead", modelId, old, near.class)
			elseif near then
				t.cargoTypeSet = { cargoTypesIncluded = { "::/cargos/" .. near.type .. "/" .. near.type .. ".cargo" } }
				report.notes[#report.notes + 1] = string.format("model %s: cargo %s has no equivalent; it carries %s instead", modelId, old, near.type)
			elseif t.type:find("%.cargo") then
				return   -- already a cargo file name
			else
				report.problems[#report.problems + 1] = string.format("model %s: cargo %s is unknown; that capacity will show as 0", modelId, t.type)
				return
			end
			t.type = nil
		end
		for _, v in pairs(t) do walk(v, depth + 1) end
	end
	walk(vehicle, 0)
end

-- Parts shown or hidden by the vehicle's state. The older games list them by position in the vehicle's settings
-- (which parts show at the front going forward, which are brake lights, ...); the newer game wants an "on" and an
-- "off" animation of that name on each such part, and only builds them itself for models older than its own
-- version. The animations are the game's own shared ones.
local STATE_PARTS = {
	railVehicle = {
		frontForwardParts = "front_forward_parts", backForwardParts = "back_forward_parts", innerForwardParts = "inner_forward_parts",
		frontBackwardParts = "front_backward_parts", backBackwardParts = "back_backward_parts", innerBackwardParts = "inner_backward_parts",
		brakeLights = "brake_lights",
		blinkLightsLeft0 = "blink_lights_left", blinkLightsLeft1 = "blink_lights_left",
		blinkLightsRight0 = "blink_lights_right", blinkLightsRight1 = "blink_lights_right",
		blinkingLights0 = "blink_lights_left", blinkingLights1 = "blink_lights_left",
	},
	roadVehicle = { blinkLightsLeft = "blink_lights_left", blinkLightsRight = "blink_lights_right", brakeLights = "brake_lights" },
}

local LAMP_EVENTS = { front_forward_parts = true, back_forward_parts = true, front_backward_parts = true, back_backward_parts = true, brake_lights = true }

local function statePartAnimations(data, modelId, report, job)
	local metadata = type(data.metadata) == "table" and data.metadata or {}
	local attached = 0
	for kind, lists in pairs(STATE_PARTS) do
		local vehicle = metadata[kind]
		if type(vehicle) == "table" then
			for lodIndex, lod in ipairs(data.lods) do
				local config = type(vehicle.configs) == "table" and vehicle.configs[lodIndex] or vehicle.config
				if type(config) == "table" and type(lod.node) == "table" then
					-- parts are counted from the root (0) through the tree, each part before its own children
					local byIndex, count = { [0] = lod.node }, 0
					local function number(node)
						for _, child in ipairs(type(node.children) == "table" and node.children or {}) do
							count = count + 1
							byIndex[count] = child
							number(child)
						end
					end
					number(lod.node)
					for _, key in ipairs(sortedKeys(lists)) do
						local event = lists[key]
						local list = config[key]
						if type(list) == "table" then
							for _, index in ipairs(list) do
								local node = type(index) == "number" and byIndex[index]
								if node and job and LAMP_EVENTS[event] and type(node.materials) == "table" then
									-- the materials of a part shown by direction are lamps (see convertMaterial)
									job.lampMaterials = job.lampMaterials or {}
									for _, material in ipairs(node.materials) do
										if type(material) == "string" then
											job.lampMaterials[(lowerPath(material):gsub("^/" .. NEW.material, ""))] = true
										end
									end
								end
								if node then
									node.animations = type(node.animations) == "table" and node.animations or {}
									for _, state in ipairs({ "_on", "_off" }) do
										if node.animations[event .. state] == nil then
											node.animations[event .. state] = {
												params = { id = "::/vehicle/shared/ani/" .. event .. state .. ".ani" },
												type = "FILE_REF", interpolation = "NEAREST",
											}
										end
									end
									attached = attached + 1
								end
							end
							config[key] = nil
						end
					end
				end
			end
		end
	end
	if attached > 0 then
		report.notes[#report.notes + 1] = string.format("model %s: %d parts set to show by the vehicle's state (direction, braking, indicating)", modelId, attached)
	end
end

-- What Transport Fever 3's own model version (2) needs that the game only does for older versions on load:
-- levels of detail in rising order of distance, and the animation driver ("transformator") named.
-- The default drivers are the game's own, by kind of vehicle.
local function newVersion(data, modelId, job)
	local report = job.report
	local metadata = type(data.metadata) == "table" and data.metadata or {}
	local order = {}
	for i = 1, #data.lods do order[i] = i end
	table.sort(order, function(a, b)
		local va, vb = tonumber(data.lods[a].visibleTo) or 0, tonumber(data.lods[b].visibleTo) or 0
		if va ~= vb then return va < vb end
		return a < b
	end)
	local moved = false
	for i, from in ipairs(order) do if from ~= i then moved = true end end
	if moved then
		local lods = {}
		for i, from in ipairs(order) do lods[i] = data.lods[from] end
		data.lods = lods
		for _, kind in ipairs(VEHICLE_KINDS) do   -- one entry of "configs" per level of detail: they move along
			local vehicle = metadata[kind]
			if type(vehicle) == "table" and type(vehicle.configs) == "table" and #vehicle.configs == #order then
				local configs = {}
				for i, from in ipairs(order) do configs[i] = vehicle.configs[from] end
				vehicle.configs = configs
			end
		end
	end
	-- Transport Fever 2 let a vehicle's lifespan be worked out by the game (-1). The newer game takes the number
	-- as it stands, and a vehicle with none starts out worn to nothing. 29220 is what many of its own trains have.
	if type(metadata.transportVehicle) == "table" then
		metadata.maintenance = type(metadata.maintenance) == "table" and metadata.maintenance or {}
		local lifespan = tonumber(metadata.maintenance.lifespan)
		if not lifespan or lifespan <= 0 then
			metadata.maintenance.lifespan = 29220
			report.notes[#report.notes + 1] = string.format("model %s: no lifespan given; set to the newer game's usual 29220", modelId)
		end
	end
	if metadata.transformatorConfig == nil then
		local carrier = type(metadata.transportVehicle) == "table" and metadata.transportVehicle.carrier
		local name
		if metadata.roadVehicle then name = "::/vehicle/shared/default_road.trf"
		elseif metadata.railVehicle then name = (carrier == "RAIL") and "::/vehicle/train/shared/default_train.trf" or "::/vehicle/tram/shared/default_tram.trf"
		elseif metadata.airVehicle then name = "::/vehicle/shared/default_air.trf"
		elseif metadata.waterVehicle then name = "::/vehicle/ship/shared/default_ship.trf" end
		if name then metadata.transformatorConfig = { transformator = { name = name }, skipFromLod = 1 } end
	end
	-- the vehicle's sound set, in the newer game's form; a name that leads nowhere is worse than none
	for _, kind in ipairs(VEHICLE_KINDS) do
		local vehicle = metadata[kind]
		if type(vehicle) == "table" and vehicle.soundSet ~= nil then
			local name = type(vehicle.soundSet) == "table" and vehicle.soundSet.name or vehicle.soundSet
			local ref = type(name) == "string" and name ~= "" and job.soundSet and job.soundSet(name)
			vehicle.soundSet = nil
			if ref then
				metadata.soundConfig = { soundSet = { name = ref } }
			elseif type(name) == "string" and name ~= "" then
				report.notes[#report.notes + 1] = string.format("model %s: its sound set %s could not be converted; the vehicle has no sound of its own", modelId, tostring(name))
			end
		end
	end
	data.version = 2
end

-- returns the converted model, and "old" or "tree" for the form it was in
function C.convertModel(data, modelId, job)
	local report = job.report
	if type(data.lods) ~= "table" or #data.lods == 0 then return nil, "has no levels of detail" end
	local first = data.lods[1]
	if type(first) ~= "table" then return nil, "its first level of detail is not a table" end
	local form
	if type(first.node) == "table" then
		form = "tree"
		if C.layout == "content" then
			local nearest, nearestLamps = nil, {}
			local named = 0
			local lampNames, lodIndexForNames = {}, 0
			for _, lod in ipairs(data.lods) do
				lodIndexForNames = lodIndexForNames + 1
				local lamps = {}
				local function find(node, world)
					if type(node) ~= "table" then return end
					world = C.transf.mul(world, type(node.transf) == "table" and #node.transf == 16 and node.transf or IDENTITY)
					local colour = type(node.mesh) == "string" and not job.lowerNames[lowerPath(OLD.mesh .. node.mesh)] and stockLamp(node.mesh)
					if colour then
						-- Old mods put the older game's round lamp mesh on a vehicle with a material of their own:
						-- the mesh only says "a lamp", the material says which (its glow is red for a rear lamp,
						-- whatever the mesh is called) and may bring a picture of its own (a row of LEDs, say).
						local ownMaterial = type(node.materials) == "table" and type(node.materials[1]) == "string"
							and job.lowerNames[lowerPath(OLD.material .. node.materials[1])] and node.materials[1]
						if ownMaterial then
							local material = job.readOld("material", ownMaterial)
							local scale = type(material) == "table" and type(material.params) == "table" and type(material.params.emissive_scale) == "table"
								and material.params.emissive_scale.emissiveScale
							if type(scale) == "table" then
								local r, g, b = tonumber(scale[1]) or 0, tonumber(scale[2]) or 0, tonumber(scale[3]) or 0
								colour = (r > 0 and r >= 2 * g and r >= 2 * b) and "red" or "white"
							elseif lowerPath(ownMaterial):find("red", 1, true) then
								colour = "red"
							end
						end
						local carrier = type(data.metadata) == "table" and type(data.metadata.transportVehicle) == "table" and data.metadata.transportVehicle.carrier
						local rail = (carrier == "RAIL" or carrier == "TRAM")
						if ownMaterial then
							report.notes[#report.notes + 1] = string.format("model %s: stock lamp %s replaced by a plain lamp with the mod's own material %s (%s)", modelId, node.mesh, ownMaterial, colour)
							-- The mod's picture is laid out as the older game's own lamp picture, since it was made for that
								-- game's lamp meshes: a sheet of five lamps, red in the top left and bottom right corners, white
								-- in the other two and in the middle. The lamp shows the one its old mesh pointed at.
								node.mesh = job.standInLamp(lowerPath(node.mesh):find("red", 1, true) and "sheet_red" or "sheet_white", false)
							job.usedMaterials[lowerPath(ownMaterial)] = true
							job.lampMaterials = job.lampMaterials or {}
							job.lampMaterials[lowerPath(ownMaterial)] = true
							node.materials = { newRef("material", ownMaterial) }
						else
							report.notes[#report.notes + 1] = string.format("model %s: stock lamp %s replaced by a plain %s lamp", modelId, node.mesh, colour)
							node.mesh = job.standInLamp(colour, rail)
							node.materials = { job.standInLampMaterial(colour, rail) }
						end
						node.standIn = true
						-- every lamp needs a name of its own: a light is tied to its lamp by the part's name
						lampNames[lodIndexForNames] = lampNames[lodIndexForNames] or {}
						local taken = lampNames[lodIndexForNames]
						if node.name == nil then
							named = named + 1
							node.name = "converter_lamp_" .. named
						elseif taken[node.name] then
							taken[node.name] = taken[node.name] + 1
							node.name = node.name .. "_" .. taken[node.name]
						end
						taken[node.name] = taken[node.name] or 1
						lamps[#lamps + 1] = { node = node, world = world, points = { { 0, 0, 0 } }, colour = colour }
					end
					for _, child in ipairs(type(node.children) == "table" and node.children or {}) do find(child, world) end
				end
				find(lod.node, IDENTITY)
				local to = tonumber(lod.visibleTo) or 0
				if nearest == nil or to < nearest then nearest, nearestLamps = to, lamps end
			end
			if type(data.metadata) == "table" and data.metadata.lightSourceList == nil then
				local lights = C.lightSources(nearestLamps)
				if #lights > 0 then
					data.metadata.lightSourceList = { lights = lights }
					report.notes[#report.notes + 1] = string.format("model %s: %d light sources placed at its lamps", modelId, #lights)
				end
			end
		end
		for _, lod in ipairs(data.lods) do moveTreeReferences(lod.node, job, modelId) end
	else
		form = "old"
		job.hiddenParts = hiddenPartsOf(data.metadata)
		local lods, nearest, nearestLamps = {}, nil, {}
		for i, lod in ipairs(data.lods) do
			local lamps
			lods[i], lamps = C.oldLodToTree(lod, job, modelId)
			local to = tonumber(lod.visibleTo) or 0
			if nearest == nil or to < nearest then nearest, nearestLamps = to, lamps end
		end
		data.lods = lods
		-- light sources where the nearest level of detail has its lamps, unless the model brings its own
		if C.layout == "content" and type(data.metadata) == "table" and data.metadata.lightSourceList == nil then
			local lights = C.lightSources(nearestLamps)
			if #lights > 0 then
				data.metadata.lightSourceList = { lights = lights }
				report.notes[#report.notes + 1] = string.format("model %s: %d light sources placed at its lamps (headlights at the +x end, red lights at the other)", modelId, #lights)
			end
		end
		oldMetadata(data.metadata)
		if type(data.collider) ~= "table" then data.collider = { params = {}, transf = IDENTITY, type = "MESH" } end
		data.version = 1
	end
	movePartNames(data.metadata)
	if type(data.metadata) == "table" and type(data.metadata.transportVehicle) == "table" then
		newCargo(data.metadata.transportVehicle, modelId, report)
	end
	-- "groupFileName" makes a vehicle a variant of another model. The newer game reads it from the model's own
	-- folder and complains when it leads nowhere; Transport Fever 2 mods often name a model that never existed.
	if C.layout == "content" and type(data.metadata) == "table" and type(data.metadata.transportVehicle) == "table" then
		local vehicle = data.metadata.transportVehicle
		if type(vehicle.groupFileName) == "string" then
			local target = lowerPath(vehicle.groupFileName)
			local here = modelId:match("^(.*)/[^/]+$") or ""
			local there, file = target:match("^(.*)/([^/]+)$")
			if not there then there, file = "", target end
			if job.lowerNames[OLD.model .. target] and there == here then
				vehicle.groupFileName = file
			else
				if vehicle.groupFileName ~= "" then
					report.notes[#report.notes + 1] = string.format("model %s: its variant group %s is not a model of the mod; it is listed on its own", modelId, vehicle.groupFileName)
				end
				vehicle.groupFileName = nil
			end
		end
	end
	if C.layout == "content" then
		-- Text on the model (line number, destination, station name). The newer game draws a label's text at
		-- the label's "size" taken as picture points and brings it to its place with the label's transform:
		-- its own models have sizes like 161 x 9 and a transform that scales by 0.01. The older game's labels
		-- give the size in metres (0.78 x 0.12) with a transform that does not scale, which the newer game
		-- draws with less than one point - a smear. Same place and same extent, a hundred times the points:
		local labels = type(data.metadata) == "table" and type(data.metadata.labelList) == "table" and data.metadata.labelList.labels
		local sharpened = 0
		for _, label in ipairs(type(labels) == "table" and labels or {}) do
			-- Text with hard edges ("CUTOUT") was readable from afar in the older game; in the newer one it breaks
			-- up into dots at a distance. The newer game's own models only ever ask for blended text.
			if type(label) == "table" and label.alphaMode == "CUTOUT" then label.alphaMode = "BLEND" end
			if type(label) == "table" and type(label.size) == "table" and type(label.transf) == "table" and #label.transf == 16
				and (tonumber(label.size[1]) or 0) > 0 and math.max(tonumber(label.size[1]) or 0, tonumber(label.size[2]) or 0) < 20 then
				label.size = { label.size[1] * 100, (tonumber(label.size[2]) or 0) * 100 }
				local t = {}
				for i = 1, 16 do t[i] = label.transf[i] end
				for _, i in ipairs({ 1, 2, 3, 5, 6, 7, 9, 10, 11 }) do t[i] = t[i] / 100 end
				label.transf = t
				sharpened = sharpened + 1
			end
		end
		if sharpened > 0 then
			report.notes[#report.notes + 1] = string.format("model %s: %d text labels given the newer game's scale (they were a smear otherwise)", modelId, sharpened)
		end
		statePartAnimations(data, modelId, report, job)   -- before the levels of detail are put in order: the settings go by level
		-- lamps the model itself does not switch (see where they are found)
		local switched = 0
		for _, lamp in ipairs(job.lampStates or {}) do
			local animations = type(lamp.node.animations) == "table" and lamp.node.animations or {}
			local has = false
			for name in pairs(animations) do
				if type(name) == "string" and name:find("_parts_o", 1, true) then has = true end
			end
			if not has then
				for _, state in ipairs({ "_on", "_off" }) do
					animations[lamp.event .. state] = { params = { id = "::/vehicle/shared/ani/" .. lamp.event .. state .. ".ani" }, type = "FILE_REF", interpolation = "NEAREST" }
				end
				lamp.node.animations = animations
				switched = switched + 1
			end
		end
		job.lampStates = nil
		if switched > 0 then
			report.notes[#report.notes + 1] = string.format("model %s: %d lamps switched by which end of the train they are at", modelId, switched)
		end
		newVersion(data, modelId, job)
		if C.addGlassParts(data, job) > 0 then
			report.notes[#report.notes + 1] = string.format("model %s: its paint-and-glass parts are drawn a second time for the glass", modelId)
		end
	end
	return data, form
end


-- ---------------------------------------------------------------------------------------------------------
-- lamps that light the scene

-- In the older games a lamp is only a glowing mesh. The newer game also has light sources: a list on the model,
-- each tied to a node (it is lit while that node is shown) and placed in that node's own space. So for each
-- glowing mesh at the vehicle's ends, a pair of beams is put where the lamps are: headlights at the front
-- (the +x end, the way a vehicle of the older games faces), dim red lights at the back. Night only, as the
-- game's own vehicles have it.

local function float32(s, i)
	local b1, b2, b3, b4 = s:byte(i, i + 3)
	if not b4 then return 0 end
	local sign = (b4 >= 128) and -1 or 1
	local exponent = (b4 % 128) * 2 + math.floor(b3 / 128)
	local mantissa = ((b3 % 128) * 256 + b2) * 256 + b1
	if exponent == 0 then return sign * mantissa * 2 ^ -149 end
	if exponent == 255 then return 0 end
	return sign * (1 + mantissa * 2 ^ -23) * 2 ^ (exponent - 127)
end

-- the points of a mesh, from its description and its .blob
function C.meshPoints(description, blob)
	local attr = type(description) == "table" and type(description.vertexAttr) == "table" and description.vertexAttr.position
	if type(attr) ~= "table" or not blob then return {} end
	local offset, count, comp = tonumber(attr.offset) or 0, tonumber(attr.count) or 0, tonumber(attr.numComp) or 3
	local points = {}
	if comp < 3 then return points end
	local last = math.min(offset + count, #blob)
	local i = offset + 1
	while i + comp * 4 - 1 <= last do
		points[#points + 1] = { float32(blob, i), float32(blob, i + 4), float32(blob, i + 8) }
		i = i + comp * 4
	end
	return points
end

local function applyTransform(m, p)
	return {
		m[1] * p[1] + m[5] * p[2] + m[9] * p[3] + m[13],
		m[2] * p[1] + m[6] * p[2] + m[10] * p[3] + m[14],
		m[3] * p[1] + m[7] * p[2] + m[11] * p[3] + m[15],
	}
end

-- A model that is nothing but a box inside which the terrain is not drawn: no mesh, one entry in the light list
-- with mode = "DISCARD". The values other than the size are those of the two boxes on the newer game's own
-- underpass model (stations/rail/era_a/perron_5_underpass.mdl), which lie centred on their origin, long side
-- along x, at ground level.
C.cutStep = 0.4                          -- metres
C.cutUnits = { 1, 2, 4, 8, 16, 32, 64 }  -- box sides, in steps: 0.4 m to 25.6 m
function C.cutModelText(length, width)
	return C.dataFileText({
		boundingInfo = { bbMax = { length / 2, width / 2, 1 }, bbMin = { -length / 2, -width / 2, -1 } },
		collider = { transf = IDENTITY, type = "NONE" },
		lods = { { node = { name = "RootNode", transf = IDENTITY }, visibleFrom = 0, visibleTo = 5000 } },
		metadata = { lightSourceList = { lights = { {
			angleMax = 160, angleMin = 0, backFaceLit = true, color = { 0, 0, 0 }, fromTime = 0, toTime = 24,
			height = 2, length = length, width = width, radius = math.max(length, width) * 2.8,
			invertMask = false, lightId = "", mask = 1, meshId = "", mode = "DISCARD", strength = 10000,
			transf = IDENTITY, type = "PARALLEL", visibleFrom = -1, visibleTo = -1,
		} } } },
		version = 2,
	})
end

C.solidFrom = 0.9   -- in a cut-out material, opacity from this value up is drawn solid
C.glassBelow = 0.85 -- in a picture of paint and glass, what is less opaque than this is glass
C.glassShare = 0.005 -- ... and there has to be this much of it (as a part of the picture) to call it glass

-- The parts of a model that are drawn with a paint-and-glass material, once more for the glass: a copy of the
-- tree that keeps only what leads to such parts (empty nodes with the same place and the same animations, so
-- that a door's glass moves with the door), each part with the glass twin of its material.
local function glassMirror(node, job)
	local kids = {}
	for _, child in ipairs(type(node.children) == "table" and node.children or {}) do
		local mirrored = glassMirror(child, job)
		if mirrored then kids[#kids + 1] = mirrored end
	end
	local materials, any = nil, false
	if type(node.mesh) == "string" and type(node.materials) == "table" then
		materials = {}
		for i, material in ipairs(node.materials) do
			materials[i] = material
			if type(material) == "string" and not material:find("::", 1, true) then
				local old = (lowerPath(material):gsub("^/" .. NEW.material, ""))
				local twin = job.glassTwin(old)
				if twin then
					materials[i] = "/" .. NEW.material .. twin
					any = true
				end
			end
		end
	end
	if not any and #kids == 0 then return nil end
	local copy = { name = tostring(node.name or "part") .. "_glass", transf = node.transf, animations = node.animations }
	if any then copy.mesh, copy.materials = node.mesh, materials end
	if #kids > 0 then copy.children = kids end
	return copy
end

-- The glass parts are put last in the model, after everything else: parts are counted by their place in the
-- tree (seats and the like name them by number), and nothing that was there may change its number.
function C.addGlassParts(model, job)
	if type(job) ~= "table" or not job.glassTwin then return 0 end
	local added = 0
	for _, lod in ipairs(type(model.lods) == "table" and model.lods or {}) do
		if type(lod) == "table" and type(lod.node) == "table" then
			local mirror = glassMirror(lod.node, job)
			if mirror then
				if type(lod.node.children) ~= "table" then lod.node.children = {} end
				-- (the root's own place and animations act on its children already)
				table.insert(lod.node.children, { name = "converter_glass", transf = IDENTITY, mesh = mirror.mesh, materials = mirror.materials, children = mirror.children })
				added = added + 1
			end
		end
	end
	return added
end

-- Kinds of construction of the older game that are a station or depot in themselves and are not converted yet.
-- (A whole rail station is: the station library turns its stops and lanes into the newer game's form.)
C.wholeStationTypes = {
	RAIL_DEPOT = true,
	STREET_STATION = true, STREET_STATION_CARGO = true, STREET_DEPOT = true, TRAM_DEPOT = true,
	HARBOR = true, HARBOR_CARGO = true, WATER_DEPOT = true, AIRPORT = true, AIRPORT_CARGO = true,
	INDUSTRY = true, TOWN_BUILDING = true,
}

-- lamps: { { node = <tree node>, world = <its transform in the model>, points = <mesh points> } }
function C.lightSources(lamps)
	local lights = {}
	for _, lamp in ipairs(lamps) do
		local sides = { {}, {} }   -- left and right of the vehicle's centre line
		local endSum = 0
		for _, p in ipairs(lamp.points) do
			local w = applyTransform(lamp.world, p)
			endSum = endSum + w[1]
			local side = sides[(w[2] >= 0) and 1 or 2]
			side[#side + 1] = p
		end
		if #lamp.points > 0 and (lamp.colour or math.abs(endSum / #lamp.points) > 1) then
			-- which way is outwards: towards the end of the vehicle the lamp is at
			local front = endSum >= 0
			local head = front
			if lamp.colour then head = (lamp.colour == "white") end
			-- the beam points along the model's x axis, outwards and a little down; in the node's own space that
			-- direction is the node's rotation undone (its transpose: nodes are not scaled)
			local w = lamp.world
			local tilt = math.rad(head and 10 or 15)
			local dir = { (front and 1 or -1) * math.cos(tilt), 0, -math.sin(tilt) }
			local across = { 0, front and 1 or -1, 0 }
			local up = { (front and 1 or -1) * math.sin(tilt), 0, math.cos(tilt) }
			local function toNode(v)
				return { w[1] * v[1] + w[2] * v[2] + w[3] * v[3], w[5] * v[1] + w[6] * v[2] + w[7] * v[3], w[9] * v[1] + w[10] * v[2] + w[11] * v[3] }
			end
			local x, y, z = toNode(dir), toNode(across), toNode(up)
			for _, side in ipairs(sides) do
				if #side > 0 then
					local cx, cy, cz = 0, 0, 0
					for _, p in ipairs(side) do cx, cy, cz = cx + p[1], cy + p[2], cz + p[3] end
					cx, cy, cz = cx / #side, cy / #side, cz / #side
					local light = {
						fromTime = 18, toTime = 7, invertMask = true, lightId = "", mask = 0, meshId = lamp.node.name, mode = "LIGHT", type = "SPOT",
						transf = { x[1], x[2], x[3], 0, y[1], y[2], y[3], 0, z[1], z[2], z[3], 0, cx, cy, cz, 1 },
						visibleFrom = -1,
					}
					if head then
						light.angleMax, light.angleMin, light.color = 25, 5, { 1, 0.93, 0.75 }
						light.fadeOutStart, light.radius, light.strength, light.visibleTo = 1400, 25, 3, 1600
					else
						-- rear lights are lit round the clock, headlights at night
						light.fromTime, light.toTime = 0, 24
						light.angleMax, light.color = 35, { 0.43, 0.03, 0.03 }
						light.fadeOutStart, light.radius, light.strength, light.visibleTo = 700, 5, 1, 800
					end
					lights[#lights + 1] = light
				end
			end
		end
	end
	return lights
end

-- an all-black one-channel picture: the "nothing here takes the company colour" mask that goes with an icon
local function blankMask(width, height)
	return string.char(0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, width % 256, math.floor(width / 256), height % 256, math.floor(height / 256), 8, 0)
		.. string.rep("\0", width * height)
end

-- A stand-in for the older games' stock lamp meshes, which mods refer to and never contain, and which the newer
-- game does not have: a small disc facing along x (where the stock lamps face: mods widen them by scaling y
-- and z), to be drawn with a glowing material from both sides.
local function bytes32(n)   -- an unsigned 32-bit number, low byte first
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function floatBytes(x)   -- a 32-bit float, low byte first
	if string.pack then return string.pack("<f", x) end
	if x == 0 then return "\0\0\0\0" end
	local sign = 0
	if x < 0 then sign, x = 1, -x end
	local mantissa, exponent = math.frexp(x)   -- x = mantissa * 2^exponent, 0.5 <= mantissa < 1
	local bits = math.floor((mantissa * 2 - 1) * 8388608 + 0.5)
	local e = exponent - 1 + 127
	if bits == 8388608 then bits, e = 0, e + 1 end
	return string.char(bits % 256, math.floor(bits / 256) % 256, (e % 2) * 128 + math.floor(bits / 65536), sign * 128 + math.floor(e / 2))
end

-- The disc is seen from both sides (a rear lamp on an unturned part faces the other way), and its texture
-- points go round a circle on the texture: uCentre, vCentre, uvRadius say which.
-- returns the mesh description (as file text) and its .blob
C.lampSheetRadius = 0.2   -- of one lamp on the older game's sheet of five, as a part of the picture's width
function C.lampMesh(radius, corners, uCentre, vCentre, uvRadius)
	uCentre, vCentre, uvRadius = uCentre or 0.5, vCentre or 0.5, uvRadius or 0
	local positions, uvs, order = { floatBytes(0), floatBytes(0), floatBytes(0) }, { floatBytes(uCentre), floatBytes(vCentre) }, {}
	for i = 0, corners - 1 do
		local angle = 2 * math.pi * i / corners
		positions[#positions + 1] = floatBytes(0) .. floatBytes(radius * math.cos(angle)) .. floatBytes(radius * math.sin(angle))
		uvs[#uvs + 1] = floatBytes(uCentre + uvRadius * math.cos(angle)) .. floatBytes(vCentre - uvRadius * math.sin(angle))
	end
	for i = 1, corners do   -- the side facing +x, then the same triangle the other way round
		order[#order + 1] = bytes32(0) .. bytes32(i) .. bytes32(i % corners + 1)
		order[#order + 1] = bytes32(0) .. bytes32(i % corners + 1) .. bytes32(i)
	end
	local position = table.concat(positions)
	local positionIndex = table.concat(order)
	local same = string.rep(bytes32(0), corners * 6)   -- every corner uses the one normal and tangent
	local uv = table.concat(uvs)
	local normal = floatBytes(1) .. floatBytes(0) .. floatBytes(0)
	local tangent = floatBytes(0) .. floatBytes(1) .. floatBytes(0) .. floatBytes(1)
	local blob = uv .. normal .. tangent .. position .. positionIndex .. same .. same .. positionIndex
	local at = #uv + #normal + #tangent + #position
	local description = {
		subMeshes = { { indices = {
			uv0 = { count = #positionIndex, offset = at },   -- texture points are numbered like the corners
			normal = { count = #same, offset = at + #positionIndex },
			tangent = { count = #same, offset = at + #positionIndex + #same },
			position = { count = #positionIndex, offset = at + #positionIndex + 2 * #same },
		} } },
		vertexAttr = {
			uv0 = { count = #uv, numComp = 2, offset = 0 },
			normal = { count = #normal, numComp = 3, offset = #uv },
			tangent = { count = #tangent, numComp = 4, offset = #uv + #normal },
			position = { count = #position, numComp = 3, offset = #uv + #normal + #tangent },
		},
	}
	return C.dataFileText(description), blob
end

-- "white" or "red" for a mesh name that is one of the older games' stock lamps, else nil
function stockLamp(mesh)
	local name = lowerPath(mesh):match("([^/]+)$") or ""
	if not name:find("light", 1, true) and not name:find("lamp", 1, true) then return nil end
	if name:find("red", 1, true) then return "red" end
	if name:find("white", 1, true) or name:find("yellow", 1, true) or name:find("head", 1, true) then return "white" end
	return nil
end

-- ---------------------------------------------------------------------------------------------------------
-- sound sets

-- An old sound set is a list of sound files plus a function that, every frame, works out each one's loudness
-- and pitch from the vehicle's state. The newer game wants that as data: for each file a curve over "speed01"
-- or "power01", or one of its built-in behaviours (squeal, brake, clacks). So the old function is run once on
-- stand-in values that remember what was done with them.
local Symbol = {}
local function symbol(t) return setmetatable(t, Symbol) end
local function blurred(a, b)   -- arithmetic on a stand-in: the shape is kept, the exact numbers are not
	local s = getmetatable(a) == Symbol and a or b
	s.approximate = true
	return s
end
Symbol.__add, Symbol.__sub, Symbol.__mul, Symbol.__div = blurred, blurred, blurred, blurred
Symbol.__unm = function(a) a.approximate = true return a end
Symbol.__lt = function() return false end
Symbol.__le = function() return false end

local function soundLibrary()
	local lib = {}
	function lib.sampleCurve(curve, x)
		if getmetatable(x) == Symbol and type(curve) == "table" then return symbol({ kind = "curve", curve = curve, param = x.param }) end
		return 1
	end
	function lib.squeal() return symbol({ kind = "squeal" }) end
	function lib.brake(_, _, maxGain) return symbol({ kind = "brake", maxGain = tonumber(maxGain) or 0.5 }) end
	function lib.clacks(_, _, _, axleRefWeight) return symbol({ kind = "clacks", axleRefWeight = tonumber(axleRefWeight) or 10 }) end
	return setmetatable(lib, { __index = function(_, name) return function() return symbol({ kind = "other", name = name }) end end })
end

-- stock sounds of the older games that the newer one still has, by their old names
local STOCK_SOUNDS = {
	["vehicle/train/wheels_ringing1.wav"] = true, ["vehicle/train/wheels_ringing2.wav"] = true, ["vehicle/train/brakes.wav"] = true,
	["vehicle/train_diesel/_brakes.wav"] = true, ["vehicle/train_diesel/brakes.wav"] = true,
	["vehicle/train_diesel/_wheels_ringing.wav"] = true, ["vehicle/train_diesel/wheels_ringing.wav"] = true,
	["vehicle/train_electric_modern/_brakes.wav"] = true, ["vehicle/train_electric_modern/_wheels_ringing.wav"] = true,
	["vehicle/train_electric_old/_brakes.wav"] = true, ["vehicle/train_electric_old/_wheels_ringing.wav"] = true,
	["vehicle/train_steam_modern/_brakes.wav"] = true, ["vehicle/train_steam_modern/_wheels_ringing.wav"] = true,
	["vehicle/train_steam_old/_brakes.wav"] = true, ["vehicle/train_steam_old/_wheels_ringing.wav"] = true,
}
local STOCK_PREFIX = "::/vehicle/train/shared/sound/"

local function curveText(curve)
	local parts = {}
	for _, point in ipairs(curve) do
		parts[#parts + 1] = "{ " .. numberText(tonumber(point[1]) or 0) .. ", " .. numberText(tonumber(point[2]) or 0) .. " }"
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

-- one loudness or pitch value of the old function -> a curve and the parameter it follows
local function curveOf(value, fallback)
	if type(value) == "number" then return { { 0, value }, { 1, value } }, "speed01" end
	if getmetatable(value) == Symbol then
		local param = (value.param == "power01") and "power01" or "speed01"
		if value.kind == "curve" then return value.curve, param, value.approximate or (value.param ~= param) end
		if value.kind == "input" then return { { 0, 0 }, { 1, 1 } }, param, value.approximate or (value.param ~= param) end
	end
	return { { 0, fallback }, { 1, fallback } }, "speed01", true
end

-- data: the old sound set, as read (with its updateFn). resolve(oldName) -> the new reference of a sound file,
-- or nil when it is neither in the mod nor a stock sound the newer game still has.
-- Returns the text of the new sound set file, and a list of remarks.
function C.soundSetText(data, resolve)
	local remarks = {}
	local lines = {
		'local soundsetutil = require "::/scripts/soundsetutil.lua"', "",
		"function data()", "\tlocal data = soundsetutil.makeSoundSet()",
	}
	local input = setmetatable({}, { __index = function(_, key) return symbol({ kind = "input", param = key }) end })
	local result = {}
	if type(data.updateFn) == "function" then
		local ok, value = pcall(data.updateFn, input)
		if ok and type(value) == "table" then result = value else remarks[#remarks + 1] = "its update function could not be followed; every sound plays at a steady level" end
	end
	local resultTracks = type(result.tracks) == "table" and result.tracks or {}
	local written = 0
	for i, track in ipairs(type(data.tracks) == "table" and data.tracks or {}) do
		local value = resultTracks[i]
		local kind = getmetatable(value) == Symbol and value.kind or nil
		local name = type(track) == "table" and tostring(track.name or "") or ""
		local ref = resolve(name)
		if not ref and kind == "squeal" then ref = STOCK_PREFIX .. "train/wheels_ringing1.wav" end
		if not ref and kind == "brake" then ref = STOCK_PREFIX .. "train_electric_modern/_brakes.wav" end
		local refDist = numberText(tonumber(type(track) == "table" and track.refDist) or 10)
		if not ref then
			remarks[#remarks + 1] = "sound " .. name .. " is not in the mod and has no stand-in; left out"
		elseif kind == "squeal" then
			lines[#lines + 1] = string.format("\tsoundsetutil.addTrackSqueal(data, %s, %s)", quoted(ref), refDist)
			written = written + 1
		elseif kind == "brake" then
			lines[#lines + 1] = string.format("\tsoundsetutil.addTrackBrake(data, %s, %s, %s)", quoted(ref), refDist, numberText(value.maxGain))
			written = written + 1
		else
			local gain, gainParam, gainRough = curveOf(type(value) == "table" and value.gain, 1)
			local pitch, pitchParam, pitchRough = curveOf(type(value) == "table" and value.pitch, 1)
			lines[#lines + 1] = string.format('\tsoundsetutil.addTrackParam01(data, %s, %s, %s, %s, { "vehicle", %s }, { "vehicle", %s })',
				quoted(ref), refDist, curveText(gain), curveText(pitch), quoted(gainParam), quoted(pitchParam))
			if gainRough or pitchRough then remarks[#remarks + 1] = "sound " .. name .. ": loudness or pitch is only roughly what the old sound set did" end
			written = written + 1
		end
	end
	local resultEvents = type(result.events) == "table" and result.events or {}
	for _, key in ipairs(sortedKeys(type(data.events) == "table" and data.events or {})) do
		local event = data.events[key]
		local refs = {}
		for _, name in ipairs(type(event) == "table" and type(event.names) == "table" and event.names or {}) do
			local ref = resolve(tostring(name))
			if ref then refs[#refs + 1] = quoted(ref) end
		end
		local refDist = numberText(tonumber(type(event) == "table" and event.refDist) or 10)
		local value = resultEvents[key]
		if key == "clacks" then
			if #refs == 0 then
				local set = (type(event) == "table" and type(event.names) == "table" and tostring(event.names[1] or ""):find("/old/", 1, true)) and "old" or "modern"
				for n = 1, 10 do refs[#refs + 1] = quoted(STOCK_PREFIX .. "clack/" .. set .. "/part_" .. n .. ".wav") end
			end
			local weight = (getmetatable(value) == Symbol and value.axleRefWeight or 10) * 1000   -- tonnes -> kilograms
			lines[#lines + 1] = string.format("\tsoundsetutil.addEventClacks(data, { %s }, %s, %s)", table.concat(refs, ", "), refDist, numberText(weight))
			written = written + 1
		elseif (key == "horn" or key == "openDoors" or key == "closeDoors") and #refs > 0 then
			lines[#lines + 1] = string.format("\tsoundsetutil.addEvent(data, %s, { %s }, %s)", quoted(key), table.concat(refs, ", "), refDist)
			written = written + 1
		else
			remarks[#remarks + 1] = "event " .. tostring(key) .. " left out (" .. (#refs == 0 and "its sounds are not in the mod" or "the newer game has no such event") .. ")"
		end
	end
	lines[#lines + 1] = "\treturn data"
	lines[#lines + 1] = "end"
	if written == 0 then return nil, remarks end
	return table.concat(lines, "\n") .. "\n", remarks
end

-- Transport Fever 2 sound sets are already made of calls to a helper ("soundsetutil"), much as the newer game's
-- are. They are run against a helper that only writes the calls down; then the calls are written out again with
-- the sound files renamed and the few differences put right (parameters named with their source, weights in
-- kilograms).
local function soundRecorder()
	local lib = { makeSoundSet = function() return { calls = {} } end }
	return setmetatable(lib, { __index = function(_, name)
		return function(data, ...)
			if type(data) == "table" and type(data.calls) == "table" then data.calls[#data.calls + 1] = { name = name, args = { ... } } end
		end
	end })
end

local function paramText(p)
	local name = type(p) == "table" and p[2] or p
	if name ~= "power01" then name = "speed01" end
	return '{ "vehicle", ' .. quoted(name) .. " }"
end

function C.soundSetTextFromCalls(calls, resolve)
	local remarks = {}
	local lines = {
		'local soundsetutil = require "::/scripts/soundsetutil.lua"', "",
		"function data()", "\tlocal data = soundsetutil.makeSoundSet()",
	}
	local written = 0
	local function names(list)
		local refs = {}
		for _, name in ipairs(type(list) == "table" and list or {}) do
			local ref = resolve(tostring(name))
			if ref then refs[#refs + 1] = quoted(ref) else remarks[#remarks + 1] = "sound " .. tostring(name) .. " is not in the mod and has no stand-in; left out" end
		end
		return refs
	end
	for _, call in ipairs(calls) do
		local a = call.args
		local dist = numberText(tonumber(a[2]) or 10)
		if call.name == "addTrackParam01" or call.name == "addSimpleTrackParam01" or call.name == "addTrackSqueal" or call.name == "addTrackBrake" then
			local ref = resolve(tostring(a[1]))
			if not ref and call.name == "addTrackSqueal" then ref = STOCK_PREFIX .. "train/wheels_ringing1.wav" end
			if not ref and call.name == "addTrackBrake" then ref = STOCK_PREFIX .. "train_electric_modern/_brakes.wav" end
			if not ref then
				remarks[#remarks + 1] = "sound " .. tostring(a[1]) .. " is not in the mod and has no stand-in; left out"
			elseif call.name == "addTrackSqueal" then
				lines[#lines + 1] = string.format("\tsoundsetutil.addTrackSqueal(data, %s, %s)", quoted(ref), dist)
				written = written + 1
			elseif call.name == "addTrackBrake" then
				lines[#lines + 1] = string.format("\tsoundsetutil.addTrackBrake(data, %s, %s, %s)", quoted(ref), dist, numberText(tonumber(a[3]) or 0.5))
				written = written + 1
			elseif call.name == "addSimpleTrackParam01" then
				lines[#lines + 1] = string.format("\tsoundsetutil.addSimpleTrackParam01(data, %s, %s, %s)", quoted(ref), dist, paramText(a[3]))
				written = written + 1
			elseif type(a[3]) == "table" and type(a[4]) == "table" then
				lines[#lines + 1] = string.format("\tsoundsetutil.addTrackParam01(data, %s, %s, %s, %s, %s, %s)", quoted(ref), dist,
					curveText(a[3]), curveText(a[4]), paramText(a[5]), paramText(a[6] or a[5]))
				written = written + 1
			end
		elseif call.name == "addEventClacks" then
			local refs = names(a[1])
			if #refs == 0 then
				for n = 1, 10 do refs[#refs + 1] = quoted(STOCK_PREFIX .. "clack/modern/part_" .. n .. ".wav") end
			end
			local weight = tonumber(a[3]) or 10
			if weight < 1000 then weight = weight * 1000 end   -- tonnes -> kilograms
			lines[#lines + 1] = string.format("\tsoundsetutil.addEventClacks(data, { %s }, %s, %s)", table.concat(refs, ", "), dist, numberText(weight))
			written = written + 1
		elseif call.name == "addEvent" then
			local refs = names(a[2])
			local key = tostring(a[1])
			if #refs > 0 and (key == "horn" or key == "openDoors" or key == "closeDoors") then
				lines[#lines + 1] = string.format("\tsoundsetutil.addEvent(data, %s, { %s }, %s)", quoted(key), table.concat(refs, ", "), numberText(tonumber(a[3]) or 10))
				written = written + 1
			else
				remarks[#remarks + 1] = "event " .. key .. " left out"
			end
		else
			remarks[#remarks + 1] = "its " .. tostring(call.name) .. " part is not converted"
		end
	end
	lines[#lines + 1] = "\treturn data"
	lines[#lines + 1] = "end"
	if written == 0 then return nil, remarks end
	return table.concat(lines, "\n") .. "\n", remarks
end

-- ---------------------------------------------------------------------------------------------------------
-- stations of Transport Fever 2 (constructions and their modules)

-- A station mod's construction and module files are scripts. They are carried over as they were written, with
-- only the libraries they ask for pointed at the newer game's, and run through a small library shipped with the
-- converted mod (converter/station_shim.lua) that adapts them. See re_notes/converter/stations.md.
local STATION_LIBRARIES = {
	constructionutil = 'require "::/scripts/construction/constructionutil.lua"',
	modulesutil = 'require "::/scripts/construction/modulesutil.lua"',
	streetutil = 'require "::/scripts/construction/streetutil.lua"',
	laneutil = 'require "::/scripts/construction/laneutil.lua"',
	transf = 'require "::/scripts/transf.lua"',
	vec2 = 'require "::/scripts/vec2.lua"',
	vec3 = 'require "::/scripts/vec3.lua"',
	vec4 = 'require "::/scripts/vec4.lua"',
	["modules/trainstationutil"] = 'require "::/stations/rail/trainstationutil.lua"',
}

-- the text of an old script with its libraries repointed; "own" says which names are scripts of the mod itself
function C.stationScriptText(text, modId, own, unknown)
	if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
	local shim = 'require "' .. modId .. '::/tf3api_legacy/shim.lua"'
	local function replace(name)
		local key = name:lower():gsub("%.lua$", "")
		if key == "paramsutil" then return "(" .. shim .. ").paramsutil()" end
		if key == "colliderutil" then return "(" .. shim .. ").colliderutil()" end
		if STATION_LIBRARIES[key] then return STATION_LIBRARIES[key] end
		if own[key] then return 'require "' .. modId .. "::/scripts/" .. key .. '.lua"' end
		if unknown then unknown[name] = true end
		return "(" .. shim .. ").unknown(" .. quoted(name) .. ")"
	end
	text = text:gsub('require%s*%(%s*"([^"\n]+)"%s*%)', replace)
	text = text:gsub("require%s*%(%s*'([^'\n]+)'%s*%)", replace)
	text = text:gsub('require%s*"([^"\n]+)"', replace)
	text = text:gsub("require%s*'([^'\n]+)'", replace)
	return text
end

-- the old file as a library that hands out its data() function
local function legacyText(text)
	local changed, n = text:gsub("function%s+data%s*%(%s*%)", "return function()", 1)
	if n ~= 1 then return nil end
	return changed
end

-- ---------------------------------------------------------------------------------------------------------
-- a whole mod

local function modIdFrom(folderName)
	local id = folderName:lower():gsub("[^a-z0-9_]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
	if id == "" then id = "mod" end
	return "legacy_" .. id
end

-- host: see the top of the file. src, dst: folders. folderName: the old mod's folder name.
-- Returns the report table; report.text is what is also written to <dst>/conversion_report.txt.
-- options (optional): { stations = true } also converts station constructions and modules (experimental)
-- ---- Kinds of track ---------------------------------------------------------------------------------------
-- The older games describe a kind of track in one file (res/config/track/<name>.lua): its shape, the models and
-- materials it is laid with, its speed, its cost. The newer game has the same description in two parts: a
-- "street style" (<name>.street.lua: shape, models, materials) and one "street template" for each form that can
-- be built (<name>.street_template.lua without overhead wire, <name>_catenary.street_template.lua with), which
-- names the style and carries speed, cost, years and the menu entry.

-- what stands in where the old track names a model or material that is the older game's own
C.trackStock = {
	standard = {
		dir = "::/infrastructure/track/standard/", tail = "_standard", sleeperMaterial = "mat/sleeper_standard_tileable.mtl",
		maxSlope = 0.13, maxSlopeBuild = 0.085, maxSlopeShape = 0.16, minCurveRadius = 40, minCurveRadiusBuild = 55,
	},
	high_speed = {
		dir = "::/infrastructure/track/high_speed/", tail = "_high_speed", sleeperMaterial = "mat/sleeper_high_speed_tileable.mtl",
		maxSlope = 0.13, maxSlopeBuild = 0.085, maxSlopeShape = 0.16, minCurveRadius = 40, minCurveRadiusBuild = 55,
	},
}
-- what a metre of track costs in the newer game for one unit of the older game's cost: its standard track is
-- 180 where the older game's is 75, its high-speed track 540 where the older game's is 150
C.trackCostFactor = { standard = 2.4, high_speed = 3.6 }
C.trackFastFrom = 55         -- from this speed (m/s) on, the newer game's high-speed track is the nearer relative

-- data: what the old file gives; name: the file's name without ".lua";
-- refs.model(old) / refs.material(old): the new name of a model / material the mod (or another old mod) has, or nil;
-- refs.icon(old file name): the new name of a menu picture, or nil
-- Returns the style, the template without wire and the template with wire, as tables.
function C.trackFiles(data, name, refs)
	local speed = tonumber(data.speedLimit) or 33.3
	local kind = speed >= C.trackFastFrom and "high_speed" or "standard"
	local stock = C.trackStock[kind]
	local function number(key, default) return tonumber(data[key]) or default end
	local function model(key, stockName)
		local old = data[key]
		return (type(old) == "string" and refs.model(old)) or (stock.dir .. stockName .. stock.tail .. ".mdl")
	end
	local function material(key, stockName)
		local old = data[key]
		return (type(old) == "string" and refs.material(old)) or stockName
	end
	local straights = {}
	for _, old in ipairs(type(data.trackStraightModel) == "table" and data.trackStraightModel or {}) do
		local new = type(old) == "string" and refs.model(old)
		if new then straights[#straights + 1] = new end
	end
	if #straights == 0 then
		for _, length in ipairs({ "2m", "4m", "8m", "16m" }) do straights[#straights + 1] = stock.dir .. length .. stock.tail .. ".mdl" end
	end
	local railBase, railHeight = number("railBase", 0.37), number("railHeight", 0.17)
	local shapeWidth, shapeStep = number("shapeWidth", 4), number("shapeStep", 4)
	local style = {
		roadType = "TRACK",
		categories = { "tracks" },
		categoryList = { categories = { speed >= C.trackFastFrom and "concrete" or "ballast" } },
		ballastCutOff = number("ballastCutOff", 0.35), ballastHeight = number("ballastHeight", 0.3),
		railBase = railBase, railCutOff = number("railCutOff", 0.012), railHeight = railHeight,
		railTrackWidth = number("railTrackWidth", 1.435), railWidth = number("railWidth", 0.07),
		shapeSleeperStep = number("shapeSleeperStep", 8 / 13), shapeStep = shapeStep,
		sleeperBase = number("sleeperBase", 0.3), sleeperCutOff = number("sleeperCutOff", 0.006),
		sleeperHeight = number("sleeperHeight", 0.07), sleeperLength = number("sleeperLength", 0.2),
		sleeperWidth = number("sleeperWidth", 2.3),
		trackDistance = number("trackDistance", 5),
		railModel = (type(data.railModel) == "string" and refs.model(data.railModel)) or "::/infrastructure/track/shared/single_rail.mdl",
		sleeperModel = model("sleeperModel", "single_sleeper"),
		bumperModel = model("bumperModel", "bumper"),
		switchSignalModel = model("switchSignalModel", "switch_box"),
		trackStraightModel = straights,
		catenary = {
			catenaryBase = number("catenaryBase", 6.447), catenaryHeight = number("catenaryHeight", 1.35),
			catenaryPoleDistance = number("catenaryPoleDistance", 24),
			catenaryMaxPoleDistance = 3.33, catenaryMinPoleDistance = 0.9,
			catenaryPoleModel = model("catenaryPoleModel", "power_pole_2"),
			catenaryMultiPoleModel = model("catenaryMultiPoleModel", "power_pole_1"),
			catenaryMultiGirderModel = model("catenaryMultiGirderModel", "power_pole_1a"),
			catenaryMultiInnerPoleModel = model("catenaryMultiInnerPoleModel", "power_pole_1b"),
		},
		materials = {
			catenaryMaterial = material("catenaryMaterial", "::/infrastructure/shared/mat/catenary.mtl"),
			railMaterial = material("railMaterial", "::/infrastructure/track/shared/mat/rail_tileable.mtl"),
			sleeperMaterial = material("sleeperMaterial", stock.dir .. stock.sleeperMaterial),
		},
	}
	-- the bed: the mod's own picture lies once across the bed and once along each step of it; the game's gravel
	-- is laid by the metre
	local ownBed = type(data.ballastMaterial) == "string" and refs.material(data.ballastMaterial)
	style.materials.ballast = ownBed and { name = ownBed, size = { shapeWidth, shapeStep } }
		or { name = "::/infrastructure/track/shared/mat/ballast.mtl", size = { 7, 7 } }

	local cost = math.max(10, math.floor((number("cost", 75) * C.trackCostFactor[kind]) / 10 + 0.5) * 10)
	local function template(wire)
		local file = "/track/" .. name
		local icon = refs.icon(name .. (wire and "_catenary" or "") .. ".tga") or refs.icon(name .. ".tga")
		-- (the name as the mod gives it, translated by the mod's own texts; the form with overhead wire has no
		-- name of its own in the older games, so it is that name with a note, in the mod's first language only)
		local title = data.name or name
		local t = {
			roadType = "TRACK",
			streetStyle = file .. ".street",
			availability = { yearFrom = number("yearFrom", 0), yearTo = number("yearTo", 0) },
			cost = cost, maintenanceCost = math.floor(cost / 6 + 0.5),
			description = { name = wire and (title .. " (catenary)") or title, description = data.desc or "", icon = icon, previewIcon = icon },
			emissions = { noise = 0, pollution = 4, pollutionRadius = 0, radius = 0 },
			borderGroundTex = "::/infrastructure/track/shared/ballast.gtex",
			fillGroundTex = "::/infrastructure/track/shared/ballast_fill.gtex",
			sidewalkFillGroundTex = "::/infrastructure/street/shared/street_sidewalk_fill.gtex",
			laneConfigs = { {
				forward = true, height = railBase + railHeight, offset = 0, speed = speed, width = shapeWidth,
				transportModes = wire and { "TRAIN", "ELECTRIC_TRAIN", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK" } or { "TRAIN", "TRAM_TRACK" },
			} },
			-- (limits the mod sets are kept; the older game's own tracks set all five)
			maxSlope = number("maxSlope", stock.maxSlope), maxSlopeBuild = number("maxSlopeBuild", stock.maxSlopeBuild),
			maxSlopeShape = number("maxSlopeShape", stock.maxSlopeShape),
			minCurveRadius = number("minCurveRadius", stock.minCurveRadius),
			minCurveRadiusBuild = number("minCurveRadiusBuild", math.max(number("minCurveRadius", 0), stock.minCurveRadiusBuild)),
			menuCategory = { categories = { { category = "tracks", filterCategories = {}, order = wire and 9100 or 9000 } } },
			modifiers = { maxSpeedModifier = 0, noiseModifier = 0, pollutionModifier = 0 },
			speedCoeffs = type(data.speedCoeffs) == "table" and data.speedCoeffs or { 0.9, 15, 0.63 },
			trackDistance = number("trackDistance", 5),
			builderAudioRes = "::/gui/construction/sound/buildoze_track.builder_audio",
		}
		if wire then t.catenaryRemove = file .. ".street_template" else t.catenaryAdd = file .. "_catenary.street_template" end
		return t
	end
	return style, template(false), template(true)
end

-- A remaster's changes to one model, made to the model as the old mod gives it, so that the converter's own
-- rules then treat what was added like the rest. changes: list of { engineType, labels }
function C.remasterModel(data, changes)
	data.metadata = type(data.metadata) == "table" and data.metadata or {}
	local metadata = data.metadata
	for _, change in ipairs(changes) do
		if change.engineType then
			for _, key in ipairs({ "railVehicle", "roadVehicle", "landVehicle", "waterVehicle", "airVehicle" }) do
				local engines = type(metadata[key]) == "table" and metadata[key].engines
				for _, engine in ipairs(type(engines) == "table" and engines or {}) do
					if type(engine) == "table" then engine.type = change.engineType end
				end
			end
		end
		if type(change.labels) == "table" then
			if type(metadata.labelList) ~= "table" then metadata.labelList = {} end
			if type(metadata.labelList.labels) ~= "table" then metadata.labelList.labels = {} end
			for _, label in ipairs(change.labels) do
				local copy = {}
				for k, v in pairs(label) do
					if type(v) == "table" then
						local inner = {}
						for i, x in pairs(v) do inner[i] = x end
						copy[k] = inner
					else
						copy[k] = v
					end
				end
				table.insert(metadata.labelList.labels, copy)
			end
		end
	end
end

-- A converted mod is made on the player's machine from the player's own copy of an old mod, and it is still
-- that mod's author's work. So that a converted mod passed on by itself is of no use, what it adds is only
-- offered while the old mod it was made from is in legacy_mods beside the game, which the native layer answers
-- (tf3api.legacySource). Without the layer, or without the old mod, the converted mod's vehicles, constructions
-- and tracks are not offered in the menus. Nothing is taken out of the game: what is already running in a
-- saved game keeps running, and the saved game loads.
-- The script the converted mod gets (content/mod.script.lua), named in its mod.json as its run script:
function C.sourceCheckText(modId, folderName)
	return table.concat({
		"-- Written by the TF3OpenAPI mod converter. This mod was converted on its player's machine from the old mod",
		"-- " .. string.format("%q", folderName) .. ". It is that mod's author's work: do not pass it on.",
		"-- What it adds is offered only while that old mod is in legacy_mods beside the game.",
		"local FOLDER = " .. string.format("%q", folderName),
		"local PREFIX = " .. string.format("%q", modId .. "::"),
		"",
		"local function sourcePresent()",
		"\tlocal ok, present = pcall(function()",
		"\t\treturn type(tf3api) == \"table\" and type(tf3api.legacySource) == \"function\" and tf3api.legacySource(FOLDER) == true",
		"\tend)",
		"\treturn ok and present == true",
		"end",
		"",
		"local function mine(fileName)",
		"\treturn type(fileName) == \"string\" and fileName:sub(1, #PREFIX) == PREFIX",
		"end",
		"",
		"-- not offered: available from a year that does not come",
		"local NEVER = { yearFrom = 9998, yearTo = 9999 }",
		"",
		"function data()",
		"\treturn {",
		"\t\trunFn = function()",
		"\t\t\tif sourcePresent() then return end",
		"\t\t\tpcall(function() tf3api.log(PREFIX .. \" the old mod \" .. FOLDER .. \" is not in legacy_mods: what this converted mod adds is not offered\") end)",
		"\t\t\taddModifier(\"loadModel\", function(fileName, model)",
		"\t\t\t\tif mine(fileName) and type(model) == \"table\" and type(model.metadata) == \"table\" and model.metadata.transportVehicle ~= nil then",
		"\t\t\t\t\tmodel.metadata.availability = { yearFrom = NEVER.yearFrom, yearTo = NEVER.yearTo }",
		"\t\t\t\tend",
		"\t\t\t\treturn model",
		"\t\t\tend)",
		"\t\t\tfor _, kind in ipairs({ \"loadConstruction\", \"loadStreetTemplate\" }) do",
		"\t\t\t\taddModifier(kind, function(fileName, thing)",
		"\t\t\t\t\tif mine(fileName) and type(thing) == \"table\" then",
		"\t\t\t\t\t\tthing.availability = { yearFrom = NEVER.yearFrom, yearTo = NEVER.yearTo }",
		"\t\t\t\t\tend",
		"\t\t\t\t\treturn thing",
		"\t\t\t\tend)",
		"\t\t\tend",
		"\t\tend,",
		"\t}",
		"end",
		"",
	}, "\n")
end

function C.convertMod(host, src, dst, folderName, options)
	options = options or {}
	local report = { missing = {}, notes = {}, problems = {}, notConverted = {}, carried = {}, counts = { models = 0, oldModels = 0, meshes = 0, materials = 0, textures = 0, animations = 0 } }
	local files = host.list(src)
	table.sort(files)
	local lowerNames = {}
	for _, f in ipairs(files) do lowerNames[lowerPath(f)] = f end
	local job = { host = host, src = src, lowerNames = lowerNames, report = report, needDefault = {}, usedMaterials = {}, hiddenParts = {} }
	-- The other old mods waiting in the inbox. Old mods build on one another (a station pack on a track pack, a
	-- repaint on the station it repaints); a file this mod refers to and does not have may be one of theirs,
	-- and is then referred to in that mod as it is converted ("<its mod id>::/...").
	local siblings = {}
	if host.siblings then
		for _, other in ipairs(host.siblings() or {}) do
			local set = {}
			for _, f in ipairs(other.files or {}) do set[lowerPath(f)] = true end
			siblings[#siblings + 1] = { folder = tostring(other.folder), modId = modIdFrom(tostring(other.folder)), files = set }
		end
		table.sort(siblings, function(a, b) return a.modId < b.modId end)
	end
	job.siblings = siblings
	job.usedSiblings = {}   -- mod id -> { folder, count }
	local function useSibling(other)
		local used = job.usedSiblings[other.modId]
		if not used then used = { folder = other.folder, count = 0 } job.usedSiblings[other.modId] = used end
		used.count = used.count + 1
	end
	-- which other old mod has this file (path in the old layout, lower case): its mod id and its record
	function job.elsewhere(lowPath)
		for _, other in ipairs(siblings) do
			if other.files[lowPath] then
				useSibling(other)
				return other.modId, other
			end
		end
		return nil
	end
	local missingLibraries = {}
	local libraries = { used = missingLibraries, modules = {} }
	-- a script of the mod's own (res/scripts/<name>.lua), which its models may build their data with
	function libraries.resolve(lib)
		local real = lowerNames["res/scripts/" .. lib:gsub("%.", "/") .. ".lua"] or lowerNames["res/scripts/" .. lib .. ".lua"]
		if not real then return nil end
		job.scriptsUsed = job.scriptsUsed or {}
		job.scriptsUsed[real] = true
		return host.read(src .. "/" .. real)
	end

	-- Is this material (old id, lower case) one picture of paint and glass? Then the id of its glass twin.
	-- Told from the picture itself: a material the mod marks as cut out, most of whose picture is opaque
	-- and a real part of which lies between its threshold and "glassBelow".
	local glassTwins = {}
	function job.glassTwin(material)
		local key = lowerPath(material)
		if glassTwins[key] ~= nil then return glassTwins[key] or nil end
		glassTwins[key] = false
		if C.layout ~= "content" or not host.alphaBands or not lowerNames[OLD.material .. key] then return nil end
		local data = job.readOld("material", key)
		local params = type(data) == "table" and data.params
		if type(params) ~= "table" then return nil end
		local old = OLD_TYPES[tostring(data.type)]
		if not startsWith(old and old[1] or tostring(data.type), "PHYS_TRANSPARENT") then return nil end
		local test = params.alpha_test
		local threshold = type(test) == "table" and test.cutout == true and (tonumber(test.alphaThreshold) or 0.5)
		if not threshold or threshold <= 0 or threshold >= C.glassBelow then return nil end
		local map = params.map_albedo_opacity or (old and params[old[3]])
		local file = type(map) == "table" and type(map.fileName) == "string" and lowerNames[OLD.texture .. lowerPath(map.fileName)]
		local bands = file and host.alphaBands(src .. "/" .. file)
		if type(bands) ~= "table" or #bands ~= 16 then return nil end
		-- bands[i]: the part of the picture whose opacity is in the i-th sixteenth
		local glass, solid = 0, 0
		for i = 1, 16 do
			local low, high = (i - 1) / 16, i / 16
			if low >= C.glassBelow then solid = solid + bands[i]
			elseif low >= threshold and high <= C.glassBelow + 1 / 32 then glass = glass + bands[i] end
		end
		if solid < 0.5 or glass < C.glassShare then return nil end
		glassTwins[key] = (key:gsub("%.mtl$", "") .. "_glass.mtl")
		report.notes[#report.notes + 1] = string.format("material %s: its picture is paint and glass (%.1f%% glass); the glass is drawn by a twin material", key, glass * 100)
		return glassTwins[key]
	end

	function job.readOld(kind, id)
		local real = lowerNames[lowerPath(OLD[kind] .. id)]
		if not real then return nil, "not in the mod" end
		return C.readData(host.read(src .. "/" .. real), real, libraries)
	end

	-- meshes: the material lists move to the models; the mesh file itself keeps only its geometry
	local meshes = {}
	function job.meshInfo(id)
		local key = lowerPath(id)
		if meshes[key] == nil then
			local data, why = job.readOld("mesh", id)
			if not data then
				meshes[key] = { failed = why }
			else
				local info = { materials = {}, matConfigs = oneBased(data.matConfigs), animations = data.animations }
				for i, sub in ipairs(type(data.subMeshes) == "table" and data.subMeshes or {}) do
					info.materials[i] = type(sub.materials) == "table" and sub.materials or {}
					sub.materials = nil
				end
				data.matConfigs, data.animations = nil, nil
				info.text = C.dataFileText(data)
				meshes[key] = info
			end
		end
		if meshes[key].failed then return nil, meshes[key].failed end
		return meshes[key]
	end

	local handled = {}

	-- Remasters: changes for this particular mod, if the converter has any (converter/remasters.lua).
	-- remasterModels[model] = list of changes; remasterTextures[texture] = list of patches
	local remasterModels, remasterTextures = {}, {}
	if C.layout == "content" and options.remasters ~= false then
		local list = C.remasters
		if list == nil and host.resource then
			local text = host.resource("remasters.lua")
			local chunk = text and loadChunk(text, "remasters.lua", {})
			local ok, value = false, nil
			if chunk then ok, value = pcall(chunk) end
			if ok and type(value) == "table" then list = value
			elseif text then report.problems[#report.problems + 1] = "the remasters do not load: " .. tostring(value) end
		end
		for _, remaster in ipairs(type(list) == "table" and list or {}) do
			local matches = type(remaster.match) == "table" and #remaster.match > 0
			for _, file in ipairs(matches and remaster.match or {}) do
				if not lowerNames[lowerPath(file)] then matches = false end
			end
			if matches then
				for _, part in ipairs(type(remaster.parts) == "table" and remaster.parts or {}) do
					for model, change in pairs(type(part.models) == "table" and part.models or {}) do
						remasterModels[lowerPath(model)] = remasterModels[lowerPath(model)] or {}
						table.insert(remasterModels[lowerPath(model)], change)
					end
					for texture, patches in pairs(type(part.textures) == "table" and part.textures or {}) do
						remasterTextures[lowerPath(texture)] = remasterTextures[lowerPath(texture)] or {}
						for _, one in ipairs(patches) do table.insert(remasterTextures[lowerPath(texture)], one) end
					end
					report.notes[#report.notes + 1] = string.format("remaster %s (%s): %s", tostring(remaster.id), tostring(remaster.title or ""), tostring(part.note or part.id))
					report.counts.remasterParts = (report.counts.remasterParts or 0) + 1
				end
			end
		end
	end
	local textureCache = {}   -- every mod of the newer game carries this list of its textures
	job.textureCache = textureCache

	-- the kind of a material, by the reference a tree node has to it
	local materialKinds = {}
	function job.materialKind(ref)
		local id = lowerPath(ref):gsub("^/" .. NEW.material, "")
		if materialKinds[id] == nil then
			local data = job.readOld("material", id)
			materialKinds[id] = data and tostring(data.type or "") or ""
		end
		return materialKinds[id]
	end
	function job.meshPoints(id)
		local real = lowerNames[lowerPath(OLD.mesh .. id)]
		local blob = lowerNames[lowerPath(OLD.mesh .. id) .. ".blob"]
		if not real or not blob then return {} end
		local description = C.readData(host.read(src .. "/" .. real), real, { used = {}, modules = {} })
		return C.meshPoints(description, host.read(src .. "/" .. blob))
	end

	-- the older games keep a vehicle's small side views under res/textures/ui; the newer one beside the model
	local function icons(modelId)
		if C.layout ~= "content" then return end
		local base = modelId:gsub("%.mdl$", "")
		local folder, name = base:match("^(.*)/([^/]+)$")
		if not folder then folder, name = "", base end
		local found = false
		for _, pair in ipairs({ { "ui/models_20/", "_icon20" }, { "ui/models_small/", "_icon_small" } }) do
			for _, size in ipairs({ "@2x", "" }) do   -- double-size pictures first, as the newer game prefers them
				local real = lowerNames[OLD.texture .. pair[1] .. base .. size .. ".tga"]
				if real and not job.iconFiles[real] then
					found = true
					job.iconFiles[real] = true
					local to = (folder ~= "" and (folder .. "/") or "") .. "icons/" .. name .. pair[2]
					host.copy(src .. "/" .. real, dst .. "/content/" .. to .. size .. ".tga")
					local head = host.readHead(src .. "/" .. real, 32)
					local info = C.textureInfo(size .. ".tga", head)
					if info then job.textureCache[to .. size .. ".tga"] = info end
					-- the large picture in the shop: the older games have none, so the biggest side view serves
					if pair[2] == "_icon_small" and not job.storeIcons[base] then
						job.storeIcons[base] = true
						local store = (folder ~= "" and (folder .. "/") or "") .. "icons/" .. name .. "_store.tga"
						host.copy(src .. "/" .. real, dst .. "/content/" .. store)
						local storeInfo = C.textureInfo(".tga", head)
						if storeInfo then job.textureCache[store] = storeInfo end
					end
					-- the mask of what takes the company colour: the mod's own, or a blank one of the same size
					local mask = lowerNames[OLD.texture .. pair[1] .. base .. "_cblend" .. size .. ".tga"]
					if mask then
						job.iconFiles[mask] = true
						host.copy(src .. "/" .. mask, dst .. "/content/" .. to .. "_cblend" .. size .. ".tga")
						local maskInfo = C.textureInfo(size .. ".tga", host.readHead(src .. "/" .. mask, 32))
						if maskInfo then job.textureCache[to .. "_cblend" .. size .. ".tga"] = maskInfo end
					elseif info and head then
						local w, h = head:byte(13) + head:byte(14) * 256, head:byte(15) + head:byte(16) * 256
						host.write(dst .. "/content/" .. to .. "_cblend" .. size .. ".tga", blankMask(w, h))
						job.textureCache[to .. "_cblend" .. size .. ".tga"] = { channels = 1, extent = { info.extent[1], info.extent[2] }, numMipmaps = 1, numStrippedMipmaps = 0 }
					end
				end
			end
		end
		if not found then
			report.notes[#report.notes + 1] = string.format("model %s: the mod has no side-view pictures for it; lists show a placeholder", modelId)
		end
	end
	job.iconFiles = {}
	job.storeIcons = {}

	-- the red twin of a glowing material whose lamp picture is not in the mod; nil for any other material
	local rearTwins = {}
	function job.rearLampMaterial(ref)
		local id = lowerPath(ref):gsub("^/" .. NEW.material, "")
		if rearTwins[id] == nil then
			rearTwins[id] = false
			local data = job.readOld("material", id)
			local map = data and data.type == "EMISSIVE" and type(data.params) == "table" and data.params.map_emissive
			local file = type(map) == "table" and tostring(map.fileName or "") or ""
			local stem = file:match("^(.*)%.[^%./]+$") or file
			local present = false
			for _, ext in ipairs({ "dds", "tga", "png" }) do
				if lowerNames[lowerPath(OLD.texture .. stem .. "." .. ext)] then present = true end
			end
			if map and not present then
				local twin = id:gsub("%.mtl$", "") .. "_rear.mtl"
				data.params.map_emissive = { fileName = C.defaultTextures.lampRed.name, isDefault = true, type = "TWOD", wrapS = "REPEAT", wrapT = "REPEAT" }
				-- lit round the clock, as the newer game's own rear lamp material is (0 to 24)
				if type(data.params.emissive_scale) ~= "table" then data.params.emissive_scale = { emissiveScale = { 45, 45, 45 } } end
				data.params.emissive_scale.fromTime, data.params.emissive_scale.toTime = 0, 24
				job.needDefault.lampRed = true
				host.write(dst .. "/" .. newPath("material", twin), C.dataFileText(C.convertMaterial(data, twin, job)))
				rearTwins[id] = newRef("material", twin)
			end
		end
		return rearTwins[id] or nil
	end

	-- the converter's own lamp, written once when a model needs it
	local lampWritten = {}
	-- For rail vehicles the lamp uses the newer game's own lamp material and lamp picture, as its own trains do:
	-- one texture with the white lamp in the top left quarter and the red one below it (read off the texture
	-- points of the game's own head and rear lamp meshes). Other vehicles get a plain glowing colour.
	function job.standInLamp(colour, rail)
		local sheet = colour == "sheet_red" or colour == "sheet_white"
		local id = "converter/lamp" .. ((rail or sheet) and ("_" .. colour) or "") .. ".msh"
		if not lampWritten[id] then
			lampWritten[id] = true
			local text, blob
			-- (where the older game's own round lamp meshes point on the sheet, read off those meshes; their
			-- radius is 0.0875 m)
			if colour == "sheet_white" then text, blob = C.lampMesh(0.0875, 16, 0.483, 0.497, C.lampSheetRadius)
			elseif colour == "sheet_red" then text, blob = C.lampMesh(0.0875, 16, 0.203, 0.204, C.lampSheetRadius)
			elseif rail then text, blob = C.lampMesh(0.09, 16, 0.25, (colour == "red") and 0.75 or 0.25, 0.21)
			else text, blob = C.lampMesh(0.09, 16) end
			host.write(dst .. "/content/" .. NEW.mesh .. id, text)
			host.write(dst .. "/content/" .. NEW.mesh .. id .. ".blob", blob)
		end
		return "/" .. NEW.mesh .. id
	end
	function job.standInLampMaterial(colour, rail)
		if rail then
			return (colour == "red") and "::/vehicle/train/emissive/train_red_lights.mtl" or "::/vehicle/train/emissive/train_all_lights.mtl"
		end
		local which = (colour == "red") and "lampRed" or "lampWhite"
		local id = "converter/lamp_" .. colour .. ".mtl"
		if not lampWritten[id] then
			lampWritten[id] = true
			job.needDefault[which] = true
			local material = C.convertMaterial({ type = "EMISSIVE", order = 0, params = {
				map_emissive = { fileName = C.defaultTextures[which].name, isDefault = true, type = "TWOD", wrapS = "REPEAT", wrapT = "REPEAT" },
				two_sided = { twoSided = true },
			} }, id, job)
			host.write(dst .. "/content/" .. NEW.material .. id, C.dataFileText(material))
		end
		return "/" .. NEW.material .. id
	end

	-- sound sets are converted when a model asks for one; each once
	local soundSets = {}
	function job.soundSet(name)
		local key = name:lower():gsub("%.lua$", "")
		if soundSets[key] ~= nil then return soundSets[key] or nil end
		soundSets[key] = false
		local real = lowerNames["res/config/sound_set/" .. key .. ".lua"]
		if not real then return nil end
		local data, why = C.readData(host.read(src .. "/" .. real), real,
			{ used = {}, modules = {}, libraries = { soundeffectsutil = soundLibrary(), soundsetutil = soundRecorder() } })
		if not data then
			report.problems[#report.problems + 1] = string.format("sound set %s not converted: %s", key, why)
			return nil
		end
		local function resolve(old)
			local low = lowerPath(old)
			local file = lowerNames["res/audio/effects/" .. low]
			if file then
				if not handled[file] then
					handled[file] = true
					host.copy(src .. "/" .. file, dst .. "/content/audio/effects/" .. low)
				end
				return "/audio/effects/" .. low
			end
			if STOCK_SOUNDS[low] then return STOCK_PREFIX .. low:sub(#"vehicle/" + 1) end
			local part = low:match("^vehicle/(clack/[a-z]+/part_%d+%.wav)$")
			if part and (part:find("^clack/modern/") or part:find("^clack/old/")) then return STOCK_PREFIX .. part end
			return nil
		end
		local text, remarks
		if type(data.calls) == "table" then text, remarks = C.soundSetTextFromCalls(data.calls, resolve)
		else text, remarks = C.soundSetText(data, resolve) end
		for _, remark in ipairs(remarks) do report.notes[#report.notes + 1] = "sound set " .. key .. ": " .. remark end
		if not text then return nil end
		handled[real] = true
		host.write(dst .. "/content/sound_set/" .. key .. ".snd.lua", text)
		report.counts.soundSets = (report.counts.soundSets or 0) + 1
		soundSets[key] = "/sound_set/" .. key .. ".snd"
		return soundSets[key]
	end
	-- in the old layout a file keeps its exact name, since the references to it are kept as written
	local function out(kind, id, real)
		if real and C.layout == "legacy" then return dst .. "/content/" .. real end
		return dst .. "/" .. newPath(kind, id)
	end

	-- Textures without smaller copies of themselves ("mip levels") are always loaded whole by the newer game and
	-- shimmer at a distance. The older games' .tga textures have none, so where the host can, each is written
	-- as a .dds with all its levels, and the materials are pointed at that.
	job.mipped = {}
	if C.layout == "content" and host.makeMips then
		for _, f in ipairs(files) do
			local low = lowerPath(f)
			-- (.hdr: the older games' bright lamp pictures. The newer game reads the file but cannot use what it
			-- gets - "Unsupported format E5B9G9R9UfloatPack32" in its log - so those are written as .dds too,
			-- with the brightest value as full white; how bright that was is kept for the materials.)
			local hdr = endsWith(low, ".hdr")
			if startsWith(low, OLD.texture) and (endsWith(low, ".tga") or hdr) and not startsWith(low, OLD.texture .. "ui/") then
				local id = low:sub(#OLD.texture + 1)
				local newId = id:gsub(hdr and "%.hdr$" or "%.tga$", ".dds")
				if not lowerNames[OLD.texture .. newId] then
					local width, height, levels, peak = host.makeMips(src .. "/" .. f, dst .. "/content/" .. NEW.texture .. newId)
					if width then
						if hdr then
							job.hdrPeak = job.hdrPeak or {}
							job.hdrPeak[id] = tonumber(peak) or 1
							report.counts.hdr = (report.counts.hdr or 0) + 1
						end
						job.mipped[id] = newId
						handled[f] = true
						textureCache[NEW.texture .. newId] = { channels = 4, extent = { width, height }, numMipmaps = levels, numStrippedMipmaps = 0 }
						report.counts.textures = report.counts.textures + 1
						report.counts.mipped = (report.counts.mipped or 0) + 1
					end
				end
			end
		end
		if report.counts.mipped then
			report.notes[#report.notes + 1] = string.format("%d .tga textures written as .dds with mip levels", report.counts.mipped)
			if report.counts.hdr then
				report.notes[#report.notes + 1] = string.format("%d of them were bright .hdr lamp pictures, which the newer game cannot use as they are", report.counts.hdr)
			end
		end
	end

	-- models
	for _, f in ipairs(files) do
		local low = lowerPath(f)
		if startsWith(low, OLD.model) and endsWith(low, ".mdl") then
			handled[f] = true
			local id = low:sub(#OLD.model + 1)
			local data, why = C.readData(host.read(src .. "/" .. f), f, libraries)
			local model, form
			if data and remasterModels[id] then C.remasterModel(data, remasterModels[id]) end
			if data then model, form = C.convertModel(data, id, job) end
			if model then
				-- a one-model multiple unit gets its unit file, where the game looks for the model by its old name
				-- (in the new layout file names are lower case, in the old one as the mod wrote them)
				local named = (C.layout == "legacy") and f:sub(#OLD.model + 1) or id
				local unit = form == "old" and C.singleModelUnit(model, named:match("([^/]+)$"))
				if unit then
					local unitFile = "content/" .. named:gsub("%.[^%./]*$", "") .. ".mu.lua"
					host.write(dst .. "/" .. unitFile, C.dataFileText(unit))
					report.notes[#report.notes + 1] = string.format("model %s: powered and carrying, so listed as a multiple unit (%s)", id, unitFile)
				end
				host.write(out("model", id, f), C.dataFileText(model))
				report.counts.models = report.counts.models + 1
				if type(model.metadata) == "table" and type(model.metadata.transportVehicle) == "table" then icons(id) end
				if form == "old" then report.counts.oldModels = report.counts.oldModels + 1 end
			else
				report.problems[#report.problems + 1] = string.format("model %s not converted: %s", id, tostring(why or form))
			end
		end
	end

	-- the remaining files, by kind
	for _, f in ipairs(files) do
		local low = lowerPath(f)
		if startsWith(low, OLD.mesh) then
			handled[f] = true
			local id = low:sub(#OLD.mesh + 1)
			if endsWith(low, ".msh") then
				local info = job.meshInfo(id)
				if info then
					host.write(out("mesh", id, f), info.text)
					report.counts.meshes = report.counts.meshes + 1
				else
					report.problems[#report.problems + 1] = string.format("mesh %s not converted: %s", id, tostring(meshes[lowerPath(id)].failed))
				end
			else
				host.copy(src .. "/" .. f, out("mesh", id, f))   -- the .blob with the numbers
			end
		elseif startsWith(low, OLD.group) then
			handled[f] = true   -- groups are folded into the models
		elseif startsWith(low, OLD.material) and endsWith(low, ".mtl") then
			handled[f] = true
			local id = low:sub(#OLD.material + 1)
			local data, why = C.readData(host.read(src .. "/" .. f), f, libraries)
			if data then
				host.write(out("material", id, f), C.dataFileText(C.convertMaterial(data, id, job)))
				report.counts.materials = report.counts.materials + 1
				local twin = job.glassTwin(id)
				local again = twin and C.readData(host.read(src .. "/" .. f), f, libraries)
				if again then
					host.write(dst .. "/content/" .. NEW.material .. twin, C.dataFileText(C.convertMaterial(again, id, job, "glass")))
				end
			else
				report.problems[#report.problems + 1] = string.format("material %s not converted: %s", id, why)
			end
		elseif startsWith(low, OLD.animation) then
			handled[f] = true
			host.copy(src .. "/" .. f, out("animation", low:sub(#OLD.animation + 1), f))
			report.counts.animations = report.counts.animations + 1
		elseif job.iconFiles[f] then
			handled[f] = true   -- already placed beside its model
		elseif startsWith(low, OLD.texture) and job.mipped[low:sub(#OLD.texture + 1)] then
			handled[f] = true   -- already written with its mip levels
		elseif startsWith(low, OLD.texture) then
			handled[f] = true
			host.copy(src .. "/" .. f, out("texture", low:sub(#OLD.texture + 1), f))
			report.counts.textures = report.counts.textures + 1
			for _, one in ipairs(remasterTextures[low:sub(#OLD.texture + 1)] or {}) do
				-- (on the copy; the old mod's picture stays as it is)
				local painted = host.paint and type(one.rect) == "table" and type(one.from) == "table"
					and host.paint(out("texture", low:sub(#OLD.texture + 1), f), one.rect[1], one.rect[2], one.rect[3], one.rect[4], one.from[1], one.from[2])
				if not painted then
					report.problems[#report.problems + 1] = string.format("remaster: texture %s could not be painted (not a .dds picture this build can change)", low:sub(#OLD.texture + 1))
				end
			end
			if C.layout == "content" then
				local info = C.textureInfo(low, host.readHead(src .. "/" .. f, 32))
				if info then textureCache[NEW.texture .. low:sub(#OLD.texture + 1)] = info end
			end
		elseif C.layout == "legacy" and not handled[f] and startsWith(low, "res/") and not startsWith(low, "res/scripts/") then
			-- sounds, sound sets and the like: carried over as they are, for the game's own handling of old content
			handled[f] = true
			host.copy(src .. "/" .. f, dst .. "/content/" .. f)
			report.carried[#report.carried + 1] = f
		end
	end
	-- Transport Fever 2's multiple units: res/config/multiple_unit/<name>.lua -> a .mu.lua beside its vehicles
	if C.layout == "content" then
		for _, f in ipairs(files) do
			local low = lowerPath(f)
			local unitName = low:match("^res/config/multiple_unit/([^/]+)%.lua$")
			if unitName then
				local data, why = C.readData(host.read(src .. "/" .. f), f, libraries)
				if data and type(data.vehicles) == "table" and #data.vehicles > 0 then
					handled[f] = true
					local folder
					for _, vehicle in ipairs(data.vehicles) do
						local dir = lowerPath(tostring(vehicle.name or "")):match("^(.*)/[^/]+$") or ""
						if folder == nil then folder = dir elseif folder ~= dir then folder = false end
					end
					local vehicles = {}
					for i, vehicle in ipairs(data.vehicles) do
						local old = lowerPath(tostring(vehicle.name or ""))
						if not lowerNames[OLD.model .. old] then
							report.missing[#report.missing + 1] = string.format("model %s (multiple unit %s)", old, unitName)
						end
						-- beside the unit file a bare name is enough; otherwise from the content root
						vehicles[i] = { name = folder and (old:match("([^/]+)$")) or ("/" .. old), forward = vehicle.forward ~= false }
					end
					local unit = { vehicles = vehicles, name = data.name, desc = data.desc, filterTags = { "default" } }
					if type(data.groupFileName) == "string" and data.groupFileName ~= "" then
						local leader = data.groupFileName:lower():gsub("%.lua$", "")
						if leader ~= unitName and lowerNames["res/config/multiple_unit/" .. leader .. ".lua"] then
							unit.groupFileName = leader .. ".mu"
						end
					end
					local where = (folder and folder ~= "") and (folder .. "/") or (folder == "" and "" or "multiple_unit/")
					host.write(dst .. "/content/" .. where .. unitName .. ".mu.lua", C.dataFileText(unit))
					report.counts.units = (report.counts.units or 0) + 1
				elseif not data then
					report.problems[#report.problems + 1] = string.format("multiple unit %s not converted: %s", unitName, why)
				end
			end
		end
	end

	-- kinds of track: res/config/track/<name>.lua -> content/track/<name>.street.lua and its two templates
	local ownTracks = {}
	if C.layout == "content" then
		local refs = {}
		function refs.model(old)
			local low = lowerPath(old)
			if lowerNames[OLD.model .. low] then return "/" .. NEW.model .. low end
			local theirs = job.elsewhere(OLD.model .. low)
			return theirs and (theirs .. "::/" .. NEW.model .. low) or nil
		end
		function refs.material(old)
			local low = lowerPath(old)
			if lowerNames[OLD.material .. low] then return "/" .. NEW.material .. low end
			local theirs = job.elsewhere(OLD.material .. low)
			return theirs and (theirs .. "::/" .. NEW.material .. low) or nil
		end
		function refs.icon(file)
			return lowerNames[OLD.texture .. "ui/tracks/" .. file] and ("/" .. NEW.texture .. "ui/tracks/" .. file) or nil
		end
		for _, f in ipairs(files) do
			local name = lowerPath(f):match("^res/config/track/([^/]+)%.lua$")
			if name then
				local data, why = C.readData(host.read(src .. "/" .. f), f, libraries)
				if type(data) == "table" then
					handled[f] = true
					local style, plain, wired = C.trackFiles(data, name, refs)
					host.write(dst .. "/content/track/" .. name .. ".street.lua", C.dataFileText(style))
					host.write(dst .. "/content/track/" .. name .. ".street_template.lua", C.dataFileText(plain))
					host.write(dst .. "/content/track/" .. name .. "_catenary.street_template.lua", C.dataFileText(wired))
					ownTracks[#ownTracks + 1] = name
					report.counts.tracks = (report.counts.tracks or 0) + 1
				else
					report.problems[#report.problems + 1] = string.format("kind of track %s not converted: %s", name, tostring(why))
				end
			end
		end
	end

	-- Transport Fever 2 stations: the construction, its modules and the mod's helper scripts
	if C.layout == "content" and options.stations then
		local shimText = host.resource and host.resource("station_shim.lua")
		local constructions, modules, scripts = {}, {}, {}
		for _, f in ipairs(files) do
			local low = lowerPath(f)
			if startsWith(low, "res/construction/") and endsWith(low, ".con") then constructions[#constructions + 1] = f
			elseif startsWith(low, "res/construction/") and endsWith(low, ".module") then modules[#modules + 1] = f
			elseif startsWith(low, "res/scripts/") and endsWith(low, ".lua") then scripts[#scripts + 1] = f end
		end
		if (#constructions > 0 or #modules > 0) and not shimText then
			report.problems[#report.problems + 1] = "the station files are not converted: this build of the converter has no station library"
		elseif #constructions > 0 or #modules > 0 then
			local modId = modIdFrom(folderName)
			local own, unknown = {}, {}
			for _, f in ipairs(scripts) do own[lowerPath(f):sub(#"res/scripts/" + 1):gsub("%.lua$", "")] = true end
			local function names(list, cut)
				local parts = {}
				for _, f in ipairs(list) do parts[#parts + 1] = "[" .. quoted(lowerPath(f):sub(cut + 1)) .. "] = true" end
				return table.concat(parts, ", ")
			end
			local models = {}
			for _, f in ipairs(files) do
				local low = lowerPath(f)
				if startsWith(low, OLD.model) and endsWith(low, ".mdl") then models[#models + 1] = f end
			end
			local filled = shimText:gsub("@MOD_ID@", (modId:gsub("%%", "%%%%")), 1)
			filled = filled:gsub("@OWN_MODULES@", (names(modules, #"res/construction/"):gsub("%%", "%%%%")), 1)
			filled = filled:gsub("@OWN_MODELS@", (names(models, #OLD.model):gsub("%%", "%%%%")), 1)
			-- models and modules of the other old mods, for the names this mod's scripts use: only those that a
			-- script of this mod names
			local texts = {}
			for _, list in ipairs({ constructions, modules, scripts }) do
				for _, f in ipairs(list) do texts[#texts + 1] = (host.read(src .. "/" .. f) or ""):lower() end
			end
			local allText = table.concat(texts, "\n")
			local otherModels, otherModules = {}, {}
			for _, other in ipairs(siblings) do
				for _, path in ipairs(sortedKeys(other.files)) do
					local key, into
					if startsWith(path, OLD.model) and endsWith(path, ".mdl") then key, into = path:sub(#OLD.model + 1), otherModels
					elseif startsWith(path, "res/construction/") and endsWith(path, ".module") then key, into = path:sub(#"res/construction/" + 1), otherModules end
					if key and not lowerNames[path] and allText:find(key, 1, true) then
						into[#into + 1] = "[" .. quoted(key) .. "] = " .. quoted(other.modId)
						useSibling(other)
					end
				end
			end
			-- kinds of track: this mod's own, and those of the other old mods that its scripts name
			local ownTrackParts, otherTrackParts = {}, {}
			for _, name in ipairs(ownTracks) do ownTrackParts[#ownTrackParts + 1] = "[" .. quoted(name) .. "] = true" end
			for _, other in ipairs(siblings) do
				for _, path in ipairs(sortedKeys(other.files)) do
					local name = path:match("^res/config/track/([^/]+)%.lua$")
					if name and not lowerNames[path] and allText:find(name .. ".lua", 1, true) then
						otherTrackParts[#otherTrackParts + 1] = "[" .. quoted(name) .. "] = " .. quoted(other.modId)
						useSibling(other)
					end
				end
			end
			local ownTracksText, otherTracksText = table.concat(ownTrackParts, ", "), table.concat(otherTrackParts, ", ")
			filled = filled:gsub("@OWN_TRACKS@", function() return ownTracksText end, 1)
			filled = filled:gsub("@OTHER_TRACKS@", function() return otherTracksText end, 1)
			local otherModelsText, otherModulesText = table.concat(otherModels, ", "), table.concat(otherModules, ", ")
			filled = filled:gsub("@OTHER_MODELS@", function() return otherModelsText end, 1)
			filled = filled:gsub("@OTHER_MODULES@", function() return otherModulesText end, 1)
			-- The walking lanes the models carried. In the newer game lanes belong to the station, so the
			-- library hands them over when a station is built.
			local lanes, lanesCount = {}, 0
			-- ... and the stops ("terminals") they carried: which of those lanes people wait on, and where the
			-- vehicle stands. In the newer game these too belong to the station.
			local terminals = {}
			for _, f in ipairs(models) do
				local data = C.readData(host.read(src .. "/" .. f), f, libraries)
				local provider = type(data) == "table" and type(data.metadata) == "table" and data.metadata.transportNetworkProvider
				local lists = type(provider) == "table" and provider.laneLists
				local stops = type(provider) == "table" and provider.terminals
				if type(stops) == "table" and #stops > 0 then
					local kept = {}
					for _, stop in ipairs(stops) do
						if type(stop) == "table" then
							kept[#kept + 1] = { personNodes = type(stop.personNodes) == "table" and stop.personNodes or {},
								personEdges = type(stop.personEdges) == "table" and stop.personEdges or {}, vehicleNode = tonumber(stop.vehicleNode) }
						end
					end
					if #kept > 0 then terminals[lowerPath(f):sub(#OLD.model + 1)] = kept end
				end
				if type(lists) == "table" and #lists > 0 then
					local kept = {}
					for _, lane in ipairs(lists) do
						-- (a list without nodes is kept too: the stops count the lists and their nodes in order)
						if type(lane) == "table" and type(lane.nodes) == "table" then
							kept[#kept + 1] = {
								nodes = lane.nodes, speedLimit = lane.speedLimit, transportModes = lane.transportModes,
								linkable = lane.linkable, forwardOnly = lane.forwardOnly, needsReservation = lane.needsReservation,
							}
						end
					end
					if #kept > 0 then
						lanes[lowerPath(f):sub(#OLD.model + 1)] = kept
						lanesCount = lanesCount + 1
					end
				end
			end
			local lanesOut = {}
			serialize(lanes, "", lanesOut)
			local lanesText = table.concat(lanesOut)
			filled = filled:gsub("@OWN_LANES@", function() return lanesText end, 1)
			local terminalsOut = {}
			serialize(terminals, "", terminalsOut)
			local terminalsText = table.concat(terminalsOut)
			filled = filled:gsub("@OWN_TERMINALS@", function() return terminalsText end, 1)
			filled = filled:gsub("@DEBUG@", options.stationDebug and "true" or "false", 1)
			report.counts.stationLaneModels = lanesCount
			host.write(dst .. "/content/tf3api_legacy/shim.lua", filled)
			-- What hides the terrain. In the older game a ground face with the "hole" texture cut the terrain
			-- away (under stairs down to an underpass, say). In the newer game that texture is plain sand; the
			-- terrain is hidden by a box on a model inside which the terrain is not drawn (the game's own
			-- underpass and tunnel portal models carry such boxes, as entries of their light list with
			-- mode = "DISCARD"). These are models that are nothing but such a box, in a set of sizes the station
			-- library puts together to cover a hole face of any size.
			for _, across in ipairs(C.cutUnits) do
				for _, along in ipairs(C.cutUnits) do
					host.write(dst .. "/content/tf3api_legacy/cut/cut_" .. along .. "x" .. across .. ".mdl", C.cutModelText(along * C.cutStep, across * C.cutStep))
				end
			end

			for _, f in ipairs(scripts) do
				if not (job.scriptsUsed and job.scriptsUsed[f]) then
					handled[f] = true
					local rel = lowerPath(f):sub(#"res/scripts/" + 1)
					host.write(dst .. "/content/scripts/" .. rel, C.stationScriptText(host.read(src .. "/" .. f) or "", modId, own, unknown))
				end
			end
			local function carry(list, kind, dataFn, functionsFn)
				for _, f in ipairs(list) do
					local rel = lowerPath(f):sub(#"res/construction/" + 1)
					local source = host.read(src .. "/" .. f) or ""
					local text = legacyText(C.stationScriptText(source, modId, own, unknown))
					-- A construction that is a whole station or depot of its own, not put together from modules:
					-- its tracks, platforms and stops are laid out the older game's way, which the newer game
					-- stops on when it is placed. Not offered until that is converted too.
					local oldType = source:match('[%s,{]type%s*=%s*"([%u_]+)"')
					local wholeStation = kind == "construction" and oldType ~= nil and C.wholeStationTypes[oldType]
						and not source:find("createTemplateFn", 1, true) and not source:find("constructionTemplates", 1, true)
					if not text then
						report.problems[#report.problems + 1] = string.format("%s %s not converted: it has no data() function", kind, rel)
					elseif wholeStation then
						handled[f] = true
						report.problems[#report.problems + 1] = string.format("construction %s not converted: a whole %s that is not built from modules (not supported yet)", rel, oldType:lower():gsub("_", " "))
					else
						handled[f] = true
						local head = 'local shim = require "' .. modId .. '::/tf3api_legacy/shim.lua"\n'
							.. 'local legacy = require "' .. modId .. "::/" .. rel .. '.legacy.lua"\n\n'
						host.write(dst .. "/content/" .. rel .. ".legacy.lua", text)
						host.write(dst .. "/content/" .. rel .. ".lua", head .. "function data()\n\treturn shim." .. dataFn
							.. "(legacy(), " .. quoted(modId .. "::/" .. rel .. ".script") .. ")\nend\n")
						host.write(dst .. "/content/" .. rel .. ".script.lua", head .. "function data()\n\treturn shim." .. functionsFn .. "(legacy())\nend\n")
						report.counts[kind] = (report.counts[kind] or 0) + 1
					end
				end
			end
			carry(modules, "module", "moduleData", "moduleFunctions")
			carry(constructions, "construction", "constructionData", "constructionFunctions")
			for name in pairs(unknown) do
				report.problems[#report.problems + 1] = "a station script asks for the library \"" .. name .. "\", which the converter does not know; what it does there is skipped"
			end
			report.notes[#report.notes + 1] = string.format("station files carried over: %d constructions, %d modules, %d helper scripts (experimental)",
				report.counts.construction or 0, report.counts.module or 0, #scripts)
		end
	end

	if job.needStandInMaterial then
		local plain = C.convertMaterial({ type = "PHYSICAL", order = 0, params = {
			map_albedo = { fileName = C.defaultTextures.grey.name, isDefault = true, type = "TWOD", wrapS = "REPEAT", wrapT = "REPEAT" },
		} }, "converter/missing.mtl", job)
		job.needDefault.grey = true
		host.write(dst .. "/content/" .. NEW.material .. "converter/missing.mtl", C.dataFileText(plain))
	end
	for which in pairs(job.needDefault) do
		local texture = C.defaultTextures[which]
		host.write(out("texture", texture.name), texture.bytes)
		if C.layout == "content" then textureCache[NEW.texture .. texture.name] = C.textureInfo(texture.name, texture.bytes) end
	end
	if next(textureCache) ~= nil then host.write(dst .. "/texture_metadata_cache.lua", C.dataFileText(textureCache)) end

	-- the mod's description and its texts
	local info, strings = {}, {}
	local stringsFile = lowerNames["strings.lua"]
	if stringsFile then
		handled[stringsFile] = true
		local data = C.readData(host.read(src .. "/" .. stringsFile), stringsFile, libraries)
		if data then
			for language, texts in pairs(data) do
				if type(language) == "string" and type(texts) == "table" then
					strings[language] = {}
					for key, text in pairs(texts) do
						if type(key) == "string" and type(text) == "string" then strings[language][key] = text end
					end
				end
			end
			if next(strings) ~= nil then host.write(dst .. "/strings.json", C.jsonText(strings)) end
		end
	end
	for _, name in ipairs({ "mod.lua", "info.lua" }) do   -- info.lua: Train Fever
		local real = lowerNames[name]
		if real and next(info) == nil then
			handled[real] = true
			local data, why = C.readData(host.read(src .. "/" .. real), real, libraries)
			if data then
				info = type(data.info) == "table" and data.info or data
				if type(data.runFn) == "function" then
					report.notConverted[#report.notConverted + 1] = name .. ": the mod's own script (runFn) is not carried over"
				end
			else
				report.problems[#report.problems + 1] = string.format("%s not read: %s", name, why)
			end
		end
	end
	local function plain(v)
		if type(v) == "table" and getmetatable(v) == Translated then
			local texts = strings.en or strings[next(strings) or ""] or {}
			return texts[v.key] or v.key
		end
		return type(v) == "string" and v or nil
	end
	local modId = modIdFrom(folderName)
	-- the other old mods this one uses files of: it needs them, converted, to be enabled with it
	local dependencies = {}
	for _, otherId in ipairs(sortedKeys(job.usedSiblings)) do
		local used = job.usedSiblings[otherId]
		dependencies[#dependencies + 1] = {
			mod = { modId = otherId, revisionMin = -1, revisionMax = -1 },
			modInfo = { displayName = used.folder, url = "" },
			loadBefore = true,
			optional = false,
		}
		report.needs = report.needs or {}
		report.needs[#report.needs + 1] = string.format("%s (the old mod \"%s\"): %d of its files or names are used", otherId, used.folder, used.count)
	end
	local modJson = {
		modId = modId,
		revision = 1,
		severityAdd = "None",
		severityRemove = "Warning",
		cosmetic = false,
		name = plain(info.name) or folderName,
		description = plain(info.description) or "",
	}
	if #dependencies > 0 then modJson.dependencies = dependencies end
	if C.layout == "content" and options.sourceCheck ~= false then
		host.write(dst .. "/content/mod.script.lua", C.sourceCheckText(modId, folderName))
		modJson.runScript = { fileName = modId .. "::/mod.script@runFn" }
		local notice = "Converted on this machine by TF3OpenAPI from the old mod \"" .. folderName .. "\", which has to stay in legacy_mods. The original author's work: not for redistribution."
		modJson.description = (modJson.description ~= "" and (modJson.description .. "\n\n") or "") .. notice
	end
	host.write(dst .. "/mod.json", C.jsonText(modJson))

	for f in pairs(job.scriptsUsed or {}) do
		handled[f] = true
		report.notes[#report.notes + 1] = f .. ": run during the conversion; what it produced is written into the models"
	end
	for _, f in ipairs(files) do
		if not handled[f] then report.notConverted[#report.notConverted + 1] = f end
	end
	for lib in pairs(missingLibraries) do
		report.problems[#report.problems + 1] = "a file uses the script library \"" .. lib .. "\", which the converter does not have; values from it are left out"
	end

	local lines = {
		"Conversion report - " .. folderName .. " -> " .. modId,
		"Converter " .. C.version,
		"",
		string.format("Multiple units: %d   Sound sets: %d   Kinds of track: %d", report.counts.units or 0, report.counts.soundSets or 0, report.counts.tracks or 0),
		string.format("Models: %d (%d of them in the old group form)   Meshes: %d   Materials: %d   Textures: %d   Animation files: %d",
			report.counts.models, report.counts.oldModels, report.counts.meshes, report.counts.materials, report.counts.textures, report.counts.animations),
	}
	local function section(title, list)
		table.sort(list)
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("%s (%d)", title, #list)
		local last
		for _, item in ipairs(list) do
			if item ~= last then lines[#lines + 1] = "  " .. item end
			last = item
		end
	end
	if report.counts.stockDefaults then
		report.notes[#report.notes + 1] = string.format("%d times a material named one of the older game's own stand-in textures (default_..., unknown_...); the converter's plain ones are used", report.counts.stockDefaults)
	end
	section("Needs these other converted mods to be enabled with it", report.needs or {})
	section("Problems", report.problems)
	section("Referred to but not in the mod (often a file of the older game itself)", report.missing)
	section("Carried over unchanged (not checked by the converter)", report.carried)
	section("Not converted", report.notConverted)
	section("Notes", report.notes)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "The converted mod is the work of the original author. Do not share it without their permission."
	report.text = table.concat(lines, "\n") .. "\n"
	report.modId = modId
	-- nothing the converter handles was in the folder: the caller should not make a mod of it
	report.empty = (report.counts.models + report.counts.materials + report.counts.meshes + report.counts.textures) == 0
	host.write(dst .. "/conversion_report.txt", report.text)
	return report
end

return C
