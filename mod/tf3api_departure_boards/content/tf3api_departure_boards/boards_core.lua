-- TF3OpenAPI - departure boards: the rules, free of the game (tested by tools/tests/boards_test.lua).
--
-- A board is placed near a station and joins it by itself; from then on it is that station's board. What it
-- shows - the station's departures or its arrivals - is the kind of board. How this was done in the older
-- game, which ours follows, is written up in re_notes/boards/reference_tf2_displays.md.
--
-- Behind the scenes every different content needs a screen texture of its own, of which the mod has
-- core.SLOTS. Boards that show the same thing share one. Which screen a board has is our bookkeeping
-- (core.allocate); the player never sees a number.

local core = {}

core.SLOTS = 32
core.JOIN_REACH = 100    -- metres from a station (from its outline, where that is known) within which a board joins it
core.ROWS = 3            -- vehicles on a station's board
core.DUE = 60            -- seconds: nearer than this is "Due"
core.DWELL = 25          -- seconds a vehicle is taken to stand at a stop on its way
core.MAX_AHEAD = 4 * 3600
core.CYCLE = 8          -- seconds each platform is shown when a board shows several in turn
-- The plan view: how wide the live picture sees, as the tangent of half its angle up-and-down and
-- side-to-side (not yet measured in the game: these are the usual 45 degrees on a 16 : 9 picture), and how
-- much room is left round the station.
core.PLAN_TAN_V = 0.4142
core.PLAN_TAN_H = 0.7364
core.PLAN_MARGIN = 1.12
core.PLAN_DEFAULT = 240  -- metres taken for a station whose outline is not known
core.CLOCK = "\1"        -- stands for the running clock in a row (the native layer puts the time there)

core.DEPARTURES, core.ARRIVALS = "departures", "arrivals"

-- ---- joining a station ------------------------------------------------------------------------------------

-- How far a spot is from a station: from its outline when that is known (x0, y0, x1, y1), else from its
-- middle.
local function distance(station, x, y)
	if station.x0 ~= nil then
		local dx = math.max(station.x0 - x, 0, x - station.x1)
		local dy = math.max(station.y0 - y, 0, y - station.y1)
		return math.sqrt(dx * dx + dy * dy)
	end
	return math.sqrt((station.x - x) ^ 2 + (station.y - y) ^ 2)
end

