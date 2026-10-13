-- The departure board's construction: one model, standing where it is placed.
function data()
	return {
		updateFn = function(captureParams, params)
			-- the screen number, counted from 1 as the game hands a chosen value over; anything else is screen 1
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
