-- Styles for the departure board window (boards_ui.script.lua).
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)
	a("!tf3api-board-window", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
		minSize = { 560, -1 },
	})
	a("!tf3api-board-content", {
		outerSpacing = { 14, 12 },
		innerSpacing = { 0, 10 },
	})
	-- the live picture of the station from above
	a("!tf3api-board-view", {
		minSize = { 532, 300 },
		maxSize = { 532, 300 },
	})
	a("!tf3api-board-row", {
		innerSpacing = { 8, 0 },
	})
	a("!tf3api-board-label", {
		minSize = { 130, -1 },
	})
	a("!tf3api-board-platforms", {
		innerSpacing = { 6, 6 },
	})
	return result
end
