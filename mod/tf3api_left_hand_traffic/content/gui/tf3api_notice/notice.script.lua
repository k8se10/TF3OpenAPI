-- TF3OpenAPI notice (written by tools/make_notices.py).
--
-- TF3OpenAPI is installed as a whole: its native layer (winhttp.dll and tf3api.ini beside TransportFever3.exe)
-- together with its mods. A converted mod also needs the old mod it was made from in legacy_mods beside the
-- game. When this mod is switched on in a game where that is not so, this script says what is missing, in one
-- window shared by every TF3OpenAPI and converted mod of the game (each mod's copy of this script adds its own
-- line; the first one opens the window, once).

local MOD_ID = "tf3api_left_hand_traffic"
local MOD_NAME = "TF3OpenAPI left-hand traffic"
local KIND = "api"         -- "api": a TF3OpenAPI mod; "converted": made by its converter
local FOLDER = ""   -- converted: the old mod's folder in legacy_mods

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"

local WINDOW = "tf3apiNotice"
local WAIT_STEPS = 60   -- the other mods' copies add their lines before the window opens

local function log(text)
	local line = "[" .. MOD_ID .. "] notice: " .. tostring(text)
	if not pcall(function() debugPrint(line) end) then print(line) end
end

-- what every copy of this script in this interface shares
local function shared()
	local s = rawget(_G, "TF3API_NOTICE")
	if s == nil then
		s = { problems = {}, order = {}, owner = nil, shown = false }
		rawset(_G, "TF3API_NOTICE", s)
	end
	return s
end

-- "native": the native layer is not running; "source": the old mod is not in legacy_mods; nil: all is well
local function problem()
	local ok, b = pcall(function() return tf3api end)
	if not ok or type(b) ~= "table" then return "native" end
	if KIND == "converted" then
		if type(b.modProblem) == "function" then
			local okP, p = pcall(b.modProblem, MOD_ID)
			if okP and p == "source" then return "source" end
		elseif type(b.legacySource) == "function" then
			local okS, present = pcall(b.legacySource, FOLDER)
			if okS and present == false then return "source" end
		end
	end
	return nil
end

local function listOf(kind)
	local s = shared()
	local names = {}
	for _i, id in ipairs(s.order) do
		local p = s.problems[id]
		if p ~= nil and p.problem == kind then
			names[#names + 1] = (p.kind == "converted" and p.folder ~= "") and (p.name .. " (from \"" .. p.folder .. "\")") or p.name
		end
	end
	return names
end

local function paragraphs()
	local out = {}
	local native = listOf("native")
	if #native > 0 then
		out[#out + 1] = "The TF3OpenAPI native layer is not running, so these mods cannot work: " .. table.concat(native, ", ") .. "."
		out[#out + 1] = "TF3OpenAPI is installed as a whole: the native layer (winhttp.dll and tf3api.ini beside TransportFever3.exe) together with its mods. Get it from github.com/k8se10/TF3OpenAPI, or switch these mods off for this game."
		out[#out + 1] = "Mods converted by TF3OpenAPI also need the old mod they were made from in the legacy_mods folder beside the game."
	end
	local source = listOf("source")
	if #source > 0 then
		out[#out + 1] = "These mods were converted by TF3OpenAPI from old mods that are no longer in the legacy_mods folder beside the game: " .. table.concat(source, ", ") .. "."
		out[#out + 1] = "What they add is not offered until the old mod is back. Put each old mod's folder back in legacy_mods and start the game again. Anything of theirs already in this game keeps running."
	end
	return out
end

local NoticeWindow
NoticeWindow = react.RegisterWrapperRecipe("Tf3apiNoticeWindow_" .. MOD_ID, builtin.Window, function(param)
	local children = {}
	for _i, text in ipairs(paragraphs()) do
		children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" }, text = text }
	end
	return builtin.Window {
		id = WINDOW,
		title = "TF3OpenAPI",
		closable = true,
		movable = true,
		onClose = function()
			pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(NoticeWindow, WINDOW) end)
		end,
		content = builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = children },
	}
end)

local checked, steps, failed = false, 0, false

local function step()
	local s = shared()
	if not checked then
		checked = true
		local p = problem()
		if p == nil then return end
		s.problems[MOD_ID] = { name = MOD_NAME, kind = KIND, folder = FOLDER, problem = p }
		s.order[#s.order + 1] = MOD_ID
		if s.owner == nil then s.owner = MOD_ID end
		log(p == "native" and "the native layer is not running" or ("the old mod \"" .. FOLDER .. "\" is not in legacy_mods"))
	end
	if s.owner ~= MOD_ID or s.shown then return end
	steps = steps + 1
	if steps < WAIT_STEPS then return end
	s.shown = true
	local ok, err = pcall(function() game_react_globals.getDefaultWindowApi().addSingletonWindow(NoticeWindow, {}) end)
	if not ok then log("the notice window could not be opened: " .. tostring(err)) end
end

local Host = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "Tf3apiNoticeHost_" .. MOD_ID, function()
	react.onStep(function()
		local ok, err = pcall(step)
		if not ok and not failed then
			failed = true
			log("failed: " .. tostring(err))
		end
	end)
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

local M = { Host = Host }

function data()
	return M
end

return M
