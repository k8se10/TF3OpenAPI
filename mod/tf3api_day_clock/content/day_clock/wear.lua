-- TF3OpenAPI - day clock: vehicle wear and age follow the calendar.
--
-- The game wears a vehicle down, and counts it towards the end of its life, by hours of play: each step a
-- vehicle's condition falls by an amount inversely proportional to its model's lifespan, whatever the
-- calendar says. With a calendar day stretched to an hour or to 24 hours, a train would be worn out within
-- days of the calendar.
--
-- So in the modes with a long day every model's lifespan is multiplied by the same factor the day was
-- stretched by. Wear and age then pass in calendar time exactly as they do in the game as shipped - a
-- vehicle that was worn after two calendar years still is - and every vehicle keeps its proportion to the
-- others, because the game's own rule scales with the lifespan.
--
-- Nothing of this is stored in a save: a lifespan is a property of the model, read when the game loads it.
-- A save keeps only each vehicle's condition and the time it was bought, and both mean the same with or
-- without this mod.

local wear = {}

-- the game's own day, in milliseconds of running time
wear.STOCK_DAY_MS = 4000
-- lifespans are whole numbers the engine keeps in 32 bits
wear.MAX_LIFESPAN = 2000000000

-- By how much lifespans are multiplied for a calendar day of `dayMs` milliseconds (nil: the game's own day).
function wear.factor(dayMs, stockDayMs)
	stockDayMs = (type(stockDayMs) == "number" and stockDayMs > 0) and stockDayMs or wear.STOCK_DAY_MS
	if type(dayMs) ~= "number" or dayMs <= stockDayMs then return 1 end
	return dayMs / stockDayMs
end

-- Applies the factor to one model (the table a "loadModel" modifier is given). Returns true when the
-- model's lifespan was changed. Models without a lifespan, or with the "no end" value, are left alone.
function wear.scaleModel(data, factor)
	if type(data) ~= "table" or type(factor) ~= "number" or factor <= 1 then return false end
	local metadata = data.metadata
	local maintenance = type(metadata) == "table" and metadata.maintenance or nil
	if type(maintenance) ~= "table" then return false end
	local lifespan = maintenance.lifespan
	if type(lifespan) ~= "number" or lifespan <= 0 then return false end
	local scaled = math.floor(lifespan * factor + 0.5)
	if scaled > wear.MAX_LIFESPAN then scaled = wear.MAX_LIFESPAN end
	maintenance.lifespan = scaled
	return true
end

return wear
