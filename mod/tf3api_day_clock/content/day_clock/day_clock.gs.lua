-- TF3OpenAPI - day clock: game script registration.
-- update keeps the length of the game day and moves the sky with the clock (see day_clock.script.lua).
function data()
	return {
		updateScript = {
			fileName = "tf3api_day_clock::/day_clock/day_clock.script@update",
		},
	}
end
