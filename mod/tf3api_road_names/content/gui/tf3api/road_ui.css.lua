-- Styles for the road window (road_ui.script.lua).
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	-- the window opens in the middle of the screen, at a readable size
	a("!tf3api-road-window", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
		minSize = { 440, -1 },
	})

	a("!tf3api-road-content", {
		padding = { 18, 16, 18, 18 },
	})

	-- the road's number and name at the top
	a("!tf3api-road-heading", {
		fontSize = 26,
		margin = { 0, 0, 0, 14 },
	})

	a("!tf3api-road-row", {
		margin = { 0, 3, 0, 3 },
	})

	a("!tf3api-road-label", {
		fontSize = 17,
		size = { 150, -1 },
		minSize = { 150, -1 },
	})

	a("!tf3api-road-value", {
		fontSize = 17,
	})

	a("!tf3api-road-note", {
		fontSize = 14,
		margin = { 0, 10, 0, 0 },
	})

	return result
end
