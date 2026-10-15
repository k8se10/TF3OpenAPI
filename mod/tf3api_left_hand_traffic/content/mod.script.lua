-- TF3OpenAPI left-hand traffic.
--
-- What this mod itself does is small: it is the choice of the left for a new game (the guard sees that it is enabled), and
-- it mirrors road vehicles and trams built for the right (vehicle.lua). The streets, the roundabouts and ramps and the
-- lanes of buildings are turned by the TF3OpenAPI save guard and native layer, which keep every game on the side its roads
-- were built for - whichever left-hand traffic mod is enabled, or none.
local MOD_ID = "tf3api_left_hand_traffic"
local core = require(MOD_ID .. "::/left_hand_traffic/core.lua")
local vehicle = require(MOD_ID .. "::/left_hand_traffic/vehicle.lua")

local function note(text)
	pcall(function() if type(tf3api) == "table" and type(tf3api.log) == "function" then tf3api.log("[" .. MOD_ID .. "] " .. text) end end)
	pcall(function() debugPrint("[" .. MOD_ID .. "] " .. text) end)
end

function data()
	return {
		runFn = function(_captureParams, _configDict, allModParams)
			-- the setting "Vehicles": 1 = mirror (the default), 2 = leave them as built
			local choice = 1
			pcall(function() choice = tonumber(allModParams[MOD_ID].vehicles) or 1 end)
			if choice ~= 1 then
				note("vehicles are left as built (the setting)")
				return
			end
			local counts = { mirrored = 0, kept = 0, unsafe = 0 }
			local told = 0
			addModifier("loadModel", function(fileName, model)
				-- a fault of ours must never cost the game a vehicle
				local ok, result, why = pcall(vehicle.adapt, core, fileName, model)
				if not ok then
					counts.unsafe = counts.unsafe + 1
					return model
				end
				if why:find("^mirrored") then
					counts.mirrored = counts.mirrored + 1
					if told < 8 then
						told = told + 1
						note(tostring(fileName) .. ": " .. why)
					end
				elseif why:find("unsafe") then
					counts.unsafe = counts.unsafe + 1
					if counts.unsafe <= 8 then note(tostring(fileName) .. ": " .. why) end
				end
				return result
			end)
			note("road vehicles built for the right are mirrored as they load")
		end,
	}
end
