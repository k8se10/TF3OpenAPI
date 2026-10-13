function data()
return {
	autoRemovable = false,
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
	description = {
		description = "A dot-matrix board showing the vehicles leaving a station. Place it within 100 m of the station: it joins it by itself and stays the board of that station. TF3OpenAPI.",
		name = "Departures board for a station",
	},
	menuCategory = {
		categories = {
			{
				category = "rail_buildings",
				filterCategories = { },
				order = 9000,
			},
		},
	},
	order = 9000,
	params = { },
	skipCollision = true,
	updateScript = {
		fileName = "tf3api_departure_boards::/asset/tf3api_departure_boards/board_modern_pole.con.script@updateFn",
		params = {
		},
	},
}
end
