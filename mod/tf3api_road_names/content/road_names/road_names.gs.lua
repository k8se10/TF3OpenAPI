-- TF3OpenAPI - road names: game script registration.
-- guiUpdate does the work (reading the roads, naming them, the labels); update and handleEvent only keep the
-- names and the player's choices in the game's saved state.
function data()
	return {
		updateScript = {
			fileName = "tf3api_road_names::/road_names/road_names.script@update",
		},
		handleEventScript = {
			fileName = "tf3api_road_names::/road_names/road_names.script@handleEvent",
		},
		guiUpdateScript = {
			fileName = "tf3api_road_names::/road_names/road_names.script@guiUpdate",
		},
	}
end
