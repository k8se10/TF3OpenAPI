-- Mounts the departure boards' interface host in the game bar. It draws nothing there; it watches for clicks
-- on boards (reported by the native layer) and opens the board's window.
function data()
	return {
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "tf3api_departure_boards::/gui/tf3api_boards/boards_ui.script@BoardsHost",
			priority = 51,
		}
	}
end
