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
local function plainTexture(r, g, b)
	local parts = { "DDS ", u32(124), u32(0x100F), u32(4), u32(4), u32(16), u32(0), u32(0) }
	for _ = 1, 11 do parts[#parts + 1] = u32(0) end
	parts[#parts + 1] = u32(32) .. u32(0x41) .. u32(0) .. u32(32) .. u32(0x00FF0000) .. u32(0x0000FF00) .. u32(0x000000FF) .. u32(0xFF000000)
	parts[#parts + 1] = u32(0x1000) .. u32(0) .. u32(0) .. u32(0) .. u32(0)
	parts[#parts + 1] = string.rep(string.char(b, g, r, 255), 16)
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
function C.convertMaterial(data, id, job)
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
		if type(params.alpha_test) ~= "table" then params.alpha_test = { alphaThreshold = 0.5 } end
		params.alpha_test.cutout = true
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
			if file ~= "" and not job.lowerNames[lowerPath(OLD.texture .. file)] then
				local which = name:find("normal", 1, true) and "normal" or name == "map_metal_gloss_ao" and "mga"
					or name == "map_emissive" and "dark" or "grey"
				report.missing[#report.missing + 1] = string.format("texture %s (material %s); a plain %s texture stands in", file, id, which == "dark" and "lamp-coloured" or which)
				entry.fileName = C.defaultTextures[which].name
				entry.isDefault = true
				job.needDefault[which] = true
			end
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
					if type(v) ~= "table" and k ~= "isDefault" then sampler[k] = v end
				end
				sampler.fileName = newRef("texture", file)
				if name:find("normal", 1, true) then
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
			if glows and job.meshPoints then lamps[#lamps + 1] = { node = node, world = world, points = job.meshPoints(node.oldMesh) } end
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
		metadata.maintenance.lifespan = (tonumber(metadata.maintenance.lifespan) or 40) * 730.5   -- years -> days
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
		if not job.lowerNames[lowerPath(OLD.mesh .. node.mesh)] then
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
			for _, lod in ipairs(data.lods) do
				local lamps = {}
				local function find(node, world)
					if type(node) ~= "table" then return end
					world = C.transf.mul(world, type(node.transf) == "table" and #node.transf == 16 and node.transf or IDENTITY)
					local colour = type(node.mesh) == "string" and not job.lowerNames[lowerPath(OLD.mesh .. node.mesh)] and stockLamp(node.mesh)
					if colour then
						report.notes[#report.notes + 1] = string.format("model %s: stock lamp %s replaced by a plain %s lamp", modelId, node.mesh, colour)
						local carrier = type(data.metadata) == "table" and type(data.metadata.transportVehicle) == "table" and data.metadata.transportVehicle.carrier
						local rail = (carrier == "RAIL" or carrier == "TRAM")
						node.mesh = job.standInLamp(colour, rail)
						node.materials = { job.standInLampMaterial(colour, rail) }
						node.standIn = true
						if node.name == nil then
							named = named + 1
							node.name = "converter_lamp_" .. named
						end
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
				report.notes[#report.notes + 1] = string.format("model %s: its variant group %s is not a model of the mod; it is listed on its own", modelId, vehicle.groupFileName)
				vehicle.groupFileName = nil
			end
		end
	end
	if C.layout == "content" then newVersion(data, modelId, job) end
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
-- a whole mod

local function modIdFrom(folderName)
	local id = folderName:lower():gsub("[^a-z0-9_]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
	if id == "" then id = "mod" end
	return "legacy_" .. id
end

-- host: see the top of the file. src, dst: folders. folderName: the old mod's folder name.
-- Returns the report table; report.text is what is also written to <dst>/conversion_report.txt.
function C.convertMod(host, src, dst, folderName)
	local report = { missing = {}, notes = {}, problems = {}, notConverted = {}, carried = {}, counts = { models = 0, oldModels = 0, meshes = 0, materials = 0, textures = 0, animations = 0 } }
	local files = host.list(src)
	table.sort(files)
	local lowerNames = {}
	for _, f in ipairs(files) do lowerNames[lowerPath(f)] = f end
	local job = { host = host, src = src, lowerNames = lowerNames, report = report, needDefault = {}, usedMaterials = {}, hiddenParts = {} }
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

	-- the converter's own lamp, written once when a model needs it
	local lampWritten = {}
	-- For rail vehicles the lamp uses the newer game's own lamp material and lamp picture, as its own trains do:
	-- one texture with the white lamp in the top left quarter and the red one below it (read off the texture
	-- points of the game's own head and rear lamp meshes). Other vehicles get a plain glowing colour.
	function job.standInLamp(colour, rail)
		local id = "converter/lamp" .. (rail and ("_" .. colour) or "") .. ".msh"
		if not lampWritten[id] then
			lampWritten[id] = true
			local text, blob
			if rail then text, blob = C.lampMesh(0.09, 16, 0.25, (colour == "red") and 0.75 or 0.25, 0.21)
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

	-- models
	for _, f in ipairs(files) do
		local low = lowerPath(f)
		if startsWith(low, OLD.model) and endsWith(low, ".mdl") then
			handled[f] = true
			local id = low:sub(#OLD.model + 1)
			local data, why = C.readData(host.read(src .. "/" .. f), f, libraries)
			local model, form
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
			else
				report.problems[#report.problems + 1] = string.format("material %s not converted: %s", id, why)
			end
		elseif startsWith(low, OLD.animation) then
			handled[f] = true
			host.copy(src .. "/" .. f, out("animation", low:sub(#OLD.animation + 1), f))
			report.counts.animations = report.counts.animations + 1
		elseif job.iconFiles[f] then
			handled[f] = true   -- already placed beside its model
		elseif startsWith(low, OLD.texture) then
			handled[f] = true
			host.copy(src .. "/" .. f, out("texture", low:sub(#OLD.texture + 1), f))
			report.counts.textures = report.counts.textures + 1
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
	host.write(dst .. "/mod.json", C.jsonText({
		modId = modId,
		revision = 1,
		severityAdd = "None",
		severityRemove = "Warning",
		cosmetic = false,
		name = plain(info.name) or folderName,
		description = plain(info.description) or "",
	}))

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
		string.format("Multiple units: %d   Sound sets: %d", report.counts.units or 0, report.counts.soundSets or 0),
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
