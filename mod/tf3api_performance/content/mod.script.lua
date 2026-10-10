-- TF3OpenAPI - performance tuning (script-only companion mod).
--
-- STATUS: shelved 2026-10-10. Tried in-game and withdrawn: visible loss of detail for little frame-rate gain,
-- because draw distance and LOD were not what limited the frame on the test save. Kept for reference; not deployed.
--
-- What it does, all in memory while the game loads (no game or mod files are changed):
--  1. Caps the render distance (far plane) of the Low / Medium / High geometry settings and the cockpit view.
--     Fog is defined as a fraction of the far distance, so it moves in with it.
--  2. Pulls in the LOD distances of every model: the part of each distance beyond LOD_SCALE_START is
--     multiplied by LOD_SCALE, so detail close to the camera is untouched and distant objects switch to
--     their cheaper LOD, and disappear, sooner.
--  3. Applies a harsher scale to model groups listed in HEAVY_MODELS.
--
-- Rendering only: nothing here touches simulation data, and saves stay loadable without the mod.
-- Same idea as the Transport Fever 2 mod "Performance tuning" by okeating (no code taken from it).
-- Log: lines "[tf3api_performance]" in crash_dump/stdout.txt.

local MOD_ID = "tf3api_performance"

-- ---- Settings ------------------------------------------------------------------------------------------

-- Nothing is drawn beyond this distance (metres). Vanilla: Low 7200, Medium 9000, High 11250.
local RENDER_DISTANCE = 5000

-- LOD distances: the part beyond LOD_SCALE_START metres is multiplied by LOD_SCALE (1.0 = vanilla).
local LOD_SCALE = 0.5
local LOD_SCALE_START = 1000

-- Harsher settings for models whose file path contains `pattern` (plain text, lower case). First match wins.
local HEAVY_MODELS = {
	{ pattern = "bridge", scale = 0.3, start = 500 },
}

-- Entries of baseConfig.settings.geometryQualityOptions that get the render-distance cap
-- (order in ::/base/mod.script.tl: Low, Medium, High, Camera tool, Cockpit view, Camera tool preview).
-- The camera tool and its preview keep their long view on purpose.
local CAPPED_QUALITY_OPTIONS = { 1, 2, 3, 5 }

-- ---------------------------------------------------------------------------------------------------------

local function log(msg)
	local text = "[" .. MOD_ID .. "] " .. msg
	if not pcall(function() debugPrint(text) end) then
		print(text)
	end
end

local function capRenderDistance(baseConfig)
	local options = baseConfig.settings.geometryQualityOptions
	for _, index in ipairs(CAPPED_QUALITY_OPTIONS) do
		local option = options[index]
		if option ~= nil then
			local near, far = option.viewNearFar.x, option.viewNearFar.y
			if far > RENDER_DISTANCE then
				-- only the far distance changes; the near distance (which other mods adjust) is kept as found
				option.viewNearFar = api.type.Vec2f.new(near, RENDER_DISTANCE)
				options[index] = option
				log(string.format("geometry option %d: render distance %.0f m -> %.0f m", index, far, RENDER_DISTANCE))
			end
		end
	end
	baseConfig.settings.geometryQualityOptions = options
end

local function settingsFor(fileName)
	local name = string.lower(tostring(fileName))
	for _, heavy in ipairs(HEAVY_MODELS) do
		if string.find(name, heavy.pattern, 1, true) then
			return heavy.scale, heavy.start
		end
	end
	return LOD_SCALE, LOD_SCALE_START
end

local function scaleDistance(distance, scale, start)
	if distance > start then
		distance = start + (distance - start) * scale
	end
	return math.min(distance, RENDER_DISTANCE)
end

-- Returns true if any distance of the model changed. Distances stay in order and contiguous because the
-- same increasing function is applied to every one of them.
local function tuneModel(fileName, model)
	local lods = model and model.lods
	if type(lods) ~= "table" then return false end
	local scale, start = settingsFor(fileName)
	local changed = false
	for _, lod in ipairs(lods) do
		if type(lod) == "table" then
			for _, key in ipairs({ "visibleFrom", "visibleTo" }) do
				local distance = lod[key]
				if type(distance) == "number" and distance > 0 then
					local tuned = scaleDistance(distance, scale, start)
					if tuned ~= distance then
						lod[key] = tuned
						changed = true
					end
				end
			end
		end
	end
	return changed
end

function data()
	return {
		-- runs after the base game's preRunFn, which sets the graphics settings
		preRunFn = function(_captureParams, _configDict, _allModParams, baseConfig)
			local ok, err = pcall(capRenderDistance, baseConfig)
			if not ok then
				log("could not cap the render distance: " .. tostring(err))
			end
		end,

		runFn = function(_captureParams, _settings)
			local seen, tuned, failed = 0, 0, 0
			log(string.format("active: render distance %d m, LOD scale %.2f beyond %d m", RENDER_DISTANCE, LOD_SCALE,
				LOD_SCALE_START))
			addModifier("loadModel", function(fileName, model)
				seen = seen + 1
				local ok, result = pcall(tuneModel, fileName, model)
				if not ok then
					failed = failed + 1
					if failed <= 3 then
						log("error in " .. tostring(fileName) .. ": " .. tostring(result))
					end
				elseif result then
					tuned = tuned + 1
				end
				if seen % 1000 == 0 then
					log(string.format("%d models loaded, %d had LOD distances shortened, %d errors", seen, tuned, failed))
				end
				return model
			end)
		end,
	}
end
