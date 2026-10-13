function data()
return {
	autoRemovable = false,
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
	constructionType = "ASSET_DEFAULT",
	description = {
		description = "A dot-matrix departure board. TF3OpenAPI.",
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
	params = { },
	skipCollision = true,
	updateScript = {
		fileName = "tf3api_departure_boards::/asset/tf3api_departure_boards/board_modern_pole.con.script@updateFn",
		params = {
		},
	},
}
end
