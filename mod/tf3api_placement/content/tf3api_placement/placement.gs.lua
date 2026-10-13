-- TF3OpenAPI - placement in two steps: game script registration.
-- guiUpdate tells the native layer whether the game's own drag-and-confirm option is on (see placement.script.lua).
function data()
	return {
		guiUpdateScript = {
			fileName = "tf3api_placement::/tf3api_placement/placement.script@guiUpdate",
		},
	}
end
