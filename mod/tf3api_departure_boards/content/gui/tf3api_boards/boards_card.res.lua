-- Adds the departure board's settings to the game's own window of a construction (only boards show them).
function data()
	return {
		type = "react-plugin ::EmptyConstructionEowExtensionPoint",
		data = {
			filePath = "tf3api_departure_boards::/gui/tf3api_boards/boards_ui.script@BoardCard",
			order = 10,
		}
	}
end
