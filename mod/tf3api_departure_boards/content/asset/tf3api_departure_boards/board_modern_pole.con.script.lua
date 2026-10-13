-- The departure board's construction: one model, standing where it is placed.
function data()
	return {
		updateFn = function(captureParams, params)
			-- the screen this board uses, counted from 1; set by the boards' script when the board joins a station
			-- (never by the player). A board that has joined nothing has none and is built with the first.
			local screen = math.floor(tonumber(type(params) == "table" and params.screen or 1) or 1)
			if screen < 1 or screen > 32 then screen = 1 end
			return {
				subconstructions = { {
					models = { {
						id = string.format("tf3api_departure_boards::/tf3api_departure_boards/board_modern_pole_%02d.mdl", screen - 1),
						transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
					} },
					terrainAlignmentLists = { { type = "EQUAL", faces = { } } },
				} },
			}
		end,
	}
end
