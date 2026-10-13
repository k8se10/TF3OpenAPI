-- Mounts the placement mod's interface part in the game bar. It draws nothing; it hands the height steps of a
-- middle-button drag (from the native layer) to the construction tool in use.
function data()
	return {
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "tf3api_placement::/gui/tf3api_placement/height.script@HeightHost",
			priority = 52,
		}
	}
end
