-- TF3OpenAPI - departure boards: the board's window.
--
-- The game does not let assets be selected, so a board cannot be clicked the game's way. The boards script
-- hands the boards' places to the native layer (tf3api.boardSpots); a click on one is reported here
-- (tf3api.takeBoardClick) and the board's window opens: the live picture of its station from straight above
-- (the native plan view), which platforms the board serves, and how it shows several.
--
-- What the window needs to know about each board comes from the boards script on the channel
-- "tf3api_departure_boards.ui"; choices go back on "tf3api_departure_boards".

local MOD_ID = "tf3api_departure_boards"
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"

local CHANNEL = "tf3api_departure_boards"
local UI_CHANNEL = "tf3api_departure_boards.ui"

local function bridge()
	local ok, t = pcall(function() return tf3api end)
	if ok and type(t) == "table" then return t end
	return nil
end

local logged = 0
local function log(text)
	logged = logged + 1
	local b = bridge()
	if b ~= nil and logged <= 100 then pcall(b.log, "[" .. MOD_ID .. "] ui: " .. tostring(text)) end
end

-- what the boards script told us: [board id] = { stationName =, kind =, platforms = { n, ... },
-- chosen = { [n] = true }, mode = "merged" | "cycle" }
local boards = {}

local function send(text)
	local b = bridge()
	if b ~= nil and type(b.post) == "function" then pcall(b.post, CHANNEL, text) end
end

local function chosenText(chosen)
	local list = {}
	for n in pairs(chosen) do list[#list + 1] = n end
	table.sort(list)
	return table.concat(list, ",")
end

local BoardWindow
local openKey = nil

local function windowKey(id) return "tf3api_board_" .. tostring(id) end

local BoardWindowContent = react.RegisterRecipe("Tf3apiBoardWindowContent", function(param)
	local horizontal, vertical = builtin.type.Orientation.Horizontal, builtin.type.Orientation.Vertical
	local info = boards[param.id] or {}
	local chosen = react.useState(info.chosen or {})
	local mode = react.useState(info.mode or "merged")

	local function row(label, child)
		return builtin.BoxLayout {
			meta = { class = "tf3api-board-row" },
			orientation = horizontal,
			children = { builtin.TextView { meta = { class = "tf3api-board-label" }, text = label }, child },
		}
	end

	-- one button per platform; a chosen one is marked
	local buttons = {}
	for _i, n in ipairs(info.platforms or {}) do
		local on = chosen:old()[n] == true
		buttons[#buttons + 1] = builtin.Button {
			meta = { class = on and "primary" or "secondary" },
			content = builtin.TextView { text = (on and "[x] " or "[ ] ") .. string.format(_("Platform %d"), n) },
			onClick = function()
				local now = {}
				for k, v in pairs(chosen:old()) do now[k] = v end
				if now[n] then now[n] = nil else now[n] = true end
				chosen:set(now)
				send(string.format("set\t%d\t%s\t%s", param.id, chosenText(now), mode:old()))
			end,
		}
	end
	if #buttons == 0 then
		buttons[1] = builtin.TextView { text = _("No platforms known yet: the board has not joined a station.") }
	end

	local modeItems = {
		builtin.ComboBoxItem { value = "merged", content = builtin.TextView { text = _("One list, sorted by time") } },
		builtin.ComboBoxItem { value = "cycle", content = builtin.TextView { text = _("One platform at a time, in turn") } },
	}

	local children = {}
	if not param.noView and info.entity ~= nil then   -- a live view needs the game's entity of the board
		children[#children + 1] = builtin.Component {
			meta = { class = "tf3api-board-view" },
			layout = builtin.BoxLayout { orientation = vertical, child = builtin.EntityRendererComponent { entity = info.entity } },
		}
	end
	for _i, child in ipairs({
			row(_("Station"), builtin.TextView { text = info.stationName or _("none in reach") }),
			row(_("Shows"), builtin.TextView { text = info.kind == "arrivals" and _("Arrivals") or _("Departures") }),
			builtin.TextView { text = _("Platforms this board serves (none chosen: all of them)") },
			builtin.BoxLayout { meta = { class = "tf3api-board-platforms" }, orientation = horizontal, children = buttons },
			builtin.Button {
				meta = { class = "secondary" },
				content = builtin.TextView { text = _("Forget this board (it was removed)") },
				onClick = function()
					send(string.format("forget\t%d", param.id))
					boards[param.id] = nil
					pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(BoardWindow, windowKey(param.id)) end)
					openKey = nil
				end,
			},
			row(_("Several platforms"), builtin.ComboBox {
				value = mode:old(),
				items = modeItems,
				onValueChange = function(value)
					mode:set(value)
					send(string.format("set\t%d\t%s\t%s", param.id, chosenText(chosen:old()), tostring(value)))
				end,
			}),
		}) do children[#children + 1] = child end
	return builtin.BoxLayout { meta = { class = "tf3api-board-content" }, orientation = vertical, children = children }
end)

BoardWindow = react.RegisterWrapperRecipe("Tf3apiBoardWindow", builtin.Window, function(param)
	local info = boards[param.id] or {}
	return builtin.Window {
		meta = { class = "tf3api-board-window" },
		id = windowKey(param.id),
		title = info.stationName ~= nil and string.format(_("Departure board - %s"), info.stationName) or _("Departure board"),
		closable = true,
		movable = true,
		onClose = function()
			pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(BoardWindow, windowKey(param.id)) end)
			if openKey == windowKey(param.id) then openKey = nil end
		end,
		content = BoardWindowContent(param),
	}
end)

