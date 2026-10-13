function data()
return {
	autoRemovable = false,
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
	constructionType = "ASSET_DEFAULT",
	description = {
		description = "A dot-matrix departure board. It shows the departures of the station nearest to it. Boards with the same screen number show the same thing: give each station a number of its own. TF3OpenAPI.",
		name = "Departure board (modern, on a post)",
	},
	menuCategory = {
		categories = {
			{
				category = "landscaping_assets",
				filterCategories = { },
				order = 9000,
			},
		},
	},
	order = 9000,
	params = {
		{
			defaultIndex = 1,
			displayMode = "Horizontal",
			key = "screen",
			name = "Screen number",
			tooltip = "Boards with the same number show the same station. Use a different number at each station.",
			uiType = "Slider",
			values = {
				"1",
				"2",
				"3",
				"4",
				"5",
				"6",
				"7",
				"8",
				"9",
				"10",
				"11",
				"12",
				"13",
				"14",
				"15",
				"16",
				"17",
				"18",
				"19",
				"20",
				"21",
				"22",
				"23",
				"24",
				"25",
				"26",
				"27",
				"28",
				"29",
				"30",
				"31",
				"32",
			},
		},
	},
	skipCollision = true,
	updateScript = {
		fileName = "tf3api_departure_boards::/asset/tf3api_departure_boards/board_modern_pole.con.script@updateFn",
		params = {
		},
	},
}
end
