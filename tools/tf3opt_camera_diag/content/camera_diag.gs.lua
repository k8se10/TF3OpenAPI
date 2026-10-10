-- TF3 Optimizations: camera diagnostic (development only, never published).
-- Registers a GUI-side per-frame script that logs camera data while following a vehicle.
function data()
	return {
		guiUpdateScript = {
			fileName = "camera_diag.script@guiUpdate",
		},
	}
end
