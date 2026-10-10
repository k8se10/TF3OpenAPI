-- Runs hud_fix.script@doReplace while the game sets up each UI Lua state. No recipe is replaced.
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "tf3opt_hud_fix::/gui/tf3opt/hud_fix.script",
			doReplaceFn = "doReplace",
			order = 50,
		}
	}
end
