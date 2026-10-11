-- TF3OpenAPI - road names: the interface.
--
-- Road names and number signs are drawn in the world by the native layer. When the player clicks one, the
-- native layer reports the road through tf3api.takeRoadClick(); this script picks that up and opens the
-- road's window.
--
-- First version of the window: the road's number, name, kind and length. Renaming, road type, label style,
-- statistics and the Adjust Road tool are added to this window next.
--
-- Log: lines "[tf3api_road_names] ui:" in crash_dump/stdout.txt and "[script]" lines in tf3api.log.

local MOD_ID = "tf3api_road_names"

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"

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

local CLASS_NAMES = { "Road", "Main road", "Motorway" }

local function formatLength(metres)
	local ok, text = pcall(function() return api.util.formatLength(metres) end)
	if ok and type(text) == "string" then return text end
	return string.format("%.0f m", metres)
end

local function windowKey(id) return "tf3apiRoad" .. tostring(id) end

local RoadWindow

local function closeWindow(id)
	local ok, err = pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(RoadWindow, windowKey(id)) end)
	if not ok then log("could not close the road window: " .. tostring(err)) end
end

-- param: { id, name, ref, cls, length, segments }
RoadWindow = react.RegisterRecipe("Tf3apiRoadWindow", function(param)
	local title = param.name ~= "" and param.name or param.ref
	if param.name ~= "" and param.ref ~= "" then title = param.ref .. "  " .. param.name end
	local function row(label, value)
		return builtin.BoxLayout {
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.TextView { text = label .. ":  " },
				builtin.TextView { text = value },
			},
		}
	end
	local rows = {}
	if param.ref ~= "" then rows[#rows + 1] = row(_("Number"), param.ref) end
	if param.name ~= "" then rows[#rows + 1] = row(_("Name"), param.name) end
	rows[#rows + 1] = row(_("Kind"), _(CLASS_NAMES[param.cls] or CLASS_NAMES[1]))
	rows[#rows + 1] = row(_("Length"), formatLength(param.length))
	rows[#rows + 1] = row(_("Segments"), tostring(param.segments))
	return builtin.Window {
		id = windowKey(param.id),
		title = title,
		closable = true,
		movable = true,
		onClose = function() closeWindow(param.id) end,
		content = builtin.BoxLayout {
			orientation = builtin.type.Orientation.Vertical,
			children = rows,
		},
	}
end)

local function openRoad(id, name, ref, cls, length, segments)
	local param = { id = id, name = name or "", ref = ref or "", cls = cls or 1, length = length or 0, segments = segments or 0 }
	local ok, err = pcall(function()
		local windows = game_react_globals.getDefaultWindowApi()
		windows.addWindow(RoadWindow, windowKey(id), param)
		windows.moveWindowToFront(RoadWindow, windowKey(id))
	end)
	if not ok then
		log("could not open the road window: " .. tostring(err))
		return
	end
	pcall(function() api.gui.byId.setVisible(windowKey(id), true) end)
	log(string.format("opened the window of road %s '%s' %s", tostring(id), param.name, param.ref))
end

local announced = false

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
	local ok, id, name, ref, cls, length, segments = pcall(b.takeRoadClick)
	if ok and type(id) == "number" then openRoad(id, name, ref, cls, length, segments) end
end

local RoadNamesHost = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "Tf3apiRoadNamesHost", function()
	react.onStep(function()
		local ok, err = pcall(poll)
		if not ok and logged < 20 then log("click polling failed: " .. tostring(err)) end
	end)
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

return {
	RoadNamesHost = RoadNamesHost,
	RoadWindow = RoadWindow,
}
