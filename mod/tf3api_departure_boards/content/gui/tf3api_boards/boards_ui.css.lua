-- Styles for the departure board window (boards_ui.script.lua).
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)
	local function fixed(w, h) return { minSize = { w, h }, maxSize = { w, h } } end
	a("!tf3api-board-window", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
		minSize = { 560, -1 },
	})
	a("!tf3api-board-content", {
		outerSpacing = { 14, 12 },
		innerSpacing = { 14, 10 },
	})
	a("!tf3api-board-row", {
		innerSpacing = { 8, 0 },
	})
	a("!tf3api-board-label", {
		minSize = { 120, -1 },
	})
	a("!tf3api-board-platforms", {
		innerSpacing = { 6, 6 },
	})
	-- the station plan: the picture the native layer paints into, and what is laid over it
	a("!tf3api-plan-left", {
		innerSpacing = { 0, 8 },
	})
	a("!tf3api-plan-controls", {
		innerSpacing = { 6, 0 },
	})
	a("!tf3api-plan-control", {
		minSize = { 34, 28 },
	})
	a("!tf3api-plan-control-wide", {
		minSize = { 130, 28 },
	})
	a("!tf3api-plan-area", fixed(960, 600))
	a("!tf3api-plan-picture", fixed(960, 600))
	a("!tf3api-plan-marker", fixed(28, 28))
	a("!tf3api-plan-marker-icon", fixed(28, 28))
	-- a platform's tag on the map: a small label "P1", "P2" ... (amber when the board serves the platform)
	a("!tf3api-plan-tag", {
		minSize = { 30, 18 },
		maxSize = { 30, 18 },
		innerSpacing = { 0, 0 },
		outerSpacing = { 0, 0 },
		textAlignment = { 0.5, 0.5 },
		fontSize = 13,
	})
	a("!tf3api-plan-tag-on", { backgroundColor = { 0.86, 0.62, 0.12, 0.95 }, color = { 0.08, 0.08, 0.1, 1 } })
	a("!tf3api-plan-tag-off", { backgroundColor = { 0.16, 0.2, 0.28, 0.95 }, color = { 0.92, 0.94, 0.97, 1 } })
	-- the platforms the board serves, in the side panel
	a("!tf3api-plan-serve", { innerSpacing = { 4, 4 } })
	a("!tf3api-plan-serve-button", { minSize = { 40, 26 } })
	a("!tf3api-plan-serve-wide", { minSize = { 64, 26 } })
	a("!tf3api-plan-north", fixed(36, 36))
	-- the side: legend, overview, the selected board
	a("!tf3api-plan-side", {
		minSize = { 330, -1 },
		maxSize = { 330, -1 },
		innerSpacing = { 0, 6 },
	})
	a("!tf3api-plan-heading", {
		outerSpacing = { 0, 6 },
	})
	a("!tf3api-plan-legend-row", {
		innerSpacing = { 10, 0 },
	})
	a("!tf3api-plan-legend-icon", fixed(28, 28))
	a("!tf3api-plan-overview", fixed(330, 206))
	-- placing things over the plan: empty boxes of fixed size push an item to its place (boards_ui.script.lua laid)
	a("!tf3api-sp-box", { innerSpacing = { 0, 0 }, outerSpacing = { 0, 0 } })
	for n = 0, 1040, 2 do
		a("!tf3api-sp-w" .. n, { minSize = { n, 0 }, maxSize = { n, 0 }, outerSpacing = { 0, 0 } })
		if n <= 650 then a("!tf3api-sp-h" .. n, { minSize = { 0, n }, maxSize = { 0, n }, outerSpacing = { 0, 0 } }) end
	end
	-- a car's picture on the plan: its length and height in points (boards_ui.script.lua CAR_STEP, CAR_MAX,
	-- CAR_HEIGHTS)
	for w = 4, 240, 4 do
		for _i, h in ipairs({ 6, 8, 10, 12, 16, 20 }) do a(string.format("!tf3api-car-%dx%d", w, h), fixed(w, h)) end
	end
	return result
end
