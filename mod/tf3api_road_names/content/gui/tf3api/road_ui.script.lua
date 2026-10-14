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
-- A small "TF3OpenAPI" window is always there (drag it where it suits): it writes the street map page, lists
-- the cities the player has drawn and starts the tool for drawing one.
-- Drawing a city: a tool of the game's tool stack while it is open (so clicks on the map belong to it and
-- select nothing). Left click sets a corner of the outline, right click takes the last one back; the outline
-- is shown on the ground as it grows. With a name and at least three corners it can be finished: the outline
-- goes to the naming script, which works the roads and postcodes out again. London-style postcodes can be
-- chosen for a drawn city, for one on a map.
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
local startAdjustRoad   -- the Adjust Road tool, further down

local function sendToNaming(text)
	local b = bridge()
	if b == nil or type(b.post) ~= "function" then
		log("not sent: the native layer is missing or older than API version 4")
		return false
	end
	local ok, sent, why = pcall(b.post, CHANNEL, text)
	if not ok or sent ~= true then log("not sent: " .. tostring(why or sent)) return false end
	return true
end

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
		for _i, option in ipairs(options) do
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
					-- the name is taken on Enter and also when the field loses focus (clicking elsewhere,
					-- closing the window) - before, only Enter sent it and a click away threw it away
					acceptOnFocusLoss = true,
					resetValueOnCancel = false,
					onValueChange = function(text)
						local clean = tostring(text or ""):gsub("[\t\n\r]", " ")
						log(string.format("ui: road %d renamed to '%s'", param.id, clean))
						send(string.format("rename\t%d\t%s", param.id, clean))
					end,
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

	-- where the road runs: the green line with a circle at each end
	children[#children + 1] = builtin.Button {
		meta = { class = "tf3api-city-button" },
		content = builtin.TextView { text = _("Adjust road") },
		onClick = function()
			local id, name = param.id, (param.name ~= "") and param.name or param.ref
			closeWindow(id)   -- the road's number on its label changes when the road does
			startAdjustRoad(id, name)
		end,
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
	for _i, road in ipairs(param.connects) do
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
-- ---- Adjust Road: where a road runs -----------------------------------------------------------------------------
-- Opened from a road's window. The road is shown as a green line with a large circle at each end. Take an end
-- with the mouse and let it go where the road should end: on the road itself to make it shorter (the part
-- beyond becomes a road of its own), further along another road to make it longer (the segments on the way are
-- taken from the road they were part of). The road changes by whole segments; its ends are at junctions.
-- A click on an end picks it up as well; the next click sets it down.
-- The naming script works out what the line is and what a move does; this side shows it and reports the mouse.
local ADJUST_ZONE = "tf3apiRoadLine"
local ADJUST_GRAB = 70          -- how near to an end the mouse has to be to take it (metres)
local adjust = { anchor = nil, segments = {}, ends = {}, shown = 0, picked = nil, dragging = nil, note = "", version = 0 }

local function hideRoadLine()
	pcall(function()
		for i = 1, adjust.shown do pcall(api.gui.mission.removeZone, ADJUST_ZONE .. i) end
		pcall(api.gui.mission.removeZone, ADJUST_ZONE .. "End1")
		pcall(api.gui.mission.removeZone, ADJUST_ZONE .. "End2")
		adjust.shown = 0
	end)
end

local function showRoadLine()
	hideRoadLine()
	local ok, err = pcall(function()
		local mission = api.gui.mission
		local green = api.type.Vec4f.new(0.1, 0.8, 0.2, 0.6)
		local bright = api.type.Vec4f.new(0.9, 0.95, 0.2, 0.75)
		local half = 6   -- half the width of the line, in metres
		for i, s in ipairs(adjust.segments) do
			local dx, dy = s[3] - s[1], s[4] - s[2]
			local length = math.sqrt(dx * dx + dy * dy)
			if length > 0.1 then
				local nx, ny = -dy / length * half, dx / length * half
				mission.setZone(ADJUST_ZONE .. i, {
					api.type.Vec2f.new(s[1] + nx, s[2] + ny), api.type.Vec2f.new(s[3] + nx, s[4] + ny),
					api.type.Vec2f.new(s[3] - nx, s[4] - ny), api.type.Vec2f.new(s[1] - nx, s[2] - ny),
				}, true, green, false, false)
			end
		end
		adjust.shown = #adjust.segments
		for e, at in ipairs(adjust.ends) do
			mission.setZoneCircle(ADJUST_ZONE .. "End" .. e, api.type.Vec2f.new(at[1], at[2]), 28, true, (adjust.picked == e or adjust.dragging == e) and bright or green, false, false)
		end
	end)
	if not ok then log("the road's line could not be shown: " .. tostring(err)) end
end

-- what the naming script says about the road: its line, or why it has none
local function takeExtentMessage(message)
	local key, segmentsText, endsText = message:match("^extent\t([^\t]+)\t([^\t]*)\t([^\t]*)$")
	if key ~= nil then
		adjust.anchor, adjust.segments, adjust.ends, adjust.picked, adjust.dragging = key, {}, {}, nil, nil
		for part in segmentsText:gmatch("[^;]+") do
			local x0, y0, x1, y1 = part:match("^(%S+) (%S+) (%S+) (%S+)$")
			if x0 ~= nil then adjust.segments[#adjust.segments + 1] = { tonumber(x0), tonumber(y0), tonumber(x1), tonumber(y1) } end
		end
		local ax, ay, bx, by = endsText:match("^(%S+) (%S+) (%S+) (%S+)$")
		if ax ~= nil then adjust.ends = { { tonumber(ax), tonumber(ay) }, { tonumber(bx), tonumber(by) } } end
		adjust.note, adjust.pending = adjust.pending or "", nil
		adjust.version = adjust.version + 1
		if adjust.active then showRoadLine() end
		return true
	end
	local notice = message:match("^notice\t(.*)$")
	if notice ~= nil then
		adjust.pending = notice   -- shown with the line that follows it
		return true
	end
	local why = message:match("^extent%-none\t(.*)$")
	if why ~= nil then
		adjust.anchor, adjust.segments, adjust.ends = nil, {}, {}
		adjust.note = why
		adjust.version = adjust.version + 1
		hideRoadLine()
		return true
	end
	return false
end

local function terrainSpot()
	local ok, pos = pcall(function()
		if not api.gui.mouse.hasTerrainPosition() then return nil end
		return api.gui.mouse.getTerrainPosition()
	end)
	if ok and pos ~= nil then return pos.x, pos.y end
	return nil
end

local function endNear(x, y)
	local best, bestD
	for e, at in ipairs(adjust.ends) do
		local d = (at[1] - x) ^ 2 + (at[2] - y) ^ 2
		if d <= ADJUST_GRAB * ADJUST_GRAB and (bestD == nil or d < bestD) then best, bestD = e, d end
	end
	return best
end

local function adjustAction(onChange)
	return builtin.ActionDescriptor {
		children = {
			builtin.Selector {
				filter = function() return false end,
				onProcessMouseEvent = function(evt)
					local Type = api.gui.mouse.Event.Type
					if evt.button ~= 0 or adjust.anchor == nil then return false end
					if evt.type == Type.Pressed then
						local x, y = terrainSpot()
						if x == nil then return false end
						local e = endNear(x, y)
						if e ~= nil then
							adjust.dragging, adjust.pressedAt = e, { x, y }
							showRoadLine()
							onChange()
							return true
						end
						if adjust.picked ~= nil then
							-- an end was picked up by a click before: this click sets it down
							local e2 = adjust.picked
							adjust.picked = nil
							sendToNaming(string.format("adjust\t%s\t%d\t%.1f\t%.1f", adjust.anchor, e2, x, y))
							adjust.note = _("Working it out ...")
							onChange()
							return true
						end
						return false
					elseif evt.type == Type.Released and adjust.dragging ~= nil then
						local e = adjust.dragging
						adjust.dragging = nil
						local x, y = terrainSpot()
						local from = adjust.pressedAt or adjust.ends[e]
						if x ~= nil and from ~= nil and (x - from[1]) ^ 2 + (y - from[2]) ^ 2 > 40 * 40 then
							-- taken somewhere else and let go there
							sendToNaming(string.format("adjust\t%s\t%d\t%.1f\t%.1f", adjust.anchor, e, x, y))
							adjust.note = _("Working it out ...")
						else
							-- a click on the end: it is picked up, the next click sets it down
							adjust.picked = (adjust.picked ~= e) and e or nil
						end
						showRoadLine()
						onChange()
						return true
					end
					return false
				end,
			},
		},
	}
end

local ADJUST_WINDOW_ID = "tf3apiAdjustRoad"
local AdjustRoadTool

local AdjustRoadWindow = react.RegisterWrapperRecipe("Tf3apiAdjustRoadWindow", builtin.Window, function(param)
	local vertical = builtin.type.Orientation.Vertical
	local seen = react.useState(adjust.version)
	local touched = react.useState(0)
	react.onStep(function()
		if seen:old() ~= adjust.version then seen:set(adjust.version) end
	end)
	param.setActionFn(function() return adjustAction(function() touched:set(touched:old() + 1) end) end)
	local lines = {}
	if adjust.anchor == nil then
		lines[#lines + 1] = (adjust.note ~= "") and (_("This road cannot be adjusted: ") .. adjust.note) or _("Reading the road ...")
	else
		lines[#lines + 1] = string.format(_("%s: %d segments."), param.name ~= "" and param.name or _("This road"), #adjust.segments)
		if adjust.picked ~= nil then
			lines[#lines + 1] = _("An end is picked up: click where the road should end.")
		else
			lines[#lines + 1] = _("Take a circle at either end and let it go where the road should end,")
			lines[#lines + 1] = _("or click a circle and then click the place.")
		end
		if adjust.note ~= "" then lines[#lines + 1] = adjust.note end
	end
	local children = {}
	for _i, text in ipairs(lines) do
		children[#children + 1] = builtin.TextView { meta = { class = "tf3api-city-hint" }, text = text }
	end
	children[#children + 1] = builtin.Button {
		meta = { class = "tf3api-city-button" },
		content = builtin.TextView { text = _("Done") },
		onClick = param.onClose,
	}
	return builtin.Window {
		meta = { class = "tf3api-city-window" },
		id = ADJUST_WINDOW_ID,
		title = _("Adjust road"),
		closable = true,
		movable = true,
		onClose = param.onClose,
		content = builtin.BoxLayout { meta = { class = "tf3api-tools-content" }, orientation = vertical, children = children },
	}
end)

AdjustRoadTool = react.RegisterTool({
	name = "Tf3apiAdjustRoad",
	push = function(ctx, param)
		adjust.active = true
		game_react_globals.getDefaultWindowApi().addSingletonWindow(AdjustRoadWindow, { setActionFn = ctx.setActionFn, onClose = ctx.popSelf, name = param and param.name or "" })
	end,
	pop = function(ctx, param)
		adjust.active = false
		hideRoadLine()
		adjust.anchor, adjust.segments, adjust.ends, adjust.picked, adjust.dragging = nil, {}, {}, nil, nil
		game_react_globals.getDefaultWindowApi().removeAllWindows(AdjustRoadWindow)
	end,
})

-- from a road's window: the road with this label number
startAdjustRoad = function(roadId, roadName)
	adjust.anchor, adjust.segments, adjust.ends, adjust.picked, adjust.dragging, adjust.note = nil, {}, {}, nil, nil, ""
	adjust.version = adjust.version + 1
	if not sendToNaming(string.format("extent\t%d", roadId)) then return end
	local ok, err = pcall(function() game_react_globals.getDefaultToolStackApi().push(AdjustRoadTool, ADJUST_WINDOW_ID, { name = roadName or "" }, false) end)
	if not ok then log("the Adjust Road tool could not be started: " .. tostring(err)) end
end

-- ---- Cities: drawing one, and the list -------------------------------------------------------------------------
local playerCities = {}      -- from the naming script: { name, scheme, points }
local citiesVersion = 0      -- counts up when that list changes, so that the panel draws it again

-- The outline being drawn. It lives here and not in the window, so that it is still there when the window is
-- drawn again.
local DRAFT_ZONE = "tf3apiCityDraft"
local draft = { points = {}, name = "", scheme = "grid", shown = 0 }

-- the outline on the ground: a dot at each corner, and the area once there are three
local function showDraft()
	local ok, err = pcall(function()
		local mission = api.gui.mission
		pcall(mission.removeZone, DRAFT_ZONE)
		for i = 1, draft.shown do pcall(mission.removeZone, DRAFT_ZONE .. i) end
		draft.shown = #draft.points
		local colour = api.type.Vec4f.new(0.15, 0.75, 0.25, 0.55)
		for i, p in ipairs(draft.points) do
			mission.setZoneCircle(DRAFT_ZONE .. i, api.type.Vec2f.new(p[1], p[2]), 40, true, colour, false, false)
		end
		if #draft.points >= 3 then
			local polygon = {}
			for i, p in ipairs(draft.points) do polygon[i] = api.type.Vec2f.new(p[1], p[2]) end
			mission.setZone(DRAFT_ZONE, polygon, true, colour, false, false)
		end
	end)
	if not ok then log("the outline could not be shown on the ground: " .. tostring(err)) end
end

local function clearDraft()
	draft.points = {}
	showDraft()
end

-- what the tool does with the mouse on the map
local function drawAction(onChange)
	return builtin.ActionDescriptor {
		children = {
			builtin.Selector {
				filter = function() return false end,   -- nothing on the map is selected while drawing
				onProcessMouseEvent = function(evt)
					local Type = api.gui.mouse.Event.Type
					if evt.type ~= Type.Clicked then return false end
					if evt.button == 0 then
						local okPos, pos = pcall(function()
							if not api.gui.mouse.hasTerrainPosition() then return nil end
							return api.gui.mouse.getTerrainPosition()
						end)
						if okPos and pos ~= nil then
							draft.points[#draft.points + 1] = { pos.x, pos.y }
							showDraft()
							onChange()
						end
						return true
					elseif evt.button == 2 then
						if #draft.points > 0 then
							table.remove(draft.points)
							showDraft()
							onChange()
						end
						return true
					end
					return false
				end,
			},
		},
	}
end

local CITY_WINDOW_ID = "tf3apiCityDraw"
local CityDrawTool

local CityDrawWindow = react.RegisterWrapperRecipe("Tf3apiCityDrawWindow", builtin.Window, function(param)
	local horizontal, vertical = builtin.type.Orientation.Horizontal, builtin.type.Orientation.Vertical
	local corners = react.useState(#draft.points)
	local nameNow = react.useState(draft.name)
	param.setActionFn(function() return drawAction(function() corners:set(#draft.points) end) end)

	-- only one city on a map can have London-style postcodes
	local londonTaken = false
	for _i, city in ipairs(playerCities) do
		if city.scheme == "compass" and city.name ~= draft.name then londonTaken = true end
	end
	-- and only a city named London or Greater London (any case) can have them
	local londonName = tostring(draft.name or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
	if londonName ~= "london" and londonName ~= "greater london" then londonTaken = true end
	if londonTaken and draft.scheme == "compass" then draft.scheme = "grid" end
	local schemes = { builtin.ComboBoxItem { value = "grid", content = builtin.TextView { text = _("Ordinary (an area of its own)") } } }
	if not londonTaken then
		schemes[#schemes + 1] = builtin.ComboBoxItem { value = "compass", content = builtin.TextView { text = _("London style (N, E, SE, SW, W ...)") } }
	end

	local ready = #draft.points >= 3 and draft.name ~= ""
	local hint
	if #draft.points < 3 then
		hint = string.format(_("Click on the map to set corners: %d of at least 3. Right click takes the last one back."), #draft.points)
	elseif draft.name == "" then
		hint = string.format(_("%d corners. Give the city a name to finish."), #draft.points)
	else
		hint = string.format(_("%d corners. Add more, or finish."), #draft.points)
	end
	local function row(label, control)
		return builtin.BoxLayout {
			meta = { class = "tf3api-road-row" },
			orientation = horizontal,
			children = { builtin.TextView { meta = { class = "tf3api-road-label" }, text = label }, control },
		}
	end
	return builtin.Window {
		meta = { class = "tf3api-city-window" },
		id = CITY_WINDOW_ID,
		title = _("Draw a city"),
		closable = true,
		movable = true,
		onClose = param.onClose,
		content = builtin.BoxLayout {
			meta = { class = "tf3api-tools-content" },
			orientation = vertical,
			children = {
				builtin.TextView { meta = { class = "tf3api-city-hint" }, text = hint },
				row(_("Name"), builtin.TextInputField {
					meta = { class = "tf3api-road-input" },
					value = draft.name,
					placeholderText = _("the city's name"),
					onValueChange = function(text)
						draft.name = tostring(text or ""):gsub("[\t\n\r|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
						nameNow:set(draft.name)
					end,
				}),
				row(_("Postcodes"), builtin.ComboBox {
					meta = { class = "tf3api-road-choice" },
					value = draft.scheme,
					items = schemes,
					onValueChange = function(value) draft.scheme = (value == "compass") and "compass" or "grid" end,
				}),
				builtin.BoxLayout {
					meta = { class = "tf3api-road-row" },
					orientation = horizontal,
					children = {
						builtin.Button {
							meta = { class = "tf3api-city-button", enabled = #draft.points > 0 },
							content = builtin.TextView { text = _("Start again") },
							onClick = function()
								clearDraft()
								corners:set(0)
							end,
						},
						builtin.Button {
							meta = { class = "tf3api-city-button", enabled = ready },
							content = builtin.TextView { text = _("Finish") },
							onClick = function()
								if #draft.points < 3 or draft.name == "" then return end
								local numbers = {}
								for _i, p in ipairs(draft.points) do numbers[#numbers + 1] = string.format("%.0f %.0f", p[1], p[2]) end
								if sendToNaming(string.format("city\t%s\t%s\t%s", draft.name, draft.scheme, table.concat(numbers, " "))) then
									log(string.format("city '%s' drawn: %d corners, %s postcodes", draft.name, #draft.points, draft.scheme == "compass" and "London-style" or "ordinary"))
									draft.name, draft.scheme = "", "grid"
									clearDraft()
									param.onClose()
								end
							end,
						},
					},
				},
			},
		},
	}
end)

CityDrawTool = react.RegisterTool({
	name = "Tf3apiCityDraw",
	push = function(ctx, param)
		showDraft()
		game_react_globals.getDefaultWindowApi().addSingletonWindow(CityDrawWindow, { setActionFn = ctx.setActionFn, onClose = ctx.popSelf })
	end,
	pop = function(ctx, param)
		-- the outline is kept (the tool can be picked up again), but no longer shown
		pcall(function()
			pcall(api.gui.mission.removeZone, DRAFT_ZONE)
			for i = 1, draft.shown do pcall(api.gui.mission.removeZone, DRAFT_ZONE .. i) end
			draft.shown = 0
		end)
		game_react_globals.getDefaultWindowApi().removeAllWindows(CityDrawWindow)
	end,
})

local function startCityDraw()
	closeOpenModal(nil)
	local ok, err = pcall(function() game_react_globals.getDefaultToolStackApi().push(CityDrawTool, CITY_WINDOW_ID, {}, false) end)
	if not ok then log("the city drawing tool could not be started: " .. tostring(err)) end
end

local ToolsWindow = react.RegisterWrapperRecipe("Tf3apiToolsWindow", builtin.Window, function()
	local horizontal, vertical = builtin.type.Orientation.Horizontal, builtin.type.Orientation.Vertical
	-- drawn again when the list of cities changes
	local seen = react.useState(citiesVersion)
	react.onStep(function()
		if seen:old() ~= citiesVersion then seen:set(citiesVersion) end
	end)
	local children = {
		builtin.Button {
			meta = { class = "tf3api-tools-button", tooltip = _("Writes road_map.html into tf3api_out in the game folder") },
			content = builtin.TextView { text = _("Write street map") },
			onClick = function() sendToNaming("export") end,
		},
		builtin.Button {
			meta = { class = "tf3api-tools-button", tooltip = _("Draw an outline round several towns to make one city of them") },
			content = builtin.TextView { text = _("Draw a city") },
			onClick = startCityDraw,
		},
	}
	-- (the loop variable must not be "_": that is the game's translate function, used in the loop)
	for index = 1, #playerCities do
		local city = playerCities[index]
		local name = city.name
		children[#children + 1] = builtin.BoxLayout {
			meta = { class = "tf3api-road-row" },
			orientation = horizontal,
			children = {
				builtin.TextView { meta = { class = "tf3api-city-name" }, text = name .. (city.scheme == "compass" and _("  (London postcodes)") or "") },
				builtin.Button {
					meta = { class = "tf3api-city-remove", tooltip = _("Removes the city; its towns go back to being places of their own") },
					content = builtin.TextView { text = _("Remove") },
					onClick = function() sendToNaming("city-remove\t" .. name) end,
				},
			},
		}
	end
	return builtin.Window {
		meta = { class = "tf3api-tools-window" },
		id = "tf3apiTools",
		title = "TF3OpenAPI",
		closable = false,
		movable = true,
		content = builtin.BoxLayout {
			meta = { class = "tf3api-tools-content" },
			orientation = vertical,
			children = children,
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
		for _i = 1, 4 do
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
			takeExtentMessage(message)
			local citiesText = message:match("^cities\t(.*)$")
			if citiesText ~= nil then
				playerCities = {}
				for line in citiesText:gmatch("[^\n]+") do
					local name, scheme, points = line:match("^([^|]*)|([^|]*)|([^|]*)$")
					if name ~= nil and name ~= "" then playerCities[#playerCities + 1] = { name = name, scheme = scheme, points = tonumber(points) or 0 } end
				end
				citiesVersion = citiesVersion + 1
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
