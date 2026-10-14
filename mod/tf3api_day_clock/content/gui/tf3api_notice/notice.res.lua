-- Mounts the TF3OpenAPI notice in the game bar (it draws nothing there; it opens a window when something is missing).
function data()
	return {
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "tf3api_day_clock::/gui/tf3api_notice/notice.script@Host",
			priority = 10,
		}
	}
end
