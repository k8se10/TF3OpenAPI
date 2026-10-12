-- Shipped inside a converted Transport Fever 2 station mod (as tf3api_legacy/shim.lua, with the placeholders
-- below filled in by the converter). It lets the mod's own construction and module scripts, carried over as
-- they were written, run inside Transport Fever 3:
--   * every function of the newer game gets one more first argument;
--   * names changed: models, modules, tracks, ground textures, pictures;
--   * a station of the newer game is its own modular station: the mod's construction keeps its name, its
--     parameters and its starting layout, and is built, updated and upgraded by the game's own station script;
--   * the newer game's modules put what they build into the station's inner part (result.cargoStation), and
--     the numbers of name and platform boards count the models of that part: the mod's modules are given that
--     part as their result too;
--   * where people walk belongs to the station in the newer game, not to the models: the lanes the mod's
--     models carried are handed to the station when it is finished.
-- Nothing in here is the game's code; it only calls the game's scripts by name.
--
-- On names. From inside a mod a bare "/..." means the mod's own files; the game's files are "::/...". The
-- game's own station scripts write bare names, and its table of walking lanes for its own models is keyed by
-- bare names. So while a station is being put together the game's models keep bare names, and when it is
-- finished every name still bare is given the "::" in front.

local shim = {}

shim.modId = "@MOD_ID@"
shim.ownModules = { @OWN_MODULES@ }
shim.ownModels = { @OWN_MODELS@ }
-- the walking lanes the mod's models carried in the older game, by model
shim.ownLanes = @OWN_LANES@
-- true: the lanes of the station last built are written to tf3api_out/station_lanes_<mod>.txt
shim.debug = @DEBUG@

local STOCK_STATION = "::/stations/rail/modular_station/modular_station.script"
-- the ground texture that cuts the terrain away, exactly as the game's own modules write it
local HOLE = "/infrastructure/shared/hole.gtex"

-- the older game's track modules -> the newer game's tracks
local TRACKS = {
	["station/rail/modular_station/platform_track.module"] = "::/trainstation___/infrastructure/track/standard/standard.street_template",
	["station/rail/modular_station/platform_track_catenary.module"] = "::/trainstation___/infrastructure/track/standard/standard_catenary.street_template",
	["station/rail/modular_station/platform_high_speed_track.module"] = "::/trainstation___/infrastructure/track/high_speed/high_speed.street_template",
	["station/rail/modular_station/platform_high_speed_track_catenary.module"] = "::/trainstation___/infrastructure/track/high_speed/high_speed_catenary.street_template",
}

local function lower(s) return (tostring(s):gsub("\\", "/"):lower()) end

function shim.moduleName(old)
	if type(old) ~= "string" then return old end
	local key = lower(old)
	if shim.ownModules[key] then return shim.modId .. "::/" .. key end
	if TRACKS[key] then return TRACKS[key] end
	if key:sub(1, 1) == "/" or key:find("::", 1, true) then return old end
	if key:sub(1, 8) == "station/" then return "::/stations/" .. key:sub(9) end
	return "::/" .. key
end

-- a model's name while the station is being put together: the mod's own with the mod in front, the game's bare
function shim.modelName(old)
	if type(old) ~= "string" then return old end
	local key = lower(old)
	if key:sub(1, 1) == "/" or key:find("::", 1, true) then return old end
	if shim.ownModels[key] then return shim.modId .. "::/" .. key end
	if key:sub(1, 8) == "station/" then return "/stations/" .. key:sub(9) end
	if key:sub(1, 6) == "asset/" then return "/assets/" .. key:sub(7) end
	return "/" .. key
end

-- a finished name: one that is still bare is the game's
local function final(name)
	if type(name) == "string" and name:sub(1, 1) == "/" then return "::" .. name end
	return name
end

function shim.groundTexture(old)
	if type(old) ~= "string" then return old end
	local key = lower(old)
	if key:sub(1, 1) == "/" or key:find("::", 1, true) then return old end
	if key == "street_border.lua" then return "/infrastructure/street/shared/street_border.gtex" end
	-- "hole" is what cuts the terrain away, e.g. where an underpass goes below ground
	if key == "hole.lua" then return HOLE end
	local name = key:match("^shared/([%w_]+)%.gtex%.lua$")
	if name then return "/terrain/materials/" .. name .. "/" .. name .. ".gtex" end
	return old
