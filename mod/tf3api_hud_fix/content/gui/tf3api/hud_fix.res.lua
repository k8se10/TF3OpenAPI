-- Runs hud_fix.script@doReplace while the game sets up each UI Lua state. No recipe is replaced.
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "tf3api_hud_fix::/gui/tf3api/hud_fix.script",
			doReplaceFn = "doReplace",
			order = 50,
		}
	}
end
