-- TF3OpenAPI - placing in two steps: height with the middle mouse button.
--
-- While an object is pinned, the native layer turns a middle-button drag up or down into steps, left on the
-- queue "tf3api_placement.height" ("1" up, "-1" down). Here each step is handed to the construction tool in use
-- through its own handler of input actions - the one the game's construction scripts give the tool in
-- builtin.ConstructionAction { inputActionsHandler = ... } - as "constructRaise" / "constructLower": the game
-- raises or lowers the object and moves its height setting exactly as its raise / lower keys do.
-- To have that handler, builtin.ConstructionAction is wrapped once (the module table is shared by every
-- interface script); the wrapper only notes the handler and hands everything on unchanged.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"

local QUEUE = "tf3api_placement.height"
local handler = nil          -- the newest construction tool's input action handler
local told = 0

local function log(text)
	told = told + 1
	if told > 40 then return end
	pcall(function() if tf3api ~= nil and tf3api.log ~= nil then tf3api.log("[tf3api_placement] " .. text) end end)
end

do
	local original = builtin.ConstructionAction
	if type(original) == "function" or type(original) == "table" then
		local ok, why = pcall(function()
			builtin.ConstructionAction = function(param, ...)
				if type(param) == "table" and type(param.inputActionsHandler) == "function" and param.constructionBuilder ~= nil then
					handler = param.inputActionsHandler
				end
				return original(param, ...)
			end
		end)
		if not ok then log("the construction tool's handler cannot be reached: " .. tostring(why)) end
	end
end

-- The game's raise / lower handler steps 3 m unless its precision key is held. Telling it "held" from here did
-- not reach it (seen in the game: still 3 m), so the bottom bar's height setting is stepped directly: the
-- handler for "constructRaise" keeps the bottom bar (bottomBarApi) and the setting's key among its upvalues
-- (construction_react_util: addStepValueInputActionHandlers). Found by name through the debug library, once
-- per tool; false when anything is missing, and then the game's own 3 m step is used.
local FINE = 0.5
local found = { handler = nil, api = nil, key = nil }
local saidPath = false

local function upvalue(fn, wanted)
	if type(fn) ~= "function" or type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
	for i = 1, 60 do
		local name, value = debug.getupvalue(fn, i)
		if name == nil then return nil end
		if name == wanted then return value end
	end
	return nil
end

local function fineStep(direction)
	if found.handler ~= handler then
		found.handler, found.api, found.key = handler, nil, nil
		local ok = pcall(function()
			local handlers = upvalue(handler, "inputActionToHandler")
			local raise = type(handlers) == "table" and handlers["constructRaise"] or nil
			found.api = upvalue(raise, "bottomBarApi")
			found.key = upvalue(raise, "paramkey")
		end)
		if not ok then found.api = nil end
		if not saidPath then
			saidPath = true
			log(found.api ~= nil and string.format("height steps of %.1f m go to the bottom bar's %q setting", FINE, tostring(found.key))
				or "the bottom bar's height setting cannot be reached - height steps are the game's own")
		end
	end
	if found.api == nil or found.key == nil then return false end
	local ok, done = pcall(function()
		local param = found.api.getParamByKey(found.key)
		if param == nil or type(param.value) ~= "number" then return false end
		local value = math.floor((param.value + direction * FINE) / FINE + 0.5) * FINE
		found.api.changeParam(param.index, value)
		return true
	end)
	return ok and done == true
end

local function poll()
	local ok, bridge = pcall(function() return tf3api end)
	if not ok or type(bridge) ~= "table" or type(bridge.take) ~= "function" then return end
	for _i = 1, 32 do
		local okTake, step = pcall(bridge.take, QUEUE)
		if not okTake or type(step) ~= "string" then return end
		if handler == nil then
			log("a height step came but no construction tool's handler is known")
		elseif fineStep(step == "1" and 1 or -1) then
			-- done: the height setting was stepped by 0.5 m directly
		else
			local action = step == "1" and "constructRaise" or "constructLower"
			-- The game's handler steps the height by 3 m, or by 0.5 m while its precision key is held
			-- (it asks api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")). A drag steps by
			-- 0.5 m: for the length of the call that question is answered "yes", then the game's own answer
			-- is put back.
			local inputAction = api and api.gui and api.gui.inputAction
			local asked = inputAction and inputAction.modifierOnlyActionIsActive
			if type(asked) == "function" then
				inputAction.modifierOnlyActionIsActive = function(name, ...)
					if name == "IA_PRECISION_MODE" then return true end
					return asked(name, ...)
				end
			end
			local okStep, why = pcall(handler, action)
			if type(asked) == "function" then inputAction.modifierOnlyActionIsActive = asked end
			if not okStep then log("the tool did not take " .. action .. ": " .. tostring(why)) end
		end
	end
end

local HeightHost = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "Tf3apiPlacementHeightHost", function()
	react.onStep(function()
		local ok, why = pcall(poll)
		if not ok then log("height polling failed: " .. tostring(why)) end
	end)
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

local M = { HeightHost = HeightHost }
function data() return M end
return M