-- The stations a board at (x, y) can join, nearest first: { { station =, distance = }, ... }.
--   stations = { { id = station group, name =, x =, y =, [x0, y0, x1, y1] }, ... }
function core.nearby(x, y, stations)
	local out = {}
	for _, station in ipairs(stations) do
		local d = distance(station, x, y)
		if d <= core.JOIN_REACH then out[#out + 1] = { station = station, distance = d } end
	end
	table.sort(out, function(a, b)
		if a.distance ~= b.distance then return a.distance < b.distance end
		return a.station.id < b.station.id
	end)
	return out
end

-- How high the plan view's camera has to stand for a whole station to be in the picture, and the station's
-- size along and across its platforms.
--   dx, dy = the station's outline as the game gives it (a box square to the map), nil when not known
--   upX, upY = the direction across the platforms (it points up the picture), so platforms run side to side
-- A long station needs height for its length, a wide one (many platforms) for its width: the larger counts.
function core.planHeight(dx, dy, upX, upY)
	local along, across
	if type(dx) ~= "number" or type(dy) ~= "number" or dx <= 0 or dy <= 0 then
		along, across = core.PLAN_DEFAULT, core.PLAN_DEFAULT / 2
	else
		-- the box square to the map of a station turned by some angle is larger than the station: undo that
		local length = math.sqrt((upX or 0) ^ 2 + (upY or 0) ^ 2)
		local c, s = 1, 0
		if length > 1e-6 then c, s = math.abs(upY / length), math.abs(upX / length) end   -- along = up turned a quarter
		local d = c * c - s * s
		if math.abs(d) > 0.25 then
			along, across = (dx * c - dy * s) / d, (dy * c - dx * s) / d
		end
		if along == nil or along <= 0 or across == nil or across <= 0 then
			along, across = math.max(dx, dy), math.max(dx, dy)   -- near a diagonal: take the safe figure
		end
	end
	local height = math.max(along / (2 * core.PLAN_TAN_H), across / (2 * core.PLAN_TAN_V)) * core.PLAN_MARGIN
	return math.max(height, 30), along, across
end

-- ---- which screen a board has ---------------------------------------------------------------------------

-- What a board shows, as one key: the station, departures or arrivals, the platforms it serves (none: all)
-- and how it shows several. Boards with the same key share a screen.
function core.contentKey(station, kind, platforms, mode)
	return tostring(station) .. "|" .. tostring(kind) .. "|" .. tostring(platforms or "") .. "|" .. tostring(mode or "merged")
end

-- "1,3" -> { [1] = true, [3] = true }, and the numbers in order; nil when no platform is chosen
function core.platformSet(text)
	local set, list = {}, {}
	for n in tostring(text or ""):gmatch("%d+") do
		local v = tonumber(n)
		if v ~= nil and v >= 1 and v <= 99 and not set[v] then set[v], list[#list + 1] = true, v end
	end
	table.sort(list)
	if #list == 0 then return nil, list end
	return set, list
end

-- Gives every joined board a screen.
--   boards = { { id =, station = station group it has joined (nil: none), kind =, slot = the screen it was
--                built with (nil: none) }, ... }
-- Returns
--   change  = { [board id] = slot } for the boards that have to be rebuilt with another screen,
--   content = { [slot] = { station =, kind = } } what each screen in use shows,
--   full    = { board id, ... } boards for which no screen is left.
-- Boards showing the same thing share a screen; a board keeps the screen it has wherever that is possible,
-- so that a rebuild happens once, when a board joins. Screen 0 is never given out: it is what a board that
-- has joined nothing is built with, and shows the "not connected" lines.
function core.allocate(boards)
	local sorted = {}
	for _, b in ipairs(boards) do
		if b.station ~= nil then sorted[#sorted + 1] = b end
	end
	table.sort(sorted, function(a, b) return a.id < b.id end)
	local slotOfKey, keyOfSlot = {}, {}
	-- first the screens already in use keep what they show (the oldest board of a screen decides)
	for _, b in ipairs(sorted) do
		local key = core.contentKey(b.station, b.kind, b.platforms, b.mode)
		local slot = b.slot
		if type(slot) == "number" and slot >= 1 and slot < core.SLOTS and slotOfKey[key] == nil and keyOfSlot[slot] == nil then
			slotOfKey[key], keyOfSlot[slot] = slot, key
		end
	end
	local change, full, content = {}, {}, {}
	for _, b in ipairs(sorted) do
		local key = core.contentKey(b.station, b.kind, b.platforms, b.mode)
		local slot = slotOfKey[key]
		if slot == nil then
			for s = 1, core.SLOTS - 1 do
				if keyOfSlot[s] == nil then
					slot = s
					break
				end
			end
			if slot ~= nil then slotOfKey[key], keyOfSlot[slot] = slot, key end
		end
		if slot == nil then
			full[#full + 1] = b.id
		else
			content[slot] = { station = b.station, kind = b.kind, platforms = b.platforms, mode = b.mode }
			if b.slot ~= slot then change[b.id] = slot end
		end
	end
	return change, content, full
end

-- ---- what a line is called -------------------------------------------------------------------------------

-- A line's name as a board shows it: what stands in brackets, if anything does ("(IC 335) London - Rosenheim"
-- is "IC 335"; several bracketed parts are joined by a space; empty brackets: no name); otherwise the name.
function core.lineLabel(name)
	name = tostring(name or "")
	local parts, any = {}, false
	for inside in name:gmatch("%((.-)%)") do
		any = true
		if inside ~= "" then parts[#parts + 1] = inside end
	end
	if any then return table.concat(parts, " ") end
	return name
end

-- ---- when a vehicle is where ----------------------------------------------------------------------------

-- The time from each stop to the next, averaged over the line's vehicles (a vehicle that has not driven a
-- section yet says 0 for it). sections = { { seconds from stop 1, from stop 2, ... }, one list per vehicle }.
function core.averages(n, sections)
	local out = {}
	for i = 1, n do
		local sum, count = 0, 0
		for _, list in ipairs(sections) do
			local seconds = list[i]
			if type(seconds) == "number" and seconds > 0 then sum, count = sum + seconds, count + 1 end
		end
		out[i] = count > 0 and sum / count or 0
	end
	return out
end

-- Seconds until a vehicle stands at stop `target` of its line, or nil when that cannot be told.
--   n        = number of stops of the line (numbered 1 .. n; after n comes 1)
--   sections = { seconds from stop i to the next one } (0 or nil: not known)
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
	local at, steps = stop, 0
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

-- Where a vehicle at stop `stop` is bound for, as passengers would say it: the stop half-way round the line
-- (for a line there and back, the far end); never the station itself when another name exists.
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

-- Where it comes from: the stop half-way round the line behind it.
function core.origin(names, stop, here)
	local n = #names
	if n == 0 then return "" end
	local at = ((stop - 1 - math.floor(n / 2)) % n) + 1
	for _ = 1, n do
		if names[at] ~= nil and names[at] ~= "" and names[at] ~= here then return names[at] end
		at = at == 1 and n or at - 1
	end
	return names[at] or ""
end

-- ---- the rows of a screen ---------------------------------------------------------------------------------

local function hhmm(seconds)
	seconds = math.floor(seconds) % 86400
	return string.format("%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

-- only what the boards' lettering has; a tab or the clock's code would break the layout of a row
local function plain(text, length)
	text = tostring(text or ""):gsub("[%c]", " ")
	text = text:gsub("[\128-\255]+", "?")
	if #text > length then text = text:sub(1, length) end
	return text
end

-- where the parts of a row stand (columns of dots; see the native layer's row layout)
local PLACE, LINE, PLATFORM, TIME = "<2 ", "<124 ", ">204 ", ">238 "

-- The five rows of a station's board.
--   kind     = core.DEPARTURES or core.ARRIVALS
--   clock    = the boards' clock now, in seconds of the day
--   station  = { name = }
--   vehicles = { { eta = seconds until it leaves (departures) or arrives (arrivals), place = destination or
--                  origin, line = the line's name, platform = }, ... } in any order
-- Heading with the clock; three vehicles - place, line, platform, time ("Due" when it is about to); the
-- station's name. "Sorry no service" when nothing is known.
function core.rows(kind, clock, station, vehicles)
	local list = {}
	for _, v in ipairs(vehicles or {}) do
		if type(v.eta) == "number" and v.eta >= 0 and v.eta <= core.MAX_AHEAD then list[#list + 1] = v end
	end
	table.sort(list, function(a, b)
		if a.eta ~= b.eta then return a.eta < b.eta end
		if a.place ~= b.place then return tostring(a.place) < tostring(b.place) end
		return tostring(a.platform) < tostring(b.platform)
	end)
	local rows = { PLACE .. (kind == core.ARRIVALS and "ARRIVALS" or "DEPARTURES") .. "\t" .. TIME .. core.CLOCK }
	if #list == 0 then
		rows[2] = PLACE .. "Sorry no service\t" .. TIME .. "--:--"
		rows[3], rows[4] = "", ""
	else
		for i = 1, core.ROWS do
			local v = list[i]
			if v == nil then
				rows[i + 1] = ""
			else
				local time = v.eta < core.DUE and "Due" or hhmm((clock or 0) + v.eta)
				rows[i + 1] = PLACE .. plain(v.place, 40) .. "\t" .. LINE .. plain(core.lineLabel(v.line), 20) .. "\t"
					.. PLATFORM .. plain(v.platform, 3) .. "\t" .. TIME .. time
			end
		end
	end
	rows[5] = plain(station ~= nil and station.name or "", 44)
	return rows
end

return core
