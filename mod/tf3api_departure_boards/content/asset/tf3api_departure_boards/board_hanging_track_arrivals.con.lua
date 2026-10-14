function data()
return {
	autoRemovable = false,
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
	description = {
		description = "Place it on a platform track: it lines up with the track and stands on the platform beside it. It joins the station and shows the platform it stands at by itself. TF3OpenAPI.",
		name = "Arrivals board (hanging, under a canopy), at the track",
	},
	edgeObject = {
		snapToTrack = true,
	},
	menuCategory = {
		categories = {
			{
				category = "rail_tools",
				filterCategories = { },
				order = 9106,
			},
		},
	},
	order = 9106,
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
		{
			defaultIndex = 1,
			key = "tf3api_side",
			name = "Platform side",
			uiType = "Button",
			values = {
				"Left",
				"Right",
			},
		},
		{
			defaultIndex = 10,
			key = "tf3api_height",
			name = "Height above the track",
			uiType = "Slider",
			values = {
				"-1.00 m",
				"-0.75 m",
				"-0.50 m",
				"-0.25 m",
				"0.00 m",
				"0.25 m",
				"0.50 m",
				"0.75 m",
				"1.00 m",
				"1.25 m",
				"1.50 m",
				"1.75 m",
				"2.00 m",
				"2.25 m",
				"2.50 m",
				"2.75 m",
				"3.00 m",
				"3.25 m",
				"3.50 m",
				"3.75 m",
				"4.00 m",
				"4.25 m",
				"4.50 m",
				"4.75 m",
				"5.00 m",
				"5.25 m",
				"5.50 m",
				"5.75 m",
				"6.00 m",
			},
		},
	},
	skipCollision = true,
	updateScript = {
		fileName = "tf3api_departure_boards::/asset/tf3api_departure_boards/board_modern_pole.con.script@updateFn",
		params = {
			style = "board_hanging",
			track = true,
		},
	},
}
end
