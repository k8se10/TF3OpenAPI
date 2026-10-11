-- TF3OpenAPI - road names: the interface.
--
-- Road names and number signs are drawn in the world by the native layer. When the player clicks one, the
-- native layer reports the road and the spot through tf3api.takeRoadClick(); this script picks that up and
-- opens the road's window.
--
-- The window: the road's number on its British sign in the window's header (blue for motorways, green for
-- primary A roads, white for the rest, grey for an abandoned road); its name on a street nameplate (white,
-- black border, the postcode district in red at the bottom right); then the details (kind, length, postcode
-- of the spot clicked) and the Abandoned tickbox.
-- Renaming, road type, label style, statistics and the Adjust Road tool are still to come.
--
-- Log: lines "[tf3api_road_names] ui:" in crash_dump/stdout.txt and "[script]" lines in tf3api.log.

local MOD_ID = "tf3api_road_names"

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"

local CHANNEL = "tf3api_road_names"         -- to the naming script (tf3api.post / take)
local UI_CHANNEL = "tf3api_road_names.ui"   -- from the naming script

local function bridge()
	local ok, table_ = pcall(function() return tf3api end)
	if ok and type(table_) == "table" then return table_ end
	return nil
end

local logged = 0
local function log(msg)
	local text = "[" .. MOD_ID .. "] ui: " .. tostring(msg)
	if not pcall(function() debugPrint(text) end) then print(text) end
	logged = logged + 1
	local b = bridge()
	if b ~= nil and logged <= 200 then pcall(b.log, text) end
end

-- the naming rules, for the postcode of a spot (pure Lua, shared with the naming script)
local core
do
	local ok, module = pcall(function() return ug_require(MOD_ID .. "::/road_names/core.lua") end)
	if ok and type(module) == "table" then core = module else log("could not load the naming rules: " .. tostring(module)) end
end
local postcodePlan = nil   -- sent by the naming script

local CLASS_NAMES = { "Road", "Main road", "Motorway" }

local function formatLength(metres)
	local ok, text = pcall(function() return api.util.formatLength(metres) end)
	if ok and type(text) == "string" then return text end
	return string.format("%.0f m", metres)
end

-- Which British sign a road number goes on: M = motorway (and an A road's motorway section), A = primary
-- A road (one or two digits), B = any other numbered road.
local function signOf(ref)
	if ref:sub(1, 1) == "M" or ref:sub(-3) == "(M)" then return "M" end
	local digits = ref:match("%d+") or ""
	if ref:sub(1, 1) == "A" and #digits <= 2 then return "A" end
	return "B"
end

local function windowKey(id) return "tf3apiRoad" .. tostring(id) end

local RoadWindow

local function closeWindow(id)
	local ok, err = pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(RoadWindow, windowKey(id)) end)
	if not ok then log("could not close the road window: " .. tostring(err)) end
end

