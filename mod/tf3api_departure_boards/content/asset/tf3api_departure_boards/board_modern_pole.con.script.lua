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
			-- the screen: chosen while placing (tf3api_screen), or by a rebuild (screen); counted from 1
			local screen = math.floor(tonumber(type(params) == "table" and (params.tf3api_screen or params.screen) or 0) or 0)
			if screen < 1 or screen > 32 then screen = 1 end
			local file = string.format("tf3api_departure_boards::/tf3api_departure_boards/%s_c%d_%02d.mdl", style, casing - 1, screen - 1)
			local transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
			return {
				subconstructions = { {
					models = { { id = file, transf = transf } },
					terrainAlignmentLists = { { type = "EQUAL", faces = { } } },
				} },
			}
		end,
	}
end
