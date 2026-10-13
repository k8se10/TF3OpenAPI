-- TF3OpenAPI - departure boards: the rules, free of the game (tested by tools/tests/boards_test.lua).
--
-- A board has a screen number. Boards with the same number show the same thing: the departures of one
-- station - the station nearest to the first board placed with that number.

local core = {}

core.SLOTS = 32          -- screen numbers 0 .. 31 (the game shows them as 1 .. 32)
core.REACH = 600         -- metres: a board belongs to the nearest station within this distance
core.ROWS = 3            -- departures on a screen
core.DUE = 60            -- seconds: a departure nearer than this is shown as "Due"
core.DWELL = 25          -- seconds a vehicle is taken to stand at a stop on its way
core.MAX_AHEAD = 4 * 3600   -- seconds: departures further off than this are not shown
core.NAME_LENGTH = 30    -- characters of a destination (the native layer cuts what does not fit)

-- Which station each screen number shows.
--   boards   = { { id = entity, slot = 0.., x =, y = }, ... }
--   stations = { { id = station group, name =, x =, y = }, ... }
-- Returns { [slot] = station }: for each number the board with the lowest id decides, and takes the nearest
-- station within core.REACH; a number whose board stands near no station is absent.
function core.assign(boards, stations)
	local first = {}
	for _, board in ipairs(boards) do
		local slot = board.slot
		if type(slot) == "number" and slot >= 0 and slot < core.SLOTS and (first[slot] == nil or board.id < first[slot].id) then
			first[slot] = board
		end
	end
	local out = {}
	for slot, board in pairs(first) do
		local best, bestD
		for _, station in ipairs(stations) do
			local d = (station.x - board.x) ^ 2 + (station.y - board.y) ^ 2
			if d <= core.REACH * core.REACH and (bestD == nil or d < bestD or (d == bestD and station.id < best.id)) then
				best, bestD = station, d
			end
		end
		out[slot] = best
	end
	return out
end

-- Seconds until a vehicle stands at stop `target` of its line, or nil when that cannot be told.
--   n        = number of stops of the line (stops are numbered 1 .. n, and after n comes 1)
--   sections = { seconds from stop i to the next one }, as the vehicle last took them (0 or nil: not known)
--   vehicle  = { stop = the stop it stands at or is going to, atStop = true when it stands there,
--                since = seconds since it left the stop before (nil: not known) }
function core.eta(n, sections, vehicle, target)
	if type(n) ~= "number" or n < 2 or type(vehicle) ~= "table" then return nil end
	local stop = vehicle.stop
	if type(stop) ~= "number" or stop < 1 or stop > n or target < 1 or target > n then return nil end
	local total = 0
	if not vehicle.atStop then
		local before = stop == 1 and n or stop - 1
		local section = sections[before]
		if type(section) ~= "number" or section <= 0 then return nil end
		local since = type(vehicle.since) == "number" and vehicle.since or 0
		total = math.max(0, section - math.max(0, since))
	end
	local at = stop
	local steps = 0
	while at ~= target do
		local section = sections[at]
		if type(section) ~= "number" or section <= 0 then return nil end
		total = total + core.DWELL + section
		at = at == n and 1 or at + 1
		steps = steps + 1
		if steps > n then return nil end
	end
	return total
end

-- Where a vehicle leaving stop `stop` is bound for, as passengers would say it: the stop half-way round
-- the line (for a line there and back, the far end); never the station itself when another name exists.
--   names = { name of each stop's station, 1 .. n }
function core.destination(names, stop, here)
	local n = #names
	if n == 0 then return "" end
	local at = ((stop - 1 + math.floor(n / 2)) % n) + 1
	for _ = 1, n do
		if names[at] ~= nil and names[at] ~= "" and names[at] ~= here then return names[at] end
		at = at == n and 1 or at + 1
	end
	return names[at] or ""
end

local function hhmm(seconds)
	seconds = math.floor(seconds) % 86400
	return string.format("%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

-- only what the boards' lettering has; a tab would break the layout of a line
local function plain(text, length)
	text = tostring(text or ""):gsub("[%c]", " ")
	text = text:gsub("[\128-\255]+", "?")
	if #text > length then text = text:sub(1, length) end
	return text
end

-- The three lines of a screen.
--   clock      = the boards' clock now, in seconds of the day
--   station    = { name = } (nil: the board stands at no station - returns nil, the screen is left alone)
--   departures = { { eta = seconds, destination =, platform = }, ... } in any order
--   served     = whether any line calls at the station
-- A departure line is "time <tab> destination <tab> platform <tab> expected".
function core.lines(clock, station, departures, served)
	if station == nil then return nil end
	local rows = {}
	for _, d in ipairs(departures or {}) do
		if type(d.eta) == "number" and d.eta >= 0 and d.eta <= core.MAX_AHEAD then rows[#rows + 1] = d end
	end
	table.sort(rows, function(a, b)
		if a.eta ~= b.eta then return a.eta < b.eta end
		if a.destination ~= b.destination then return tostring(a.destination) < tostring(b.destination) end
		return tostring(a.platform) < tostring(b.platform)
	end)
	if #rows == 0 then
		-- nothing due: a welcome where trains call at all, a dark screen where none do
		if served then return { "", "Welcome To " .. plain(station.name, 40), "" } end
		return { "", "", "" }
	end
	local out = {}
	for i = 1, core.ROWS do
		local d = rows[i]
		if d == nil then
			out[i] = ""
		else
			local expected = d.eta < core.DUE and "Due" or (math.floor(d.eta / 60 + 0.5) .. " min")
			out[i] = table.concat({ hhmm((clock or 0) + d.eta), plain(d.destination, core.NAME_LENGTH), plain(d.platform, 3), expected }, "\t")
		end
	end
	return out
end

return core
