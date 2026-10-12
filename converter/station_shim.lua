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
-- models and modules of other old mods that this mod's scripts name: name -> the id of that mod, converted
shim.otherModels = { @OTHER_MODELS@ }
shim.otherModules = { @OTHER_MODULES@ }
-- the walking lanes the mod's models carried in the older game, by model
shim.ownLanes = @OWN_LANES@
-- the stops the mod's models carried: per model, { personNodes, personEdges, vehicleNode } counted over that
-- model's lanes
shim.ownTerminals = @OWN_TERMINALS@
-- true: the lanes of the station last built are written to tf3api_out/station_lanes_<mod>.txt
shim.debug = @DEBUG@

local STOCK_STATION = "::/stations/rail/modular_station/modular_station.script"
-- the ground texture that cuts the terrain away, exactly as the game's own modules write it
local HOLE = "/infrastructure/shared/hole.gtex"
local fixEdgeLists   -- defined further down; turns the older game's kinds of track, bridge and tunnel into the newer one's

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
	if shim.otherModules[key] then return shim.otherModules[key] .. "::/" .. key end
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
	if shim.otherModels[key] then return shim.otherModels[key] .. "::/" .. key end
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
-- The older game cut the terrain away under a ground face with the "hole" texture. The newer game does not:
-- it hides the terrain inside boxes carried by models. The converted mod has such box models in a set of sizes
-- (tf3api_legacy/cut/cut_<along>x<across>.mdl, sides in steps of 0.4 m, each a power of two); a hole face is
-- covered with as few of them as it takes.
local CUT_STEP, CUT_MAX = 0.4, 64
local function cutPieces(length)
	local steps = math.max(1, math.floor(length / CUT_STEP + 0.5))
	local pieces, size = {}, CUT_MAX
	while steps > 0 and size >= 1 do
		while steps >= size do
			pieces[#pieces + 1] = size
			steps = steps - size
		end
		size = size / 2
	end
	return pieces
end

local function hideTerrain(result, face, tag)
	if type(face) ~= "table" or #face ~= 4 or type(result.models) ~= "table" then return end
	local p = {}
	for i = 1, 4 do
		local v = face[i]
		if type(v) ~= "table" or not tonumber(v[1]) or not tonumber(v[2]) then return end
		p[i] = { tonumber(v[1]), tonumber(v[2]) }
	end
	-- a rectangle: its middle, and its two sides from the first three corners
	local cx, cy = (p[1][1] + p[2][1] + p[3][1] + p[4][1]) / 4, (p[1][2] + p[2][2] + p[3][2] + p[4][2]) / 4
	local ax, ay = p[2][1] - p[1][1], p[2][2] - p[1][2]
	local bx, by = p[3][1] - p[2][1], p[3][2] - p[2][2]
	local along, across = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
	if along < 0.01 or across < 0.01 then return end
	ax, ay, bx, by = ax / along, ay / along, bx / across, by / across
	local alongPieces, acrossPieces = cutPieces(along), cutPieces(across)
	local function total(pieces) local n = 0 for _, s in ipairs(pieces) do n = n + s end return n * CUT_STEP end
	local u = -total(alongPieces) / 2
	for _, a in ipairs(alongPieces) do
		local v = -total(acrossPieces) / 2
		for _, b in ipairs(acrossPieces) do
			local mx = cx + ax * (u + a * CUT_STEP / 2) + bx * (v + b * CUT_STEP / 2)
			local my = cy + ay * (u + a * CUT_STEP / 2) + by * (v + b * CUT_STEP / 2)
			result.models[#result.models + 1] = {
				id = shim.modId .. "::/tf3api_legacy/cut/cut_" .. a .. "x" .. b .. ".mdl",
				-- the box's long side along the face's first side, lying at ground level (a plain turn about
				-- the vertical, whichever way round the face's corners go)
				transf = { ax, ay, 0, 0, -ay, ax, 0, 0, 0, 0, 1, 0, mx, my, 0, 1 },
				tag = tag,
			}
			v = v + b * CUT_STEP
		end
		u = u + a * CUT_STEP
	end
end

local function renameAdded(result, modelsBefore, groundBefore, tag)
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
				local cut = false
				for _, mode in ipairs(g.modes) do
					if type(mode) == "table" then
						mode.key = shim.groundTexture(mode.key)
						if mode.key == HOLE then cut = true end
					end
				end
				if cut then hideTerrain(result, g.face, tag) end
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
							if #lane.nodes == 0 then lane = nil end
							if lane then p.laneLists[#p.laneLists + 1] = {
								transf = m.transf, nodes = lane.nodes, speedLimit = lane.speedLimit,
								transportModes = lane.transportModes, linkable = lane.linkable,
								forwardOnly = lane.forwardOnly, needsReservation = lane.needsReservation,
							} end
							if lane and isTransform(m.transf) then
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
	-- kinds of track, bridge and tunnel the newer game does not know would stop it
	fixEdgeLists(result)
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
			renameAdded(target, modelsBefore, groundBefore, tag)
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

-- ------------------------------------------------------------------------------------------------------
-- Tracks, streets, bridges and tunnels a construction lays ("edge lists"). The older game names their kinds by
-- file ("standard.lua", "cement.lua"), the newer one by resource ("/infrastructure/track/standard/
-- standard.street_template", "/infrastructure/bridge/concrete.bridge"). A kind the newer game does not know
-- stops the game when the construction is placed, so every name is turned into one it has: the nearest of its
-- own. (Track, bridge and tunnel kinds that an old mod brings are not converted yet; the game's standard ones
-- stand in for them.)
local function named(name)
	return type(name) == "string" and (name:sub(1, 1) == "/" or name:find("::", 1, true) ~= nil)
end

local function trackKind(old, catenary)
	local key = lower(old or ""):gsub("%.lua$", "")
	local kind = key:find("high_speed", 1, true) and "high_speed" or "standard"
	return "::/infrastructure/track/" .. kind .. "/" .. kind .. (catenary and "_catenary" or "") .. ".street_template"
end

local function streetKind(old)
	local key = lower(old or "")
	local group = key:find("highway", 1, true) and "highway" or key:find("country", 1, true) and "country" or "town"
	local size = key:find("large", 1, true) and "large" or key:find("medium", 1, true) and "medium" or "small"
	local age = (group == "highway" or not key:find("old", 1, true)) and "new" or "old"
	return "::/infrastructure/street/" .. group .. "/" .. group .. "_" .. age .. "_" .. size .. ".street_template"
end

local BRIDGES = { cement = "concrete", concrete = "concrete", iron = "steel", steel = "steel", stone = "stone", suspension = "suspension", cable = "cable" }

fixEdgeLists = function(result)
	for _, list in ipairs(type(result.edgeLists) == "table" and result.edgeLists or {}) do
		if type(list) == "table" then
			local street = tostring(list.type or "TRACK"):upper() == "STREET"
			if type(list.params) ~= "table" then list.params = {} end
			if not named(list.params.type) then
				if street then
					list.params.type = streetKind(list.params.type)
				else
					list.params.type = trackKind(list.params.type, list.params.catenary == true)
					list.params.catenary = nil
				end
			end
			local edgeType = list.edgeType ~= nil and tostring(list.edgeType):upper() or nil
			if edgeType == "BRIDGE" and not named(list.edgeTypeName) then
				local key = lower(list.edgeTypeName or ""):gsub("%.lua$", "")
				list.edgeTypeName = "::/infrastructure/bridge/" .. (BRIDGES[key] or "concrete") .. ".bridge"
			elseif edgeType == "TUNNEL" and not named(list.edgeTypeName) then
				list.edgeTypeName = "::/infrastructure/tunnel/" .. (street and "tunnel_b_car" or "tunnel_b") .. ".tunnel"
			end
		end
	end
end

-- ------------------------------------------------------------------------------------------------------
-- constructions that are not modular stations: assets (signs, billboards, props) and other plain ones.
-- The construction keeps its parameters and its own update function. What changes: the newer game's names for
-- things, parameter choices counted from 1, and what the function builds goes into a part of the construction
-- ("subconstruction"), as the newer game has it.

-- where each kind is offered in the newer game's menus
local PLAIN_CATEGORY = {
	ASSET_DEFAULT = "landscaping_assets", ASSET_TRACK = "rail_assets",
	RAIL_STATION = "rail_buildings", RAIL_STATION_CARGO = "rail_buildings", RAIL_DEPOT = "rail_buildings",
	STREET_STATION = "road_buildings", STREET_STATION_CARGO = "road_buildings", STREET_DEPOT = "road_buildings",
	TRAM_DEPOT = "road_buildings", STREET_CONSTRUCTION = "street_constructions",
	HARBOR = "water_buildings", HARBOR_CARGO = "water_buildings", WATER_DEPOT = "water_buildings",
	AIRPORT = "air_buildings", AIRPORT_CARGO = "air_buildings",
	INDUSTRY = "industries", TOWN_BUILDING = "town_buildings_other",
}
local UI_TYPE = { BUTTON = "Button", SLIDER = "Slider", COMBOBOX = "ComboBox", ICON_BUTTON = "IconButton", CHECKBOX = "CheckBox" }

local function isModular(old)
	return type(old.createTemplateFn) == "function" or type(old.constructionTemplates) == "table"
end

local function plainParamKeys(old)
	local keys = {}
	for _, p in ipairs(type(old.params) == "table" and old.params or {}) do
		if type(p) == "table" and type(p.key) == "string" then keys[p.key] = true end
	end
	return keys
end

-- ------------------------------------------------------------------------------------------------------
-- A whole rail station built by one construction (not from modules), as the older game had it:
--   result.models            the platform models carry the walking lanes and the stops
--   result.terminalGroups    { { terminals = { { model index, stop index of that model } , ... },
--                                vehicleNodeOverride = <track node where the train stands> }, ... }
-- The newer game wants, in the part of the construction that holds the models:
--   laneLists                every lane list, placed
--   station.terminals        { { personNodes = { { lane list, node } ... }, personEdges = { { lane list, edge } ... },
--                                vehicleNode = { -1, track node }, transportModes, passengers / cargo, ... } }
-- so the lanes of every model are laid out in order, and each stop's node and edge numbers, which count through
-- its model's lanes, are turned into (lane list, number in that list). Index numbers start at 0 in both games.

local PLAIN_IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local STATION_KINDS = { RAIL_STATION = true, RAIL_STATION_CARGO = true }

-- the walking lanes of one of the game's own models, from the game's table of them
local stockLaneCache = {}
local function stockLanes(bareId)
	if stockLaneCache[bareId] == nil then
		local lists = {}
		pcall(function()
			local legacy = require "::/scripts/construction/legacytransportnetworks.lua"
			local probe = { subconstructions = { { models = { { id = bareId, transf = PLAIN_IDENTITY } } } } }
			legacy.addLaneLists(probe, true)
			lists = probe.subconstructions[1].laneLists or {}
		end)
		stockLaneCache[bareId] = lists
	end
	return stockLaneCache[bareId]
end

local function convertStation(result, cargo)
	local sub = result.subconstructions[1]
	if type(sub) ~= "table" or type(sub.models) ~= "table" then return end
	local ownPrefix = shim.modId .. "::/"
	if type(sub.laneLists) ~= "table" then sub.laneLists = {} end
	local perModel = {}
	for m, model in ipairs(sub.models) do
		local entry = { lists = {} }
		local id = type(model) == "table" and type(model.id) == "string" and model.id or ""
		local lists
		if id:sub(1, #ownPrefix) == ownPrefix then
			local key = lower(id:sub(#ownPrefix + 1))
			lists, entry.terminals = shim.ownLanes[key], shim.ownTerminals[key]
		elseif id:sub(1, 3) == "::/" then
			lists = stockLanes(id:sub(3))
		end
		for _, lane in ipairs(lists or {}) do
			-- (a list without nodes is counted but not laid out)
			entry.lists[#entry.lists + 1] = { index = #sub.laneLists, nodes = #lane.nodes }
			if #lane.nodes > 0 then
				sub.laneLists[#sub.laneLists + 1] = {
					transf = model.transf, nodes = lane.nodes, speedLimit = lane.speedLimit, transportModes = lane.transportModes,
					linkable = lane.linkable, forwardOnly = lane.forwardOnly, needsReservation = lane.needsReservation,
				}
			end
		end
		perModel[m] = entry
	end
	-- a number that counts through a model's lanes -> { lane list, number in that list }
	local function place(entry, number, edges)
		local before = 0
		for _, list in ipairs(entry.lists) do
			local count = edges and math.floor(list.nodes / 2) or list.nodes
			if number < before + count then return { list.index, number - before } end
			before = before + count
		end
		return nil
	end
	-- is the track with this node electrified
	local function electric(node)
		local before = 0
		for _, list in ipairs(type(result.edgeLists) == "table" and result.edgeLists or {}) do
			local count = type(list.edges) == "table" and #list.edges or 0
			if node < before + count then return type(list.params) == "table" and tostring(list.params.type):find("_catenary", 1, true) ~= nil end
			before = before + count
		end
		return false
	end
	local terminals, sumX, sumY, sumZ, counted = {}, 0, 0, 0, 0
	for g, group in ipairs(result.terminalGroups) do
		local terminal = { personNodes = {}, personEdges = {}, tag = tonumber(group.tag) or (g - 1), passengers = not cargo, cargo = cargo and true or false }
		for _, ref in ipairs(type(group.terminals) == "table" and group.terminals or {}) do
			local m = (tonumber(type(ref) == "table" and ref[1]) or -1) + 1
			local entry = perModel[m]
			local stop = entry and entry.terminals and entry.terminals[(tonumber(ref[2]) or 0) + 1]
			if stop then
				for _, n in ipairs(stop.personNodes) do
					local at = place(entry, tonumber(n) or -1, false)
					if at then terminal.personNodes[#terminal.personNodes + 1] = at end
				end
				for _, e in ipairs(stop.personEdges) do
					local at = place(entry, tonumber(e) or -1, true)
					if at then terminal.personEdges[#terminal.personEdges + 1] = at end
				end
				if terminal.vehicleNode == nil and stop.vehicleNode ~= nil and stop.vehicleNode >= 0 then
					terminal.vehicleNode = place(entry, stop.vehicleNode, false)
				end
				local t = sub.models[m].transf
				if isTransform(t) then sumX, sumY, sumZ, counted = sumX + t[13], sumY + t[14], sumZ + t[15], counted + 1 end
			end
		end
		local node = tonumber(group.vehicleNodeOverride)
		if node ~= nil and node >= 0 then
			terminal.vehicleNode = { -1, node }
			terminal.transportModes = electric(node) and { "TRAIN", "ELECTRIC_TRAIN", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK" } or { "TRAIN", "TRAM_TRACK" }
		end
		if not cargo then
			terminal.cargoTransferSpeeds = { { cargoTypeSet = { cargoClassesIncluded = { "PASSENGERS" } }, loadSpeedModifier = 1, length = 40 } }
		end
		terminal.comfortFactor = 1
		if terminal.vehicleNode ~= nil and #terminal.personEdges > 0 then terminals[#terminals + 1] = terminal end
	end
	result.terminalGroups, result.stations = nil, nil
	if #terminals == 0 then return end
	sub.station = { terminals = terminals, pool = { capacity = 40 * #terminals } }
	-- where people come from and go to: a circle round the middle of the platforms
	if counted > 0 then
		sub.station.catchmentAreas = { { position = { sumX / counted, sumY / counted, sumZ / counted }, radius = 250 } }
	end
	-- how many people each stop holds, worked out by the game's own function from the waiting lanes
	pcall(function() (require "::/scripts/construction/constructionutil.lua").addStationCapacities(sub) end)
end

local function plainData(old, scriptRef)
	local kind = tostring(old.type or "ASSET_DEFAULT")
	local description = dataOf(old.description) or {}
	if description.icon == nil or description.icon == "" then
		-- the older game took a construction's picture from a fixed place: ui/construction/<its path>.tga
		local rel = tostring(scriptRef):match("::/(.*)%.con%.script$")
		if rel then description.icon = "ui/construction/" .. rel .. ".tga" end
	end
	description.icon = shim.icon(description.icon)
	description.previewIcon = description.previewIcon and shim.icon(description.previewIcon) or description.icon
	local params = {}
	for i, p in ipairs(type(old.params) == "table" and old.params or {}) do
		local q = dataOf(p) or {}
		-- the older game counts a parameter's choices from 0, the newer one from 1
		q.defaultIndex = (tonumber(p.defaultIndex) or 0) + 1
		q.uiType = UI_TYPE[tostring(p.uiType or "BUTTON"):upper()] or "Button"
		if q.uiType == "IconButton" and type(q.values) == "table" then
			for k, value in ipairs(q.values) do q.values[k] = shim.icon(value) end
		end
		params[i] = q
	end
	local order = type(old.order) == "table" and tonumber(old.order.value) or tonumber(old.order) or 5000
	local out = {
		constructionType = kind,
		description = description,
		availability = dataOf(old.availability) or { yearFrom = 0, yearTo = 0 },
		order = order,
		buildMode = old.buildMode,
		skipCollision = old.skipCollision,
		autoRemovable = old.autoRemovable,
		menuCategory = { categories = { { category = PLAIN_CATEGORY[kind] or "landscaping_assets", filterCategories = {}, order = order } } },
		params = params,
		updateScript = { fileName = scriptRef .. "@updateFn", params = {} },
	}
	if kind == "ASSET_TRACK" then out.snapping = { rail = true, road = false, water = false } end
	if STATION_KINDS[kind] then
		-- a station, as the game's own are described
		out.constructionType = nil
		out.namePrefix = "{townName} Station"
		out.subConstructionNamePrefix = "{constructionName}"
		out.soundConfig = {
			soundSet = { name = "::/stations/rail/sound/modular_rail_station.snd" },
			effects = { select = { "::/stations/rail/sound/selected_passengertrainstation2.wav" } },
			builderAudioRes = "::/gui/construction/sound/buildoze_construction_large.builder_audio",
		}
		out.configureLayerScript = {
			fileName = "::/gui/construction/construction_desc_layers.script@configureDefaultLayerFn",
			params = { heightmapContours = true },
		}
		out.configureHudIconsScript = {
			fileName = "::/gui/construction/construction_desc_hud_icons.script@configureStationHudIconsFn",
			params = { cargo = kind == "RAIL_STATION_CARGO", rail = true },
		}
	end
	return out
end

local function plainFunctions(old)
	local out = {}
	if type(old.updateFn) ~= "function" then return out end
	local keys = plainParamKeys(old)
	local kind = tostring(old.type or "ASSET_DEFAULT")
	out.updateFn = function(captureParams, params)
		local p = {}
		for k, v in pairs(params) do
			if keys[k] and type(v) == "number" then p[k] = v - 1 else p[k] = v end
		end
		local result = old.updateFn(p)
		if type(result) ~= "table" then return result end
		if type(result.models) ~= "table" then result.models = {} end
		for _, m in ipairs(result.models) do
			if type(m) == "table" then m.id = final(shim.modelName(m.id)) end
		end
		if type(result.groundFaces) == "table" then
			for _, g in ipairs(result.groundFaces) do
				if type(g) == "table" and type(g.modes) == "table" then
					local cut = false
					for _, mode in ipairs(g.modes) do
						if type(mode) == "table" then
							mode.key = shim.groundTexture(mode.key)
							if mode.key == HOLE then cut = true else mode.key = final(mode.key) end
						end
					end
					if cut then hideTerrain(result, g.face, nil) end
				end
			end
		end
		fixEdgeLists(result)
		-- what stands in a construction is kept in a part of it in the newer game
		if result.subconstructions == nil then
			result.subconstructions = { {
				models = result.models, terrainAlignmentLists = result.terrainAlignmentLists,
				groundFaces = result.groundFaces, colliders = result.colliders,
			} }
			result.models, result.terrainAlignmentLists, result.groundFaces, result.colliders = nil, nil, nil, nil
		end
		if type(result.terminalGroups) == "table" then
			local ok, err = pcall(convertStation, result, kind == "RAIL_STATION_CARGO")
			if not ok then
				-- better a station nobody can use than one that stops the game
				result.terminalGroups, result.stations = nil, nil
				result.subconstructions[1].station = nil
				pcall(function() if tf3api ~= nil and tf3api.log ~= nil then tf3api.log("[" .. shim.modId .. "] station not converted: " .. tostring(err)) end end)
			end
		end
		if kind == "ASSET_TRACK" and result.snapPoint == nil then
			result.snapPoint = { transportModes = { "TRAIN", "ELECTRIC_TRAIN" }, allowSnapToBaseEdgeEnds = true, allowSnapToMesh = true }
		end
		return result
	end
	return out
end

function shim.constructionData(old, scriptRef)
	if not isModular(old) then return plainData(old, scriptRef) end
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
	if not isModular(old) then return plainFunctions(old) end
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
