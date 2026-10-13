-- TF3OpenAPI - day clock: what is set up when the game loads its models.
-- Vehicle wear and age follow the calendar in the modes with a long day (see day_clock/wear.lua).
-- The clock, the calendar's pace and the sky are the game script's work (day_clock/day_clock.script.lua).
local MOD_ID = "tf3api_day_clock"
local wear = require(MOD_ID .. "::/day_clock/wear.lua")

-- the calendar day of each mode, in the order of the mod's "Calendar" setting (the same figures as in
-- day_clock.script.lua); false = the game's own
local DAY_MS = { 24 * 60 * 60 * 1000, 60 * 60 * 1000, false }

local function note(text)
	pcall(function() if type(tf3api) == "table" and type(tf3api.log) == "function" then tf3api.log("[" .. MOD_ID .. "] " .. text) end end)
	pcall(function() debugPrint("[" .. MOD_ID .. "] " .. text) end)
end

-- a setting as the number of the chosen option, counted from 1 (as the game hands it over); nil when not set
local function setting(allModParams, key)
	local mine = type(allModParams) == "table" and allModParams[MOD_ID] or nil
	local value = type(mine) == "table" and tonumber(mine[key]) or nil
	if value ~= nil and value >= 1 then return math.floor(value) end
	return nil
end

function data()
	return {
		runFn = function(_captureParams, _configDict, allModParams)
			local dayMs = DAY_MS[setting(allModParams, "mode") or 1]
			if dayMs == nil then dayMs = DAY_MS[1] end
			if setting(allModParams, "wear") == 2 then
				note("vehicle wear is left as the game has it (setting)")
				return
			end
			local factor = wear.factor(dayMs or nil)
			if factor <= 1 then return end   -- the game's own calendar: nothing to scale
			local told = false
			addModifier("loadModel", function(fileName, model)
				-- a fault of ours must never cost the game a model
				local ok, problem = pcall(wear.scaleModel, model, factor)
				if not ok and not told then
					told = true
					note("model " .. tostring(fileName) .. " left as it was: " .. tostring(problem))
				end
				return model
			end)
			note(string.format("vehicle wear and age follow the calendar: lifespans x %d", factor))
		end,
	}
end
