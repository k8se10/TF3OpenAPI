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

local function poll()
	local ok, bridge = pcall(function() return tf3api end)
	if not ok or type(bridge) ~= "table" or type(bridge.take) ~= "function" then return end
	for _i = 1, 32 do
		local okTake, step = pcall(bridge.take, QUEUE)
		if not okTake or type(step) ~= "string" then return end
		if handler == nil then
			log("a height step came but no construction tool's handler is known")
		else
			local action = step == "1" and "constructRaise" or "constructLower"
			local okStep, why = pcall(handler, action)
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
