-- The departure board's construction: one model, standing where it is placed.
function data()
	return {
		updateFn = function(captureParams, params)
			return {
				subconstructions = { {
					models = { {
						id = "tf3api_departure_boards::/tf3api_departure_boards/board_modern_pole.mdl",
						transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
					} },
					terrainAlignmentLists = { { type = "EQUAL", faces = { } } },
				} },
			}
		end,
	}
end
