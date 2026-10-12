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
-- Below that the road can be changed: its name, its type (automatic, ordinary road, B road, A road, A road
-- motorway section, motorway) and what its label shows (number and name, number only, name only). Each
-- change is sent to the naming script, which names and draws the roads again; the window shows the new state
-- when it is opened again.
-- A small "TF3OpenAPI" window is always there (drag it where it suits): it writes the street map page.
-- Statistics and the Adjust Road tool are still to come.
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
local junctions = {}       -- likewise: every motorway junction, by its place in the list

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

-- One of the mod's windows at a time: opening a road's or a junction's window closes the one that was open.
-- (The small TF3OpenAPI window is not one of these: it is the mod's standing panel, not something opened by
-- a click in the world.)
local openModal = nil   -- { key = <window key>, close = function }

local function closeOpenModal(exceptKey)
	local modal = openModal
	if modal == nil or modal.key == exceptKey then return end
	openModal = nil
	local ok, err = pcall(modal.close)
	if not ok then log("could not close the window that was open: " .. tostring(err)) end
end

local function modalClosed(key)
	if openModal ~= nil and openModal.key == key then openModal = nil end
end

local function closeWindow(id)
	modalClosed(windowKey(id))
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
	local function send(text)
		local b = bridge()
		if b == nil or type(b.post) ~= "function" then
			log("the change was not sent: the native layer is missing or older than API version 4")
			return
		end
		local ok, sent, why = pcall(b.post, CHANNEL, text)
		if not ok or sent ~= true then log("the change was not sent: " .. tostring(why or sent)) end
	end
	local function choice(label, current, options, onChange)
		local items = {}
		for _, option in ipairs(options) do
			items[#items + 1] = builtin.ComboBoxItem { value = option[1], content = builtin.TextView { text = option[2] } }
		end
		return builtin.BoxLayout {
			meta = { class = "tf3api-road-row" },
			orientation = horizontal,
			children = {
				builtin.TextView { meta = { class = "tf3api-road-label" }, text = label },
				builtin.ComboBox { meta = { class = "tf3api-road-choice" }, value = current, items = items, onValueChange = onChange },
			},
		}
	end
	-- what the player has chosen for this road so far comes back in the flags: T + type, S + label style
	local typeNow = ({ N = "N", B = "B", A = "A", X = "AM", M = "M" })[flags:match("T(%a)") or ""] or "auto"
	local styleNow = ({ b = "both", n = "number", m = "name" })[flags:match("S(%a)") or ""] or "auto"
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
	-- what the road can carry, worked out from its lanes (sent by the naming script as L lanes; V speed in
	-- m/s; C vehicles an hour each way; W 1 = one-way)
	local info = param.info or ""
	local lanes, speed, capacity, oneWay = tonumber(info:match("L(%d+)")), tonumber(info:match("V([%d%.]+)")), tonumber(info:match("C(%d+)")), info:match("W(%d)") == "1"
	if lanes ~= nil and capacity ~= nil then
		details[#details + 1] = row(_("Lanes"), oneWay and string.format(_("%d, one-way"), lanes) or string.format(_("%d each way"), lanes))
		if speed ~= nil then
			local okSpeed, speedText = pcall(function() return api.util.formatSpeed(speed) end)
			details[#details + 1] = row(_("Speed limit"), (okSpeed and type(speedText) == "string") and speedText or string.format("%.0f m/s", speed))
		end
		details[#details + 1] = row(_("Can carry"), oneWay and string.format(_("%d vehicles an hour"), capacity)
			or string.format(_("%d vehicles an hour each way"), capacity))
		details[#details + 1] = row(_("Traffic now"), _("not measured yet"))
	end
	details[#details + 1] = row(_("Segments"), tostring(param.segments))

	-- the settings of this road
	local settings = {
		builtin.BoxLayout {
			meta = { class = "tf3api-road-row" },
			orientation = horizontal,
			children = {
				builtin.TextView { meta = { class = "tf3api-road-label" }, text = _("Name") },
				builtin.TextInputField {
					meta = { class = "tf3api-road-input" },
					value = param.name,
					placeholderText = _("automatic"),
					onValueChange = function(text) send(string.format("rename\t%d\t%s", param.id, tostring(text or ""):gsub("[\t\n\r]", " "))) end,
				},
			},
		},
		choice(_("Road type"), typeNow, {
			{ "auto", _("Automatic") }, { "N", _("Ordinary road") }, { "B", _("B road") }, { "A", _("A road") },
			{ "AM", _("A road (M)") }, { "M", _("Motorway") },
		}, function(value) send(string.format("type\t%d\t%s", param.id, tostring(value))) end),
		choice(_("Label shows"), styleNow, {
			{ "auto", _("Number and name") }, { "number", _("Number only") }, { "name", _("Name only") },
		}, function(value) send(string.format("style\t%d\t%s", param.id, tostring(value))) end),
	}
	local children = {
		builtin.BoxLayout { meta = { class = "tf3api-road-header" }, orientation = horizontal, children = header },
		builtin.Component {
			meta = { class = "tf3api-road-details" },
			layout = builtin.BoxLayout { meta = { class = "tf3api-road-detail-list" }, orientation = vertical, children = details },
		},
		builtin.Component {
			meta = { class = "tf3api-road-details" },
			layout = builtin.BoxLayout { meta = { class = "tf3api-road-detail-list" }, orientation = vertical, children = settings },
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

local function openRoad(id, name, ref, cls, length, segments, flags, x, y, info)
	local param = { id = id, name = name or "", ref = ref or "", cls = cls or 1, length = length or 0, segments = segments or 0,
		flags = type(flags) == "string" and flags or "", x = x, y = y, info = type(info) == "string" and info or "" }
	local key = windowKey(id)
	closeOpenModal(key)
	local ok, err = pcall(function()
		game_react_globals.getDefaultWindowApi().addWindow(RoadWindow, key, param)
	end)
	if not ok then
		log("could not open the road window: " .. tostring(err))
		return
	end
	openModal = { key = key, close = function() game_react_globals.getDefaultWindowApi().removeWindow(RoadWindow, key) end }
	log(string.format("opened the window of road %s '%s' %s", tostring(id), param.name, param.ref))
end

-- ---- The junction window ---------------------------------------------------------------------------------------
-- Opened by clicking a junction's number. param: { index, x, y } plus the junction's own fields.
local JunctionWindow

local function junctionKey(index) return "tf3apiJunction" .. tostring(index) end

local JunctionWindowContent = react.RegisterRecipe("Tf3apiJunctionWindowContent", function(param)
	local horizontal, vertical = builtin.type.Orientation.Horizontal, builtin.type.Orientation.Vertical
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
	local postcode, postTown
	if core ~= nil and postcodePlan ~= nil then
		local ok, full, _, town = pcall(core.postcode, postcodePlan, param.x, param.y)
		if ok then postcode, postTown = full, town end
	end
	local details = {
		row(_("Motorway"), param.ref),
		row(_("Junction"), string.format(_("%d of %d"), param.number, param.of)),
	}
	if param.toPrevious ~= nil then details[#details + 1] = row(string.format(_("To junction %d"), param.number - 1), formatLength(param.toPrevious)) end
	if param.toNext ~= nil then details[#details + 1] = row(string.format(_("To junction %d"), param.number + 1), formatLength(param.toNext)) end
	if postTown ~= nil and postTown ~= "" then details[#details + 1] = row(_("Nearest town"), postTown) end
	if postcode ~= nil then details[#details + 1] = row(_("Postcode"), postcode) end
	details[#details + 1] = row(_("Slip road ends"), tostring(param.points))

	-- what the junction connects: each road on its own line
	local roads = { builtin.TextView { meta = { class = "tf3api-junction-heading" }, text = _("Connects to") } }
	if #param.connects == 0 then
		roads[#roads + 1] = builtin.TextView { meta = { class = "tf3api-road-value" }, text = _("no other road yet") }
	end
	for _, road in ipairs(param.connects) do
		roads[#roads + 1] = builtin.TextView { meta = { class = "tf3api-road-value" }, text = road }
	end

	return builtin.BoxLayout {
		meta = { class = "tf3api-road-content" },
		orientation = vertical,
		children = {
			builtin.Component {
				meta = { class = "tf3api-road-details" },
				layout = builtin.BoxLayout { meta = { class = "tf3api-road-detail-list" }, orientation = vertical, children = roads },
			},
			builtin.Component {
				meta = { class = "tf3api-road-details" },
				layout = builtin.BoxLayout { meta = { class = "tf3api-road-detail-list" }, orientation = vertical, children = details },
			},
		},
	}
end)

JunctionWindow = react.RegisterWrapperRecipe("Tf3apiJunctionWindow", builtin.Window, function(param)
	local function sign(text, kind)
		return builtin.Component {
			meta = { class = "tf3api-sign, tf3api-sign-" .. kind },
			layout = builtin.BoxLayout {
				orientation = builtin.type.Orientation.Horizontal,
				child = builtin.TextView { meta = { class = "tf3api-sign-text, tf3api-sign-text-" .. kind }, text = text },
			},
		}
	end
	return builtin.Window {
		meta = { class = "tf3api-road-window" },
		id = junctionKey(param.index),
		title = string.format(_("Junction %d"), param.number),
		closable = true,
		movable = true,
		onClose = function()
			modalClosed(junctionKey(param.index))
			pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(JunctionWindow, junctionKey(param.index)) end)
		end,
		header = builtin.BoxLayout {
			meta = { class = "tf3api-road-signrow" },
			orientation = builtin.type.Orientation.Horizontal,
			children = { sign(param.ref, "M"), sign(tostring(param.number), "J") },
		},
		content = JunctionWindowContent(param),
	}
end)

local function openJunction(index, x, y)
	local junction = junctions[index]
	if junction == nil then
		log("junction " .. tostring(index) .. " was clicked, but its details have not arrived yet")
		return
	end
	local param = { index = index, x = junction.x, y = junction.y, ref = junction.ref, number = junction.number, of = junction.of,
		points = junction.points, toPrevious = junction.toPrevious, toNext = junction.toNext, connects = junction.connects }
	local key = junctionKey(index)
	closeOpenModal(key)
	local ok, err = pcall(function() game_react_globals.getDefaultWindowApi().addWindow(JunctionWindow, key, param) end)
	if not ok then log("could not open the junction window: " .. tostring(err)) return end
	openModal = { key = key, close = function() game_react_globals.getDefaultWindowApi().removeWindow(JunctionWindow, key) end }
	log(string.format("opened the window of %s junction %d", tostring(junction.ref), junction.number))
end

-- The mod's own small window, always there while playing: for now one button, which writes the street map.
local ToolsWindow = react.RegisterWrapperRecipe("Tf3apiToolsWindow", builtin.Window, function()
	return builtin.Window {
		meta = { class = "tf3api-tools-window" },
		id = "tf3apiTools",
		title = "TF3OpenAPI",
		closable = false,
		movable = true,
		content = builtin.BoxLayout {
			meta = { class = "tf3api-tools-content" },
			orientation = builtin.type.Orientation.Vertical,
			children = {
				builtin.Button {
					meta = { class = "tf3api-tools-button", tooltip = _("Writes road_map.html into tf3api_out in the game folder") },
					content = builtin.TextView { text = _("Write street map") },
					onClick = function()
						local b = bridge()
						if b ~= nil and type(b.post) == "function" then pcall(b.post, CHANNEL, "export") end
					end,
				},
			},
		},
	}
end)

local announced, greeted, toolsOpened = false, false, false

-- Labels can only be clicked while the player is just looking round: with a tool in hand (building, upgrading,
-- bulldozing, anything) a click belongs to that tool, and must not open a road or junction window as well.
-- The game's tool stack says which tool is active; the one for looking round is its default, EntityDetailsTool.
local IDLE_TOOLS = { EntityDetailsTool = true }
local lastBusyTool = nil

local function clicksAllowed()
	local ok, tool = pcall(function() return (game_react_globals.getDefaultToolStackApi().getActiveTool()) end)
	if not ok then return true end   -- cannot tell: behave as before
	local name = tool ~= nil and tostring(tool.name) or nil
	if name == nil or IDLE_TOOLS[name] then
		lastBusyTool = nil
		return true
	end
	if name ~= lastBusyTool then
		lastBusyTool = name
		log("labels are not clickable while a tool is in use (" .. name .. ")")
	end
	return false
end

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
	if not toolsOpened then
		toolsOpened = true
		local okTools, err = pcall(function() game_react_globals.getDefaultWindowApi().addSingletonWindow(ToolsWindow, {}) end)
		if not okTools then log("could not open the TF3OpenAPI window: " .. tostring(err)) end
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
			local notice = message:match("^notice\t(.*)$")
			if notice ~= nil then log("notice: " .. notice) end
			local junctionText = message:match("^junctions\t(.*)$")
			if junctionText ~= nil then
				junctions = {}
				for line in junctionText:gmatch("[^\n]+") do
					local ref, number, of, x, y, points, toPrevious, toNext, roads = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
					if ref ~= nil and tonumber(number) ~= nil then
						local connects = {}
						for road in roads:gmatch("[^;]+") do connects[#connects + 1] = road end
						junctions[#junctions + 1] = { ref = ref, number = tonumber(number), of = tonumber(of) or 0, x = tonumber(x) or 0, y = tonumber(y) or 0,
							points = tonumber(points) or 0, toPrevious = (tonumber(toPrevious) or -1) >= 0 and tonumber(toPrevious) or nil,
							toNext = (tonumber(toNext) or -1) >= 0 and tonumber(toNext) or nil, connects = connects }
					end
				end
			end
			local planText = message:match("^postcodes\t(.*)$")
			if planText ~= nil and core ~= nil then
				local okPlan, plan = pcall(core.postcodePlanFromText, planText)
				if okPlan and plan ~= nil then postcodePlan = plan end
			end
		end
	end
	local ok, id, name, ref, cls, length, segments, flags, x, y, info = pcall(b.takeRoadClick)
	-- (a click is always taken, so that one made with a tool in hand is not kept for later)
	if ok and type(id) == "number" and id > 0 and not clicksAllowed() then return end
	-- the flag J marks a junction number: it has a window of its own
	if ok and type(id) == "number" and id > 0 then
		if type(flags) == "string" and flags:find("J", 1, true) then
			openJunction(id, x, y)
		else
			openRoad(id, name, ref, cls, length, segments, flags, x, y, info)
		end
	end
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
