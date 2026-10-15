-- TF3OpenAPI save guard: game script registration. update keeps the street types and the native layer on the side
-- the save keeps to (see guard.script.lua).
function data()
	return {
		updateScript = {
			fileName = "tf3api_save_guard::/save_guard/guard.script@update",
		},
	}
end
