function data()
return {
	autoRemovable = false,
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
	constructionType = "ASSET_TRACK",
	description = {
		description = "Place it on a platform track: it lines up with the track and stands on the platform beside it. It joins the station and shows the platform it stands at by itself. TF3OpenAPI.",
		name = "Departures board (heritage, on a post), at the track",
	},
	menuCategory = {
		categories = {
			{
				category = "rail_assets",
				filterCategories = { },
				order = 9103,
			},
		},
	},
	order = 9103,
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
	},
	skipCollision = true,
	snapping = {
		rail = true,
		road = false,
		water = false,
	},
	updateScript = {
		fileName = "tf3api_departure_boards::/asset/tf3api_departure_boards/board_modern_pole.con.script@updateFn",
		params = {
			style = "board_heritage_pole",
			track = true,
		},
	},
}
end
