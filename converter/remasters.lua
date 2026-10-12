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
				id = "destination",
				note = "the painted destination replaced by a live one",
				textures = {
					["models/vehicle/train/p86_indoor_a.dds"] = { { rect = { 1792, 1804, 1948, 1852 }, from = { 1740, 1828 } } },
				},
				models = {
					["vehicle/train/p86_dlr.mdl"] = {
						labels = {
							{
								type = "NEXT_STOP", alignment = "CENTER", verticalAlignment = "CENTER", fitting = "SCALE", filter = "NONE",
								alphaMode = "BLEND", renderMode = "STD", alpha = 1, nLines = 1, childId = "", params = {},
								color = { 1, 1, 1 },
								size = { 4.5, 0.8 },   -- 0.9 m by 0.16 m, drawn five times as fine
								-- the end at +x: text runs along +y, up the blind, facing forward and a little up
								transf = { 0, 0.2, 0, 0, -0.04876, 0, 0.19396, 0, 0.19396, 0, 0.04876, 0, 13.293, -0.45, 3.093, 1 },
							},
							{
								type = "NEXT_STOP", alignment = "CENTER", verticalAlignment = "CENTER", fitting = "SCALE", filter = "NONE",
								alphaMode = "BLEND", renderMode = "STD", alpha = 1, nLines = 1, childId = "", params = {},
								color = { 1, 1, 1 },
								size = { 4.5, 0.8 },
								-- the end at -x
								transf = { 0, -0.2, 0, 0, 0.04876, 0, 0.19396, 0, -0.19396, 0, 0.04876, 0, -13.293, 0.45, 3.093, 1 },
							},
						},
					},
				},
			},
		},
	},
}
