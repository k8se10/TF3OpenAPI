-- TF3OpenAPI - departure boards: game script registration.
-- guiUpdate tells the native layer what the boards show (see boards.script.lua); guiHandleEvent notes boards
-- as the player builds them; update and handleEvent only keep the list of boards in the game's saved state.
function data()
	return {
		updateScript = {
			fileName = "tf3api_departure_boards::/tf3api_departure_boards/boards.script@update",
		},
		handleEventScript = {
			fileName = "tf3api_departure_boards::/tf3api_departure_boards/boards.script@handleEvent",
		},
		guiHandleEventScript = {
			fileName = "tf3api_departure_boards::/tf3api_departure_boards/boards.script@guiHandleEvent",
		},
		guiUpdateScript = {
			fileName = "tf3api_departure_boards::/tf3api_departure_boards/boards.script@guiUpdate",
		},
	}
end
