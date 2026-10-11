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

local C = { version = "0.1" }

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

local function copyValue(v)
	if type(v) ~= "table" then return v end
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

local stubs = setmetatable({}, { __mode = "k" })   -- values that came out of a require'd library we do not have
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

-- returns the table the file's data() gives, or nil and the reason; "used" collects the libraries it asked for
function C.readData(text, name, used)
	if not text then return nil, "file not found" end
	if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
	local env = {
		_ = function(key) return setmetatable({ key = tostring(key) }, Translated) end,
		math = math, string = string, table = table, pairs = pairs, ipairs = ipairs, next = next, select = select,
		tostring = tostring, tonumber = tonumber, type = type, unpack = unpack or table.unpack,
		require = function(lib)
			if used then used[tostring(lib)] = true end
			return makeStub()
		end,
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

local function newRef(kind, id) return "/" .. NEW[kind] .. lowerPath(id) end

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
	return { node = root, static = lod.static, visibleFrom = lod.visibleFrom, visibleTo = lod.visibleTo }
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
							if type(part) == "string" and endsWith(part:lower(), ".msh") and not startsWith(part, "/") then
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
	if type(node.mesh) == "string" then
		if not job.lowerNames[lowerPath(OLD.mesh .. node.mesh)] then
			report.missing[#report.missing + 1] = string.format("mesh %s (model %s)", node.mesh, modelId)
		end
		node.mesh = newRef("mesh", node.mesh)
	end
	if type(node.materials) == "table" then
		for i, material in ipairs(node.materials) do
			if type(material) == "string" then
				if not job.lowerNames[lowerPath(OLD.material .. material)] then
					report.missing[#report.missing + 1] = string.format("material %s (model %s)", material, modelId)
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

-- returns the converted model, and "old" or "tree" for the form it was in
function C.convertModel(data, modelId, job)
	local report = job.report
	if type(data.lods) ~= "table" or #data.lods == 0 then return nil, "has no levels of detail" end
	local first = data.lods[1]
	if type(first) ~= "table" then return nil, "its first level of detail is not a table" end
	local form
	if type(first.node) == "table" then
		form = "tree"
		for _, lod in ipairs(data.lods) do moveTreeReferences(lod.node, job, modelId) end
	else
		form = "old"
		job.hiddenParts = hiddenPartsOf(data.metadata)
		local lods = {}
		for i, lod in ipairs(data.lods) do lods[i] = C.oldLodToTree(lod, job, modelId) end
		data.lods = lods
		oldMetadata(data.metadata)
		if type(data.collider) ~= "table" then data.collider = { params = {}, transf = IDENTITY, type = "MESH" } end
		data.version = 1
	end
	movePartNames(data.metadata)
	if type(data.metadata) == "table" and type(data.metadata.transportVehicle) == "table" then
		local cargos = {}
		for _, capacity in ipairs(type(data.metadata.transportVehicle.capacities) == "table" and data.metadata.transportVehicle.capacities or {}) do
			if capacity.type then cargos[#cargos + 1] = tostring(capacity.type) end
		end
		if #cargos > 0 then report.notes[#report.notes + 1] = string.format("model %s carries: %s (check these cargo names exist in Transport Fever 3)", modelId, table.concat(cargos, ", ")) end
	end
	return data, form
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
	local report = { missing = {}, notes = {}, problems = {}, notConverted = {}, counts = { models = 0, oldModels = 0, meshes = 0, materials = 0, textures = 0, animations = 0 } }
	local files = host.list(src)
	table.sort(files)
	local lowerNames = {}
	for _, f in ipairs(files) do lowerNames[lowerPath(f)] = f end
	local job = { host = host, src = src, lowerNames = lowerNames, report = report, needDefault = {}, usedMaterials = {}, hiddenParts = {} }
	local libraries = {}

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

	local content = dst .. "/content/"
	local handled = {}

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
				host.write(content .. NEW.model .. id, C.dataFileText(model))
				report.counts.models = report.counts.models + 1
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
					host.write(content .. NEW.mesh .. id, info.text)
					report.counts.meshes = report.counts.meshes + 1
				else
					report.problems[#report.problems + 1] = string.format("mesh %s not converted: %s", id, tostring(meshes[lowerPath(id)].failed))
				end
			else
				host.copy(src .. "/" .. f, content .. NEW.mesh .. id)   -- the .blob with the numbers
			end
		elseif startsWith(low, OLD.group) then
			handled[f] = true   -- groups are folded into the models
		elseif startsWith(low, OLD.material) and endsWith(low, ".mtl") then
			handled[f] = true
			local id = low:sub(#OLD.material + 1)
			local data, why = C.readData(host.read(src .. "/" .. f), f, libraries)
			if data then
				host.write(content .. NEW.material .. id, C.dataFileText(C.convertMaterial(data, id, job)))
				report.counts.materials = report.counts.materials + 1
			else
				report.problems[#report.problems + 1] = string.format("material %s not converted: %s", id, why)
			end
		elseif startsWith(low, OLD.animation) then
			handled[f] = true
			host.copy(src .. "/" .. f, content .. NEW.animation .. low:sub(#OLD.animation + 1))
			report.counts.animations = report.counts.animations + 1
		elseif startsWith(low, OLD.texture) then
			handled[f] = true
			host.copy(src .. "/" .. f, content .. NEW.texture .. low:sub(#OLD.texture + 1))
			report.counts.textures = report.counts.textures + 1
		end
	end
	for which in pairs(job.needDefault) do
		local texture = C.defaultTextures[which]
		host.write(content .. NEW.texture .. texture.name, texture.bytes)
	end

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

	for _, f in ipairs(files) do
		if not handled[f] then report.notConverted[#report.notConverted + 1] = f end
	end
	for lib in pairs(libraries) do
		report.problems[#report.problems + 1] = "a file uses the script library \"" .. lib .. "\", which the converter does not have; values from it are left out"
	end

	local lines = {
		"Conversion report - " .. folderName .. " -> " .. modId,
		"Converter " .. C.version,
		"",
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
	section("Not converted", report.notConverted)
	section("Notes", report.notes)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "The converted mod is the work of the original author. Do not share it without their permission."
	report.text = table.concat(lines, "\n") .. "\n"
	report.modId = modId
	host.write(dst .. "/conversion_report.txt", report.text)
	return report
end

return C