local function openBoard(id)
	local key = windowKey(id)
	if openKey ~= nil and openKey ~= key then
		local old = openKey
		pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(BoardWindow, old) end)
	end
	local ok, err = pcall(function() game_react_globals.getDefaultWindowApi().addWindow(BoardWindow, key, { id = id }) end)
	if not ok then
		log("could not open the board window: " .. tostring(err))
		return
	end
	openKey = key
	log("opened the window of board " .. tostring(id))
end

-- only while the player is looking round, not with a tool in hand
local function clicksAllowed()
	local ok, tool = pcall(function() return (game_react_globals.getDefaultToolStackApi().getActiveTool()) end)
	if not ok then return true end
	local name = tool ~= nil and tostring(tool.name) or nil
	return name == nil or name == "EntityDetailsTool"
end

local function poll()
	local b = bridge()
	if b == nil or type(b.takeBoardClick) ~= "function" then return end
	-- what the boards script says about each board: "board\tid\tstationName\tkind\tplatforms\tchosen\tmode"
	if type(b.take) == "function" then
		for _i = 1, 64 do
			local okTake, message = pcall(b.take, UI_CHANNEL)
			if not okTake or type(message) ~= "string" then break end
			local id, name, kind, platforms, chosen, mode, entity = message:match("^board\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(%d*)$")
			id = tonumber(id)
			if id ~= nil then
				local entry = { entity = tonumber(entity), stationName = name ~= "" and name or nil, kind = kind, platforms = {}, chosen = {}, mode = mode ~= "" and mode or "merged" }
				for n in platforms:gmatch("%d+") do entry.platforms[#entry.platforms + 1] = tonumber(n) end
				for n in chosen:gmatch("%d+") do entry.chosen[tonumber(n)] = true end
				boards[id] = entry
			end
		end
	end
	local ok, id = pcall(b.takeBoardClick)
	if ok and type(id) == "string" and clicksAllowed() then
		local board = tonumber(id)
		-- only a board the boards script has told us about (its id may not be an entity of the game)
		if board ~= nil and boards[board] ~= nil then openBoard(board) end
	end
end

local BoardsHost = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "Tf3apiBoardsHost", function()
	react.onStep(function()
		local ok, err = pcall(poll)
		if not ok and logged < 20 then log("polling failed: " .. tostring(err)) end
	end)
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

-- The card in the game's own window of a board. Boards are plain constructions, so clicking one opens the
-- game's window for a construction (with its live picture); this card is added to it through the window's
-- extension point (see boards_card.res.lua) and stays empty for every other construction.
-- (A game file is named from the root of the game, "::/...": a bare "/..." would be looked for in this mod.
-- Should the game's file not be there, the card is simply missing - the rest of this script still works.)
local BoardCard
do
	local ok, err = pcall(function()
		local eow = ug_require "::/gui/entity_window/empty_construction/empty_construction_eow.script.tl"
		BoardCard = react.RegisterPluginRecipe(eow.EmptyConstructionEowExtensionPoint, "Tf3apiBoardCard", function(params)
			local id = params ~= nil and params.entityId or nil
			if id == nil or boards[id] == nil then
				return builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = {} }
			end
			return BoardWindowContent({ id = id, noView = true })
		end)
	end)
	if not ok then log("the card for the game's construction window could not be set up: " .. tostring(err)) end
end

local M = { BoardsHost = BoardsHost, BoardWindow = BoardWindow, BoardCard = BoardCard }
function data() return M end
return M
