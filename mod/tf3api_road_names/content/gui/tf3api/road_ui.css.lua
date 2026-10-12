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

	-- A layout takes its edge gap from outerSpacing and the gap between its children from innerSpacing
	-- (horizontal, vertical); padding is for components.
	a("!tf3api-road-content", {
		outerSpacing = { 18, 16 },
		innerSpacing = { 0, 18 },
	})

	-- Selectors are by class alone: the game's Component is a recipe to the stylesheet ("R::Component"), so a
	-- rule written as "Component!name" matches nothing.

	-- the row in the window's header that carries the number sign
	a("!tf3api-road-signrow", {
		outerSpacing = { 12, 9 },
		innerSpacing = { 8, 0 },
	})
	a("!tf3api-road-header", {
		gravity = { -1, -1 },
	})

	-- the road number on its sign
	a("!tf3api-sign", {
		padding = { 10, 2, 10, 2 },
		gravity = { 0, 0.5 },
	})
	a("!tf3api-sign-text", {
		fontSize = 21,
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
	a("!tf3api-sign-J", { backgroundColor = signBlack })
	a("!tf3api-sign-text-J", { color = white })
	a("!tf3api-junction-heading", { fontSize = 14 })
	a("!tf3api-sign-X", { backgroundColor = abandonedGrey })
	a("!tf3api-sign-text-X", { color = white })

	-- the street nameplate: black capitals on white with a black border, the district in red
	a("!tf3api-nameplate", {
		backgroundColor = signWhite,
		borderColor = signBlack,
		borderWidth = { 3, 3, 3, 3 },
		padding = { 24, 16, 20, 10 },
		gravity = { -1, -1 },
	})
	a("!tf3api-nameplate-layout", {
		innerSpacing = { 0, 0 },
		outerSpacing = { 0, 0 },
		gravity = { -1, -1 },
	})
	a("!tf3api-nameplate-text", {
		color = signBlack,
		fontSize = 28,
		fontWeight = "Bold",
		gravity = { 0, -1 },
	})
	-- the district: smaller, red, at the bottom right of the plate
	a("!tf3api-nameplate-district", {
		color = districtRed,
		fontSize = 17,
		fontWeight = "Bold",
		gravity = { 1, -1 },
	})

	-- the details
	a("!tf3api-road-details", {
		padding = { 4, 0, 4, 0 },
	})
	a("!tf3api-road-detail-list", {
		innerSpacing = { 0, 7 },
		outerSpacing = { 0, 0 },
	})
	a("!tf3api-road-row", {
		innerSpacing = { 12, 0 },
		outerSpacing = { 0, 0 },
	})
	a("!tf3api-road-label", {
		fontSize = 16,
		size = { 190, -1 },
		minSize = { 190, -1 },
	})
	a("!tf3api-road-value", {
		fontSize = 16,
		fontWeight = "Medium",
	})

	a("!tf3api-road-input", {
		minSize = { 220, -1 },
	})
	a("!tf3api-road-choice", {
		minSize = { 220, -1 },
	})

	-- the mod's own small window: bottom left to start with, movable
	a("!tf3api-tools-window", {
		anchorPoint = { 0, 1 },
		gravity = { 0.01, 0.82 },
	})
	a("!tf3api-tools-content", {
		outerSpacing = { 10, 8 },
	})
	a("!tf3api-tools-button", {
		minSize = { 170, 30 },
	})
	a("!tf3api-city-window", {
		anchorPoint = { 0, 1 },
		gravity = { 0.01, 0.6 },
	})
	a("!tf3api-city-hint", {
		fontSize = 14,
		margin = { 0, 0, 0, 6 },
	})
	a("!tf3api-city-button", {
		minSize = { 120, 30 },
		margin = { 0, 6, 8, 0 },
	})
	a("!tf3api-city-name", {
		minSize = { 120, -1 },
		fontSize = 14,
	})
	a("!tf3api-city-remove", {
		minSize = { 70, 24 },
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
