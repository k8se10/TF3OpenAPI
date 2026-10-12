-- Shipped inside a converted Transport Fever 2 station mod (as tf3api_legacy/shim.lua, with the three
-- placeholders below filled in by the converter). It lets the mod's own construction and module scripts,
-- carried over as they were written, run inside Transport Fever 3:
--   * every function of the newer game gets one more first argument;
--   * names changed: models, modules, tracks, ground textures, pictures;
--   * a station of the newer game is its own modular station: the mod's construction keeps its name, its
--     parameters and its starting layout, and is built, updated and upgraded by the game's own station script.
-- Nothing in here is the game's code; it only calls the game's scripts by name.
-- Names of the game's own files are written with "::/" in front: from inside a mod a bare "/..." means the
-- mod's own files (the first run in the game failed on exactly that).

local shim = {}

shim.modId = "@MOD_ID@"
shim.ownModules = { @OWN_MODULES@ }
shim.ownModels = { @OWN_MODELS@ }

local STOCK_STATION = "::/stations/rail/modular_station/modular_station.script"

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

function shim.modelName(old)
	if type(old) ~= "string" then return old end
	local key = lower(old)
	if key:sub(1, 1) == "/" or key:find("::", 1, true) then return old end
	if shim.ownModels[key] then return shim.modId .. "::/" .. key end
	if key:sub(1, 8) == "station/" then return "::/stations/" .. key:sub(9) end
	if key:sub(1, 6) == "asset/" then return "::/assets/" .. key:sub(7) end
	return "::/" .. key
end

function shim.groundTexture(old)
	if type(old) ~= "string" then return old end
	local key = lower(old)
	if key:sub(1, 1) == "/" or key:find("::", 1, true) then return old end
	if key == "street_border.lua" then return "::/infrastructure/street/shared/street_border.gtex" end
	local name = key:match("^shared/([%w_]+)%.gtex%.lua$")
	if name then return "::/terrain/materials/" .. name .. "/" .. name .. ".gtex" end
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
	if type(old.updateFn) == "function" then
		out.updateFn = function(captureParams, result, transform, tag, slotId, addModel, constrParams)
			local modelsBefore = type(result.models) == "table" and #result.models or 0
			local groundBefore = type(result.groundFaces) == "table" and #result.groundFaces or 0
			local function addModelOld(name, modelTransf, tag2, models)
				return addModel(shim.modelName(name), modelTransf, tag2, models)
			end
			old.updateFn(result, transform, tag, slotId, addModelOld, constrParams)
			renameAdded(result, modelsBefore, groundBefore)
		end
	end
	if type(old.getModelsFn) == "function" then
		out.getModelsFn = function(captureParams, params)
			local list = old.getModelsFn(params)
			if type(list) == "table" then
				for _, m in ipairs(list) do
					if type(m) == "table" then m.id = shim.modelName(m.id) end
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
