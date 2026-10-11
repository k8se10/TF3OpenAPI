-- Mounts the road-names UI host in the game bar. The host draws nothing there; it is the always-present
-- component that watches for clicks on road labels and opens the road window.
function data()
	return {
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "tf3api_road_names::/gui/tf3api/road_ui.script@RoadNamesHost",
			priority = 50,
		}
	}
end
