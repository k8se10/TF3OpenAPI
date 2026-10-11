-- Styles for the road window (road_ui.script.lua). Colours are { red, green, blue, alpha }, 0 to 1.
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	-- British sign colours
	local motorwayBlue = { 0.00, 0.475, 0.757, 1 }
	local primaryGreen = { 0.00, 0.439, 0.235, 1 }
	local primaryYellow = { 1.00, 0.824, 0.00, 1 }
	local signWhite = { 0.97, 0.97, 0.95, 1 }
	local signBlack = { 0.08, 0.08, 0.08, 1 }
	local districtRed = { 0.78, 0.09, 0.11, 1 }
	local abandonedGrey = { 0.43, 0.43, 0.43, 1 }
	local white = { 1, 1, 1, 1 }

	-- the window opens in the middle of the screen, at a readable size
	a("!tf3api-road-window", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
		minSize = { 460, -1 },
	})

	a("!tf3api-road-content", {
		padding = { 20, 18, 20, 20 },
		innerSpacing = { 0, 16 },
	})

	-- Selectors are by class alone: the game's Component is a recipe to the stylesheet ("R::Component"), so a
	-- rule written as "Component!name" matches nothing.

	-- the row in the window's header that carries the number sign
	a("!tf3api-road-signrow", {
		padding = { 20, 4, 20, 0 },
	})
	a("!tf3api-road-header", {
		gravity = { -1, -1 },
	})

	-- the road number on its sign
	a("!tf3api-sign", {
		padding = { 12, 5, 12, 5 },
		gravity = { 0, 0.5 },
	})
	a("!tf3api-sign-text", {
		fontSize = 24,
		fontWeight = "Bold",
	})
	a("!tf3api-sign-M", { backgroundColor = motorwayBlue })
	a("!tf3api-sign-text-M", { color = white })
	a("!tf3api-sign-A", { backgroundColor = primaryGreen })
	a("!tf3api-sign-text-A", { color = primaryYellow })
	a("!tf3api-sign-B", {
		backgroundColor = signWhite,
		borderColor = signBlack,
		borderWidth = { 2, 2, 2, 2 },
	})
	a("!tf3api-sign-text-B", { color = signBlack })
	a("!tf3api-sign-X", { backgroundColor = abandonedGrey })
	a("!tf3api-sign-text-X", { color = white })

	-- the street nameplate: black capitals on white with a black border, the district in red
	a("!tf3api-nameplate", {
		backgroundColor = signWhite,
		borderColor = signBlack,
		borderWidth = { 3, 3, 3, 3 },
		padding = { 22, 12, 22, 8 },
		gravity = { -1, -1 },
	})
	a("!tf3api-nameplate-layout", {
		innerSpacing = { 0, 2 },
		gravity = { -1, -1 },
	})
	a("!tf3api-nameplate-text", {
		color = signBlack,
		fontSize = 30,
		fontWeight = "Bold",
		gravity = { 0, -1 },
	})
	-- the district: smaller, red, at the bottom right of the plate
	a("!tf3api-nameplate-district", {
		color = districtRed,
		fontSize = 18,
		fontWeight = "Bold",
		gravity = { 1, -1 },
	})

	-- the details
	a("!tf3api-road-details", {
		padding = { 2, 0, 2, 0 },
	})
	a("!tf3api-road-row", {
		margin = { 0, 4, 0, 4 },
	})
	a("!tf3api-road-label", {
		fontSize = 16,
		size = { 170, -1 },
		minSize = { 170, -1 },
	})
	a("!tf3api-road-value", {
		fontSize = 16,
		fontWeight = "Medium",
	})

	a("!tf3api-road-option", {
		margin = { 0, 4, 0, 0 },
	})
	a("!tf3api-road-note", {
		fontSize = 14,
		margin = { 0, 4, 0, 0 },
	})

	return result
end
