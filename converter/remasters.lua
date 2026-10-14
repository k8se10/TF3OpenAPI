-- Remasters: changes to particular old mods, made while they are converted.
--
-- The converter's rules are general: they treat every old mod alike. A remaster is the opposite, on purpose: a
-- short list of changes for ONE mod that its player wants and that no general rule could know (this unit is
-- electric in real life; that painted destination should be a live one). The old mod itself is never touched and
-- nothing of it is in this file: a remaster only says what to change in the converted copy, which is made on the
-- player's own machine from the player's own copy of the mod.
--
-- A remaster applies when every file of its "match" list is in the old mod (paths in the old layout, lower case).
--   models[<model, below res/models/model/>] = {
--     engineType = "ELECTRIC",          -- every engine of the model gets this type
--     labels = { ... },                 -- text labels added to the model, in the older games' form (sizes in
--                                       -- metres; the converter's own rules then bring them to the newer form)
--   }
--   materials[<material, below res/models/material/>] = {
--     lit = { rect = { x0, y0, x1, y1 }, size = { w, h }, colour = { r, g, b }, strength = 0..1 },
--   }                                   -- that area of the material's picture glows, lit from behind, always
--   fonts[<name the labels use>] = <font that ships inside the native layer>
--                                       -- written into the converted mod (content/locale/<name> and
--                                       -- content/<name>) when the converter's LabelFont switch is on. A label's
--                                       -- "font" names it; a label marked boldCopy = true is a second copy drawn
--                                       -- a little to the side, kept only when the font is NOT used (the game's
--                                       -- own font has no bold for labels), and "font" is dropped then.
--   textures[<texture, below res/textures/>] = {
--     { rect = { x0, y0, x1, y1 }, from = { x, y } },   -- the picture inside rect (points, top left first, the
--   }                                                   -- far edges not included) is painted over with what is
--                                                       -- at "from": a painted text is covered by its background
return {
	{
		id = "dlr_p86",
		title = "Docklands Light Railway P86",
		match = { "res/models/model/vehicle/train/p86_dlr.mdl", "res/textures/models/vehicle/train/p86_indoor_a.dds" },
		parts = {
			{
				-- the real units take their power from a third rail
				id = "electric",
				note = "an electric unit instead of a diesel one",
				models = { ["vehicle/train/p86_dlr.mdl"] = { engineType = "ELECTRIC" } },
			},
			{
				-- The destination blind behind each windscreen has "Stratford" painted on it. The word is covered
				-- with the blind's own red, and a label showing the next stop is laid over the blind at each end.
				-- (The blind leans back by about 14 degrees; it is 0.37 m high and the painted word 0.83 m wide.)
				-- The text is drawn lit (EMISSIVE), as a real blind is lit from behind, so it reads in the dark too.
				id = "destination",
				note = "the painted destination replaced by a live one",
				textures = {
					["models/vehicle/train/p86_indoor_a.dds"] = { { rect = { 1792, 1804, 1948, 1852 }, from = { 1740, 1828 } } },
				},
				-- The blind is lit from behind, as on the real units: its face (the picture's area of the blind quad
				-- in the cab mesh) glows a soft red, which also lights the text laid over it.
				materials = {
					["vehicle/train/p86_dlr_indoor.mtl"] = {
						lit = { rect = { 1708, 1812, 2037, 1862 }, size = { 2048, 2048 }, colour = { 0.5, 0.035, 0.02 }, strength = 0.7 },   -- a deep red: brighter ones looked pink
					},
				},
				-- The blind's lettering: Isotherm Sans Bold (the painted word's own lettering is a bold sans too small
				-- on the picture, about 14 points high, to tell which typeface it was).
				fonts = { ["tf3api/IsothermSans-Bold.ttf"] = "IsothermSans-Bold.ttf" },
				models = {
					["vehicle/train/p86_dlr.mdl"] = {
						labels = {
							{
								type = "NEXT_STOP", alignment = "CENTER", verticalAlignment = "CENTER", fitting = "SCALE", filter = "NONE",
								alphaMode = "BLEND", renderMode = "EMISSIVE", alpha = 1, nLines = 1, childId = "", params = {},
								color = { 1, 1, 1 },
								font = "tf3api/IsothermSans-Bold.ttf",   -- Isotherm Sans Bold (see fonts)
								size = { 4.5, 0.8 },   -- 0.9 m by 0.16 m, drawn five times as fine
								-- the end at +x: text runs along +y, up the blind, facing forward and a little up
								transf = { 0, 0.2, 0, 0, -0.04876, 0, 0.19396, 0, 0.19396, 0, 0.04876, 0, 13.293, -0.45, 3.093, 1 },
							},
							{
								-- the same again, 4 mm along its line: the text drawn bold
								type = "NEXT_STOP", alignment = "CENTER", verticalAlignment = "CENTER", fitting = "SCALE", filter = "NONE",
								alphaMode = "BLEND", renderMode = "EMISSIVE", alpha = 1, nLines = 1, childId = "", params = {},
								color = { 1, 1, 1 },
								boldCopy = true,
								size = { 4.5, 0.8 },   -- 0.9 m by 0.16 m, drawn five times as fine
								-- the end at +x: text runs along +y, up the blind, facing forward and a little up
								transf = { 0, 0.2, 0, 0, -0.04876, 0, 0.19396, 0, 0.19396, 0, 0.04876, 0, 13.2930, -0.4460, 3.093, 1 },
							},
							{
								type = "NEXT_STOP", alignment = "CENTER", verticalAlignment = "CENTER", fitting = "SCALE", filter = "NONE",
								alphaMode = "BLEND", renderMode = "EMISSIVE", alpha = 1, nLines = 1, childId = "", params = {},
								color = { 1, 1, 1 },
								font = "tf3api/IsothermSans-Bold.ttf",   -- Isotherm Sans Bold (see fonts)
								size = { 4.5, 0.8 },
								-- the end at -x
								transf = { 0, -0.2, 0, 0, 0.04876, 0, 0.19396, 0, -0.19396, 0, 0.04876, 0, -13.293, 0.45, 3.093, 1 },
							},
							{
								-- the same again, 4 mm along its line: the text drawn bold
								type = "NEXT_STOP", alignment = "CENTER", verticalAlignment = "CENTER", fitting = "SCALE", filter = "NONE",
								alphaMode = "BLEND", renderMode = "EMISSIVE", alpha = 1, nLines = 1, childId = "", params = {},
								color = { 1, 1, 1 },
								boldCopy = true,
								size = { 4.5, 0.8 },
								-- the end at -x
								transf = { 0, -0.2, 0, 0, 0.04876, 0, 0.19396, 0, -0.19396, 0, 0.04876, 0, -13.2930, 0.4460, 3.093, 1 },
							},
						},
					},
				},
			},
		},
	},
}
