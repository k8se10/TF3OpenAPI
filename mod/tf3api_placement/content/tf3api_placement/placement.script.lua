-- TF3OpenAPI - placement in two steps.
--
-- The work is done by the native layer (native/src/placement.cpp): the first click pins an object, the right
-- mouse button turns it, a second click builds it. It is to happen only while the game's own option for
-- roads and track, "Enable Drag-and-Confirm Construction Mode", is on - a setting of the game that a script
-- can read and the native layer cannot. So this script reads it now and then and says so.
-- (In the game's settings the option is stored the other way round: enableSeamlessStreetBuilder = false
-- means drag-and-confirm is on.)
-- It also hands over the keys the player has for raising and lowering an object (constructRaise /
-- constructLower), which the native layer presses while the middle button drags a pinned object up or down.

local EVERY = 120   -- frames between two looks at the setting
local frame, last, told = 0, nil, false

local function log(text)
	pcall(function() if tf3api ~= nil and tf3api.log ~= nil then tf3api.log("[tf3api_placement] " .. text) end end)
end

-- whether the game's drag-and-confirm option is on, from the game's settings; nil when they cannot be read
local function optionOn()
	local ok, seamless = pcall(function() return api.util.getAppConfig().enableSeamlessStreetBuilder end)
	if ok and type(seamless) == "boolean" then return not seamless end
	return nil
end

-- the key (by its name, as the settings store it) the player has for an input action; nil when there is none
local function keyOf(action)
	local name
	pcall(function()
		for _i, combo in ipairs(api.util.getAppConfig().keyCmdDefinitions[action]) do
			if name == nil and type(combo.scancode) == "string" and combo.scancode ~= "" and (combo.modifiers == nil or #combo.modifiers == 0) then
				name = combo.scancode
			end
		end
	end)
	return name
end

local saidKeys = nil

local function guiUpdate()
	frame = frame + 1
	if frame % EVERY ~= 1 then return end
	local ok, bridge = pcall(function() return tf3api end)
	if not ok or type(bridge) ~= "table" or type(bridge.placementMode) ~= "function" then return end
	local on = optionOn()
	if on == nil then
		if not told then
			told = true
			log("the game's settings could not be read: objects are built at the click, as the game ships")
		end
		on = false
	end
	if on ~= last then
		last = on
		local state = bridge.placementMode(on and "1" or "0")
		log("the game's drag-and-confirm option is " .. (on and "on" or "off") .. " (native state " .. tostring(state) .. ")")
	end
	if type(bridge.placementKeys) == "function" then
		local raise, lower = keyOf("constructRaise"), keyOf("constructLower")
		local keys = tostring(raise) .. "|" .. tostring(lower)
		if keys ~= saidKeys and raise ~= nil and lower ~= nil then
			saidKeys = keys
			local okKeys, taken = pcall(bridge.placementKeys, raise, lower)
			log(string.format("raise / lower keys for the middle button: %q / %q (%s)", raise, lower, okKeys and tostring(taken) or "not taken"))
		end
	end
end

function data()
	return {
		guiUpdate = guiUpdate,
		optionOn = optionOn,   -- for tests
	}
end
