-- The departure boards' constructions: one model, standing where it is placed.
-- captureParams: what the construction file gives (the style); params: the player's choices (the casing
-- colour, counted from 1) and, for a board the boards' script rebuilt, the screen it uses.
function data()
	return {
		updateFn = function(captureParams, params)
			local style = type(captureParams) == "table" and captureParams.style or "board_modern_pole"
			if style ~= "board_modern_pole" and style ~= "board_heritage_pole" and style ~= "board_hanging" then style = "board_modern_pole" end
			local casing = math.floor(tonumber(type(params) == "table" and params.tf3api_casing or 1) or 1)
			if casing < 1 or casing > 7 then casing = 1 end
			local screen = math.floor(tonumber(type(params) == "table" and params.screen or 0) or 0)
			local file
			if style == "board_modern_pole" and casing == 1 and screen >= 1 and screen <= 32 then
				file = string.format("tf3api_departure_boards::/tf3api_departure_boards/board_modern_pole_%02d.mdl", screen - 1)
			else
				file = string.format("tf3api_departure_boards::/tf3api_departure_boards/%s_c%d.mdl", style, casing - 1)
			end
			local transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
			local track = type(captureParams) == "table" and captureParams.track == true
			if track then
				-- A board placed at the track is an object on the track, as the game's signals are: its model is
				-- given relative to the track and moved onto the platform beside it, 3.7 metres across
				-- (the side chosen, counted from 1: left, right) and as high as chosen (counted from 1, in steps of
				-- a quarter metre from -1 m).
				local side = math.floor(tonumber(type(params) == "table" and params.tf3api_side or 1) or 1)
				local step = math.floor(tonumber(type(params) == "table" and params.tf3api_height or 0) or 0)
				transf[14] = side == 2 and -3.7 or 3.7
				transf[15] = (step >= 1 and step <= 29) and (-1 + 0.25 * (step - 1)) or 1.25
				return { edgeModels = { { model = { id = file, transf = transf } } }, cost = 0, maintenanceCost = 0 }
			end
			return {
				subconstructions = { {
					models = { { id = file, transf = transf } },
					terrainAlignmentLists = { { type = "EQUAL", faces = { } } },
				} },
			}
		end,
	}
end