end

function shim.icon(old)
	if type(old) ~= "string" or old == "" then return old end
	if old:sub(1, 1) == "/" or old:find("::", 1, true) then return old end
	return shim.modId .. "::/textures/" .. lower(old)
end

-- a copy without the functions (the newer game's data files hold none)
local function dataOf(v, seen)
	if type(v) == "function" then return nil end
	if type(v) ~= "table" then return v end
	seen = seen or {}
	if seen[v] then return nil end
	seen[v] = true
	local out = {}
	for k, x in pairs(v) do
		local y = dataOf(x, seen)
		if y ~= nil then out[k] = y end
	end
	seen[v] = nil
	return out
end

-- what the old script added to the result gets the newer names
local function renameAdded(result, modelsBefore, groundBefore)
	if type(result) ~= "table" then return end
	if type(result.models) == "table" then
		for i = modelsBefore + 1, #result.models do
			local m = result.models[i]
			if type(m) == "table" then m.id = shim.modelName(m.id) end
		end
	end
	if type(result.groundFaces) == "table" then
		for i = groundBefore + 1, #result.groundFaces do
			local g = result.groundFaces[i]
			if type(g) == "table" and type(g.modes) == "table" then
				for _, mode in ipairs(g.modes) do
					if type(mode) == "table" then mode.key = shim.groundTexture(mode.key) end
				end
			end
		end
	end
end

local function menuCategory(category, order)
	return { categories = { { category = category, order = order or 5000 } } }
end

-- How high the mod's platforms are: the height most of its walking lanes lie at. The newer game's track
-- lays the lanes people wait on at the height of its own platforms (1.1 m); the older game's platforms, and
-- the mod's with them, are higher (1.5 m in the mods seen). Left as they are, people stand sunk into the
-- platform, and the waiting lanes do not meet the mod's lanes, so people jump to the platform instead of
-- walking there.
local platformHeight
local function ownPlatformHeight()
	if platformHeight == nil then
		local count, best = {}, false
		for _, lists in pairs(shim.ownLanes) do
			for _, lane in ipairs(lists) do
				for _, node in ipairs(lane.nodes) do
					local z = type(node) == "table" and type(node[1]) == "table" and tonumber(node[1][3])
					if z and z > 0 then
						count[z] = (count[z] or 0) + 1
						if not best or count[z] > count[best] then best = z end
					end
				end
			end
		end
		platformHeight = best
	end
	return platformHeight
end

-- where the mod's platform modules stand in the station being built
local platformsOf = setmetatable({}, { __mode = "k" })

-- the game's waiting lanes that lie along one of the mod's platforms are lifted to its height
local function liftWaitingLanes(result, p)
	local height, platforms = ownPlatformHeight(), platformsOf[result]
	if not height or not platforms or type(p.laneLists) ~= "table" then return end
	for _, lane in ipairs(p.laneLists) do
		local t, nodes = lane.transf, lane.nodes
		if type(t) == "table" and tonumber(t[13]) and type(nodes) == "table" and #nodes > 0 then
			-- a lane lying flat, near platform height but not at it
			local z, flat = nil, true
			for _, node in ipairs(nodes) do
				local nz = type(node) == "table" and type(node[1]) == "table" and tonumber(node[1][3])
				if not nz or (z and math.abs(nz - z) > 0.001) then flat = false break end
				z = nz
			end
			if flat and z > 0 and math.abs(z - height) > 0.001 and math.abs(z - height) < 1.0 then
				for _, at in ipairs(platforms) do
					local dx, dy = t[13] - at[1], t[14] - at[2]
					-- the waiting lane's own origin is 1.5 m to the side of the platform's middle
					if dx * dx + dy * dy < 2.0 * 2.0 then
						for _, node in ipairs(nodes) do node[1][3] = height end
						break
					end
				end
			end
		end
	end
end

-- a lane node's place in the station: the lane list's transform applied to the node's own position
local function placed(t, pos)
	local x, y, z = tonumber(pos[1]) or 0, tonumber(pos[2]) or 0, tonumber(pos[3]) or 0
	return t[1] * x + t[5] * y + t[9] * z + t[13], t[2] * x + t[6] * y + t[10] * z + t[14], t[3] * x + t[7] * y + t[11] * z + t[15]
end

local function isTransform(t)
	return type(t) == "table" and tonumber(t[1]) and tonumber(t[11]) and tonumber(t[13]) and tonumber(t[15])
end

-- The game's lanes are joined to the mod's. The game's buildings and platforms end their lanes where the
-- game's own platform has its lane ends, at its height; the mod's platform has lane ends at the same spots
-- but higher. Where an end of one of the game's lanes lies straight below or above a node of the mod's lanes
-- (up to 0.6 m), it is moved to it, so that people walk on instead of jumping.
local function joinLanes(p, gameLists, ownNodes)
	if #ownNodes == 0 then return end
	local cells = {}
	local function cell(x, y) return math.floor(x + 0.5) .. ":" .. math.floor(y + 0.5) end
	for _, n in ipairs(ownNodes) do
		local key = cell(n[1], n[2])
		cells[key] = cells[key] or {}
		cells[key][#cells[key] + 1] = n
	end
	for i = 1, gameLists do
		local lane = p.laneLists[i]
		local t = type(lane) == "table" and lane.transf
		-- only lane lists standing upright, where "up" in the list is "up" in the station
		if isTransform(t) and math.abs(t[11] - 1) < 0.001 and type(lane.nodes) == "table" then
			for _, node in ipairs(lane.nodes) do
				if type(node) == "table" and type(node[1]) == "table" then
					local x, y, z = placed(t, node[1])
					local best, bestGap
					for dx = -1, 1 do
						for dy = -1, 1 do
							for _, n in ipairs(cells[cell(x + dx, y + dy)] or {}) do
								local ax, ay = n[1] - x, n[2] - y
								local gap = math.abs(n[3] - z)
								if ax * ax + ay * ay < 0.15 * 0.15 and gap < 0.6 and (not bestGap or gap < bestGap) then best, bestGap = n, gap end
							end
						end
					end
					if best and bestGap > 0.001 then node[1][3] = (tonumber(node[1][3]) or 0) + (best[3] - z) end
				end
			end
		end
	end
end

-- For finding lane problems: what the station's walking lanes look like, in the station's own coordinates,
-- before and after the adapter's changes. Written through the native bridge when it is there.
local dumpCount, dumpLast = 0, nil
local function describeLanes(p, out, title, gameLists)
	out[#out + 1] = title
	for i, lane in ipairs(type(p.laneLists) == "table" and p.laneLists or {}) do
		local t = lane.transf
		local line = { string.format("  list %d %s%s modes=%s nodes=%d", i, (gameLists and i > gameLists) and "MOD" or "game",
			lane.linkable and " linkable" or "", table.concat(type(lane.transportModes) == "table" and lane.transportModes or {}, ","),
			type(lane.nodes) == "table" and #lane.nodes or 0) }
		if isTransform(t) and type(lane.nodes) == "table" then
			for k = 1, #lane.nodes - 1, 2 do
				local a, b = lane.nodes[k], lane.nodes[k + 1]
				if type(a) == "table" and type(b) == "table" and type(a[1]) == "table" and type(b[1]) == "table" then
					local ax, ay, az = placed(t, a[1])
					local bx, by, bz = placed(t, b[1])
					line[#line + 1] = string.format("    (%.2f, %.2f, %.2f) -> (%.2f, %.2f, %.2f)  w %.1f", ax, ay, az, bx, by, bz, tonumber(a[3]) or 0)
				end
			end
		else
			line[#line + 1] = "    (no usable transform: " .. type(t) .. ")"
		end
		out[#out + 1] = table.concat(line, "\n")
	end
end

local function dumpWanted()
	if not shim.debug or type(tf3api) ~= "table" or type(tf3api.writeFile) ~= "function" then return false end
	local now = type(os) == "table" and type(os.time) == "function" and os.time() or nil
	if now then
		if dumpLast and now - dumpLast < 2 then return false end
		dumpLast = now
	else
		dumpCount = dumpCount + 1
		if dumpCount > 40 then return false end
	end
	return true
end

-- The station is finished. The waiting lanes along the mod's platforms are lifted, every model of the mod that
-- carried walking lanes hands them to the part of the station it stands in, the game's lanes are joined to
-- them, and every name that is still bare gets the game's "::".
local function finish(result)
	local dump = dumpWanted() and {} or nil
	local ownPrefix = shim.modId .. "::/"
	local function part(p)
		if type(p) ~= "table" then return end
		if dump then describeLanes(p, dump, "== as the game built it") end
		liftWaitingLanes(result, p)
		local gameLists = type(p.laneLists) == "table" and #p.laneLists or 0
		local ownNodes = {}
		if type(p.models) == "table" then
			for _, m in ipairs(p.models) do
				if type(m) == "table" and type(m.id) == "string" then
					local lanes = m.id:sub(1, #ownPrefix) == ownPrefix and shim.ownLanes[lower(m.id:sub(#ownPrefix + 1))]
					if lanes and m.transf then
						if type(p.laneLists) ~= "table" then p.laneLists = {} end
						for _, lane in ipairs(lanes) do
							p.laneLists[#p.laneLists + 1] = {
								transf = m.transf, nodes = lane.nodes, speedLimit = lane.speedLimit,
								transportModes = lane.transportModes, linkable = lane.linkable,
								forwardOnly = lane.forwardOnly, needsReservation = lane.needsReservation,
							}
							if isTransform(m.transf) then
								for _, node in ipairs(lane.nodes) do
									if type(node) == "table" and type(node[1]) == "table" then
										ownNodes[#ownNodes + 1] = { placed(m.transf, node[1]) }
									end
								end
							end
						end
					end
					m.id = final(m.id)
				end
			end
		end
		joinLanes(p, gameLists, ownNodes)
		if dump then
			dump[#dump + 1] = string.format("== after the adapter: %d game lane lists, %d of the mod's, %d nodes of the mod's", gameLists,
				(type(p.laneLists) == "table" and #p.laneLists or 0) - gameLists, #ownNodes)
			describeLanes(p, dump, "", gameLists)
			if type(p.models) == "table" then
				dump[#dump + 1] = "== models"
				for i, m in ipairs(p.models) do
					local t = type(m) == "table" and m.transf
					dump[#dump + 1] = string.format("  %d %s at (%.2f, %.2f, %.2f)", i, tostring(type(m) == "table" and m.id),
						isTransform(t) and t[13] or 0, isTransform(t) and t[14] or 0, isTransform(t) and t[15] or 0)
				end
			end
			local station = type(p.station) == "table" and p.station
			if station and type(station.terminals) == "table" then
				dump[#dump + 1] = "== terminals: " .. #station.terminals
			end
		end
		if type(p.groundFaces) == "table" then
			for _, g in ipairs(p.groundFaces) do
				if type(g) == "table" and type(g.modes) == "table" then
					for _, mode in ipairs(g.modes) do
						-- The face that cuts the terrain away keeps its plain name. The game does the cutting for
						-- one ground texture it knows by name (the name is in its executable); seen in the game:
						-- with "::" in front the ground was laid as ordinary sand and nothing was cut.
						if type(mode) == "table" and mode.key ~= HOLE then mode.key = final(mode.key) end
					end
				end
			end
			if dump then
				dump[#dump + 1] = "== ground faces, in order"
				for i, g in ipairs(p.groundFaces) do
					local keys = {}
					for _, mode in ipairs(type(g) == "table" and type(g.modes) == "table" and g.modes or {}) do
						keys[#keys + 1] = tostring(mode.type) .. " " .. tostring(mode.key)
					end
					local v = type(g) == "table" and type(g.face) == "table" and g.face[1]
					dump[#dump + 1] = string.format("  %d  first corner (%.1f, %.1f)  %s", i, type(v) == "table" and tonumber(v[1]) or 0,
						type(v) == "table" and tonumber(v[2]) or 0, table.concat(keys, " | "))
				end
			end
		end
	end
	local seen = {}
	if type(result.subconstructions) == "table" then
		for _, sub in ipairs(result.subconstructions) do
			if not seen[sub] then seen[sub] = true part(sub) end
		end
	end
	if not seen[result] then part(result) end
	if dump then
		local platforms = platformsOf[result] or {}
		dump[#dump + 1] = "== the mod's platform modules stand at"
		for _, at in ipairs(platforms) do dump[#dump + 1] = string.format("  (%.2f, %.2f)", at[1], at[2]) end
		dump[#dump + 1] = "mod platform height: " .. tostring(ownPlatformHeight())
		pcall(tf3api.writeFile, "station_lanes_" .. shim.modId .. ".txt", table.concat(dump, "\n") .. "\n")
	end
end

-- Puts finish() after the game's own closing step, once per station being built. It is done from the mod's
-- modules, not from a construction script of the mod's own: the station's update script stays the game's, so
-- that the game and other mods (one that changes station ranges looks at exactly that) take it for what it
-- is, a modular train station.
local hooked = setmetatable({}, { __mode = "k" })
local function finishAfterClosing(result)
	if hooked[result] then return end
	hooked[result] = true
	local closing = result.terminateConstructionHook
	result.terminateConstructionHook = function()
		if type(closing) == "function" then closing() end
		finish(result)
	end
end

-- ------------------------------------------------------------------------------------------------------
-- modules

function shim.moduleData(old, scriptRef)
	local out = dataOf(old) or {}
	out.category = nil
	local order = type(old.order) == "table" and tonumber(old.order.value) or tonumber(old.order)
	out.order = nil
	out.menuCategory = { categories = { { category = "modules_platforms", filterCategories = { "passenger" }, order = order or 5000 } } }
	if type(out.description) == "table" then
		out.description.icon = shim.icon(out.description.icon)
		out.description.previewIcon = out.description.previewIcon and shim.icon(out.description.previewIcon) or out.description.icon
	end
	if type(old.updateFn) == "function" then out.updateScript = { fileName = scriptRef .. "@updateFn", params = {} } end
	if type(old.getModelsFn) == "function" then out.getModelsScript = { fileName = scriptRef .. "@getModelsFn", params = {} } end
	return out
end

function shim.moduleFunctions(old)
	local out = {}
	local isPlatform = type(old.metadata) == "table" and (old.metadata.passenger_platform or old.metadata.cargo_platform)
	if type(old.updateFn) == "function" then
		out.updateFn = function(captureParams, result, transform, tag, slotId, addModel, constrParams)
			finishAfterClosing(result)
			if isPlatform and type(transform) == "table" and tonumber(transform[13]) then
				local list = platformsOf[result]
				if not list then list = {} platformsOf[result] = list end
				list[#list + 1] = { transform[13], transform[14] }
			end
			-- like the game's own modules: build into the station's inner part
			local target = type(result.cargoStation) == "table" and result.cargoStation or result
			local modelsBefore = type(target.models) == "table" and #target.models or 0
			local groundBefore = type(target.groundFaces) == "table" and #target.groundFaces or 0
			local function addModelOld(name, modelTransf, tag2, models)
				return addModel(shim.modelName(name), modelTransf, tag2, models or target.models)
			end
			old.updateFn(target, transform, tag, slotId, addModelOld, constrParams)
			renameAdded(target, modelsBefore, groundBefore)
		end
	end
	if type(old.getModelsFn) == "function" then
		out.getModelsFn = function(captureParams, params)
			-- the picture of a module in the menu: no station is put together here, so the names are finished at once
			local list = old.getModelsFn(params)
			if type(list) == "table" then
				for _, m in ipairs(list) do
					if type(m) == "table" then m.id = final(shim.modelName(m.id)) end
				end
			end
			return list
		end
	end
	return out
end

-- ------------------------------------------------------------------------------------------------------
-- the station itself

local function paramKeys(old)
	local keys = {}
	for _, template in ipairs(type(old.constructionTemplates) == "table" and old.constructionTemplates or {}) do
		local params = type(template.data) == "table" and template.data.params
		for _, p in ipairs(type(params) == "table" and params or {}) do
			if type(p) == "table" and type(p.key) == "string" then keys[p.key] = true end
		end
	end
	return keys
end

function shim.constructionData(old, scriptRef)
	local description = dataOf(old.description) or {}
	local templates = {}
	for i, template in ipairs(type(old.constructionTemplates) == "table" and old.constructionTemplates or {}) do
		local t = dataOf(template) or {}
		t.constructionType = nil
		if type(t.description) == "table" then
			t.description.icon = shim.icon(t.description.icon)
			t.description.previewIcon = t.description.previewIcon and shim.icon(t.description.previewIcon) or t.description.icon
			if description.icon == nil then description.icon = t.description.icon end
		end
		-- the older game counts a parameter's choices from 0, the newer one from 1
		if type(t.data) == "table" and type(t.data.params) == "table" then
			for _, p in ipairs(t.data.params) do
				if type(p) == "table" then p.defaultIndex = (tonumber(p.defaultIndex) or 0) + 1 end
			end
		end
		t.menuCategory = menuCategory("rail_buildings", (tonumber(old.order) or 5000) + i)
		t.configureLayerScript = {
			fileName = "::/gui/construction/construction_desc_layers.script@configureDefaultLayerFn",
			params = { heightmapContours = true },
		}
		t.configureHudIconsScript = {
			fileName = "::/gui/construction/construction_desc_hud_icons.script@configureStationHudIconsFn",
			params = { cargo = false, rail = true },
		}
		templates[i] = t
	end
	description.icon = shim.icon(description.icon)
	description.previewIcon = description.previewIcon and shim.icon(description.previewIcon) or description.icon
	return {
		configureLayerScript = {
			fileName = "::/gui/construction/construction_desc_layers.script@configureDefaultLayerFn",
			params = { heightmapContours = true },
		},
		namePrefix = "{townName} Station",
		subConstructionNamePrefix = "{constructionName}",
		description = description,
		availability = dataOf(old.availability) or { yearFrom = 0, yearTo = 0 },
		order = tonumber(old.order) or 5000,
		soundConfig = {
			soundSet = { name = "::/stations/rail/sound/modular_rail_station.snd" },
			effects = { select = { "::/stations/rail/sound/selected_passengertrainstation2.wav" } },
			builderAudioRes = "::/gui/construction/sound/buildoze_construction_large.builder_audio",
		},
		constructionTemplates = templates,
		-- the starting layout is the mod's; building, updating and upgrading are the game's own station
		createTemplateScript = { fileName = (type(old.createTemplateFn) == "function" and scriptRef or STOCK_STATION) .. "@createTemplateFn", params = {} },
		updateScript = { fileName = STOCK_STATION .. "@updateFn", params = {} },
		upgradeScript = { fileName = STOCK_STATION .. "@upgradeFn", params = {} },
		isAffectedByToolScript = { fileName = STOCK_STATION .. "@isAffectedByToolFn", params = {} },
	}
end

function shim.constructionFunctions(old)
	local out = {}
	if type(old.createTemplateFn) == "function" then
		local keys = paramKeys(old)
		out.createTemplateFn = function(captureParams, params)
			local p = {}
			for k, v in pairs(params) do
				if keys[k] and type(v) == "number" then p[k] = v - 1 else p[k] = v end
			end
			local layout = old.createTemplateFn(p)
			local renamed = {}
			for slot, name in pairs(type(layout) == "table" and layout or {}) do renamed[slot] = shim.moduleName(name) end
			return renamed
		end
	end
	return out
end

-- ------------------------------------------------------------------------------------------------------
-- library functions the older scripts call and the newer game no longer has

local function over(lib, extra)
	return setmetatable(extra, { __index = lib })
end

function shim.paramsutil()
	return over(require "::/scripts/construction/paramsutil.lua", {
		makeTrackTypeParam = function()
			return { key = "trackType", name = "Track type", values = { "Standard", "High-speed" }, defaultIndex = 0 }
		end,
		makeTrackCatenaryParam = function()
			return { key = "catenary", name = "Catenary", values = { "No", "Yes" }, defaultIndex = 0 }
		end,
	})
end

function shim.colliderutil()
	return over(require "::/scripts/construction/colliderutil.lua", {
		createBox = function(halfExtents, boxTransf)
			return { type = "BOX", params = { halfExtents = halfExtents }, transf = boxTransf }
		end,
	})
end

-- a library the converter does not know: anything asked of it answers nothing instead of stopping the game
function shim.unknown(name)
	return setmetatable({}, { __index = function() return function() return nil end end })
end

return shim
