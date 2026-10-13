-- TF3OpenAPI - departure boards: game script registration.
-- guiUpdate tells the native layer what the boards show (see boards.script.lua).
function data()
	return {
		guiUpdateScript = {
			fileName = "tf3api_departure_boards::/tf3api_departure_boards/boards.script@guiUpdate",
		},
	}
end
