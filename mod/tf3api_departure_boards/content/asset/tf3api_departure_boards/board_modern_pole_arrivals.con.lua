function data()
return {
	autoRemovable = false,
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
	description = {
		description = "A dot-matrix board showing the vehicles approaching a station. Place it within 100 m of the station: it joins it by itself. Click it for its settings. TF3OpenAPI.",
		name = "Arrivals board (modern, on a post)",
	},
	menuCategory = {
		categories = {
			{
				category = "rail_buildings",
				filterCategories = { },
				order = 9001,
			},
		},
	},
	order = 9001,
	params = {
		{
			defaultIndex = 1,
			key = "tf3api_casing",
			name = "Casing colour",
			uiType = "ComboBox",
			values = {
				"As designed",
				"Black",
				"Network blue",
				"Dark grey",
				"Silver",
				"Green",
				"Maroon",
			},
		},
	},
	skipCollision = true,
	updateScript = {
		fileName = "tf3api_departure_boards::/asset/tf3api_departure_boards/board_modern_pole.con.script@updateFn",
		params = {
			style = "board_modern_pole",
		},
	},
}
end