-- What the window shows. param: { id, name, ref, cls, length, segments, flags, x, y }
local RoadWindowContent = react.RegisterRecipe("Tf3apiRoadWindowContent", function(param)
	local flags = param.flags or ""
	local isolated, abandoned = flags:find("i", 1, true) ~= nil, flags:find("a", 1, true) ~= nil
	local horizontal, vertical = builtin.type.Orientation.Horizontal, builtin.type.Orientation.Vertical

	local postcode, outward, postTown
	if core ~= nil and postcodePlan ~= nil and type(param.x) == "number" and type(param.y) == "number" then
		local ok, full, out, town = pcall(core.postcode, postcodePlan, param.x, param.y)
		if ok then postcode, outward, postTown = full, out, town end
	end

	-- the street nameplate, as on a British street: the name in black capitals on a white plate with a black
	-- border, the postcode district in red at the bottom right. (The road's number is in the window's header,
	-- on its sign.)
	local header = {}
	if param.name ~= "" then
		local plate = { builtin.TextView { meta = { class = "tf3api-nameplate-text" }, text = param.name:upper() } }
		if outward ~= nil then
			plate[#plate + 1] = builtin.TextView { meta = { class = "tf3api-nameplate-district" }, text = outward }
		end
		header[#header + 1] = builtin.Component {
			meta = { class = "tf3api-nameplate" },
			layout = builtin.BoxLayout { meta = { class = "tf3api-nameplate-layout" }, orientation = vertical, children = plate },
		}
	end

	local function row(label, value)
		return builtin.BoxLayout {
			meta = { class = "tf3api-road-row" },
			orientation = horizontal,
			children = {
				builtin.TextView { meta = { class = "tf3api-road-label" }, text = label },
				builtin.TextView { meta = { class = "tf3api-road-value" }, text = value },
			},
		}
	end
	local kindText = _(CLASS_NAMES[param.cls] or CLASS_NAMES[1])
	if abandoned then kindText = _("Abandoned") .. " (" .. kindText .. ")" end
	local details = {
		row(_("Kind"), kindText),
		row(_("Length"), formatLength(param.length)),
	}
	if postcode ~= nil then
		details[#details + 1] = row(_("Postcode here"), postcode)
		if postTown ~= nil and postTown ~= "" then details[#details + 1] = row(_("Post town"), postTown) end
	end
	details[#details + 1] = row(_("Segments"), tostring(param.segments))

	local children = {
		builtin.BoxLayout { meta = { class = "tf3api-road-header" }, orientation = horizontal, children = header },
		builtin.Component {
			meta = { class = "tf3api-road-details" },
			layout = builtin.BoxLayout { orientation = vertical, children = details },
		},
	}

	-- Abandoned: for a road that is cut off from the road network. It loses its number and shows an
	-- "Abandoned" badge with its name.
	if isolated then
		children[#children + 1] = builtin.CheckBox {
			meta = { class = "tf3api-road-option" },
			label = _("Abandoned"),
			initialValue = abandoned and 1 or 0,
			onValueChange = function(value)
				local b = bridge()
				if b == nil or type(b.post) ~= "function" then
					log("cannot mark the road abandoned: the native layer is missing or older than API version 4")
					return
				end
				local ok, sent, why = pcall(b.post, CHANNEL, string.format("abandon\t%d\t%d", param.id, (value ~= 0) and 1 or 0))
				if not ok or sent ~= true then log("the abandoned choice was not sent: " .. tostring(why or sent)) end
			end,
		}
	else
		children[#children + 1] = builtin.TextView {
			meta = { class = "tf3api-road-note" },
			text = _("To mark this road abandoned, first disconnect it from the road network."),
		}
	end

	return builtin.BoxLayout {
		meta = { class = "tf3api-road-content" },
		orientation = vertical,
		children = children,
	}
end)

-- The window itself. It has to be registered as a wrapper around the game's Window: the window container
-- only accepts nodes it can recognise as windows (a plain recipe here is a fatal error in the game).
RoadWindow = react.RegisterWrapperRecipe("Tf3apiRoadWindow", builtin.Window, function(param)
	local title = param.name ~= "" and param.name or param.ref
	if param.name ~= "" and param.ref ~= "" then title = param.ref .. "  " .. param.name end
	-- the number goes in the window's header on its sign (blue, green, white, or grey for an abandoned road),
	-- so the title is the name alone; a road with a number only (a motorway) keeps the number as its title
	local sign = nil
	if param.ref ~= "" then
		local kind = (param.flags or ""):find("a", 1, true) and "X" or signOf(param.ref)
		sign = builtin.BoxLayout {
			meta = { class = "tf3api-road-signrow" },
			orientation = builtin.type.Orientation.Horizontal,
			child = builtin.Component {
				meta = { class = "tf3api-sign, tf3api-sign-" .. kind },
				layout = builtin.BoxLayout {
					orientation = builtin.type.Orientation.Horizontal,
					child = builtin.TextView { meta = { class = "tf3api-sign-text, tf3api-sign-text-" .. kind }, text = param.ref },
				},
			},
		}
	end
	if param.name ~= "" then title = param.name end
	return builtin.Window {
		meta = { class = "tf3api-road-window" },
		id = windowKey(param.id),
		title = title,
		header = sign,
		closable = true,
		movable = true,
		onClose = function() closeWindow(param.id) end,
		content = RoadWindowContent(param),
	}
end)

local function openRoad(id, name, ref, cls, length, segments, flags, x, y)
	local param = { id = id, name = name or "", ref = ref or "", cls = cls or 1, length = length or 0, segments = segments or 0,
		flags = type(flags) == "string" and flags or "", x = x, y = y }
	local ok, err = pcall(function()
		game_react_globals.getDefaultWindowApi().addWindow(RoadWindow, windowKey(id), param)
	end)
	if not ok then
		log("could not open the road window: " .. tostring(err))
		return
	end
	log(string.format("opened the window of road %s '%s' %s", tostring(id), param.name, param.ref))
end

local announced, greeted = false, false

local function poll()
	local b = bridge()
	if b == nil or type(b.takeRoadClick) ~= "function" then
		if not announced then
			announced = true
			log("road labels cannot be clicked: the native layer (tf3api) is missing or older than API version 3")
		end
		return
	end
	if not announced then
		announced = true
		log("watching for clicks on road labels")
	end
	if type(b.take) == "function" then
		-- ask the naming script for what the window needs, once; then read what it sends
		if not greeted and type(b.post) == "function" then
			greeted = true
			pcall(b.post, CHANNEL, "hello")
		end
		for _ = 1, 4 do
			local okTake, message = pcall(b.take, UI_CHANNEL)
			if not okTake or type(message) ~= "string" then break end
			local planText = message:match("^postcodes\t(.*)$")
			if planText ~= nil and core ~= nil then
				local okPlan, plan = pcall(core.postcodePlanFromText, planText)
				if okPlan and plan ~= nil then postcodePlan = plan end
			end
		end
	end
	local ok, id, name, ref, cls, length, segments, flags, x, y = pcall(b.takeRoadClick)
	if ok and type(id) == "number" then openRoad(id, name, ref, cls, length, segments, flags, x, y) end
end

local RoadNamesHost = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "Tf3apiRoadNamesHost", function()
	react.onStep(function()
		local ok, err = pcall(poll)
		if not ok and logged < 20 then log("click polling failed: " .. tostring(err)) end
	end)
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

local M = {
	RoadNamesHost = RoadNamesHost,
	RoadWindow = RoadWindow,
}

-- a .script.lua module hands its functions to the game through data(); the plain return serves ug_require
function data()
	return M
end

return M
