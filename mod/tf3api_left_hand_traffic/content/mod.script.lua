-- TF3OpenAPI left-hand traffic. First stage: streets only (see core.lua for the rule).
local MOD_ID = "tf3api_left_hand_traffic"
local core = require(MOD_ID .. "::/left_hand_traffic/core.lua")

local function note(text)
	pcall(function() if type(tf3api) == "table" and type(tf3api.log) == "function" then tf3api.log("[" .. MOD_ID .. "] " .. text) end end)
	pcall(function() debugPrint("[" .. MOD_ID .. "] " .. text) end)
end

function data()
	return {
		runFn = function()
			local counts = { ["two-way"] = 0, ["one-way"] = 0, none = 0, failed = 0 }
			local told = false
			addModifier("loadStreetTemplate", function(fileName, template)
				-- a fault of ours must never cost the game a street
				local ok, what = pcall(core.street, template)
				if ok then counts[what] = (counts[what] or 0) + 1 else counts.failed = counts.failed + 1 end
				if not ok and not told then
					told = true
					note("street " .. tostring(fileName) .. " left as it was: " .. tostring(what))
				end
				return template
			end)
			note("streets keep left from now on")
		end,
	}
end
