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
function core.contentKey(station, kind, platforms, mode, layout)
	return tostring(station) .. "|" .. tostring(kind) .. "|" .. tostring(platforms or "") .. "|" .. tostring(mode or "merged")
		.. "|" .. tostring(layout or core.LAYOUT_DEFAULT)
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
	-- boards whose screen cannot be changed (the game put them into an asset group: their model is their
	-- screen) come first, whatever screen that is
	for _, b in ipairs(sorted) do
		if b.fixed and type(b.slot) == "number" and b.slot >= 0 and b.slot < core.SLOTS then
			local key = core.contentKey(b.station, b.kind, b.platforms, b.mode, b.layout)
			if keyOfSlot[b.slot] == nil then slotOfKey[key], keyOfSlot[b.slot] = slotOfKey[key] or b.slot, key end
		end
	end
	-- then the screens already in use keep what they show (the oldest board of a screen decides)
	for _, b in ipairs(sorted) do
		local key = core.contentKey(b.station, b.kind, b.platforms, b.mode, b.layout)
		local slot = b.slot
		if type(slot) == "number" and slot >= 1 and slot < core.SLOTS and slotOfKey[key] == nil and keyOfSlot[slot] == nil then
			slotOfKey[key], keyOfSlot[slot] = slot, key
		end
	end
	local change, full, content = {}, {}, {}
	for _, b in ipairs(sorted) do
		local key = core.contentKey(b.station, b.kind, b.platforms, b.mode, b.layout)
		local slot = slotOfKey[key]
		if b.fixed then
			if keyOfSlot[b.slot] == key then content[b.slot] = { station = b.station, kind = b.kind, platforms = b.platforms, mode = b.mode, layout = b.layout } end
		else
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
			content[slot] = { station = b.station, kind = b.kind, platforms = b.platforms, mode = b.mode, layout = b.layout }
			if b.slot ~= slot then change[b.id] = slot end
		end
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

-- The stops a vehicle at stop `stop` calls at after it, up to where it is bound for (the stop half-way
-- round the line), the last one included.
function core.callingAt(names, stop)
	local n, out = #names, {}
	if n < 2 then return out end
	local last = ((stop - 1 + math.floor(n / 2)) % n) + 1
	local at = stop
	for _ = 1, n do
		at = at == n and 1 or at + 1
		if names[at] ~= nil and names[at] ~= "" then out[#out + 1] = names[at] end
		if at == last then break end
	end
	return out
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

-- The plan of a station for a board's window, worked out from where its trains stop: `segments` is a list of
-- { n = platform number, x0, y0, x1, y1 } (the ends of the track a platform's trains stop on, world metres),
-- several per platform allowed; `bx, by` the board. Returns the platforms in the station's own frame - along
-- the tracks and across them, from the middle of the station - sorted across: { { n, a0, a1, c } }, and the
-- board's place in the same frame (nil, nil when not given). nil when there is nothing to draw.
function core.diagram(segments, bx, by)
	if segments == nil or #segments == 0 then return nil end
	local longest, ux, uy = -1, 1, 0
	local sx, sy, count = 0, 0, 0
	for _, s in ipairs(segments) do
		local dx, dy = s.x1 - s.x0, s.y1 - s.y0
		local length = math.sqrt(dx * dx + dy * dy)
		if length > longest and length > 0.01 then longest, ux, uy = length, dx / length, dy / length end
		sx, sy, count = sx + s.x0 + s.x1, sy + s.y0 + s.y1, count + 2
	end
	local cx, cy = sx / count, sy / count
	local vx, vy = -uy, ux
	local byNumber, list = {}, {}
	for _, s in ipairs(segments) do
		local a0 = (s.x0 - cx) * ux + (s.y0 - cy) * uy
		local a1 = (s.x1 - cx) * ux + (s.y1 - cy) * uy
		if a0 > a1 then a0, a1 = a1, a0 end
		local c = ((s.x0 - cx) * vx + (s.y0 - cy) * vy + (s.x1 - cx) * vx + (s.y1 - cy) * vy) / 2
		local p = byNumber[s.n]
		if p == nil then
			p = { n = s.n, a0 = a0, a1 = a1, c = 0, parts = 0 }
			byNumber[s.n] = p
			list[#list + 1] = p
		end
		p.a0, p.a1 = math.min(p.a0, a0), math.max(p.a1, a1)
		p.c, p.parts = p.c + c, p.parts + 1
	end
	for _, p in ipairs(list) do p.c, p.parts = p.c / p.parts, nil end
	table.sort(list, function(a, b) if a.c ~= b.c then return a.c < b.c end return a.n < b.n end)
	local ba, bc
	if type(bx) == "number" and type(by) == "number" then
		ba, bc = (bx - cx) * ux + (by - cy) * uy, (bx - cx) * vx + (by - cy) * vy
	end
	return list, ba, bc
end

-- ---- The station plan (the map in a board's window) ---------------------------------------------------------
-- Everything is put into the station's own frame: metres along its tracks (x) and across them (y), from the
-- middle of its platform tracks, so that the platforms run across the picture.

-- The frame from the platform tracks ({ n, x0, y0, x1, y1 } as segmentsOf gives them), or from a fallback
-- middle and direction when there are none.
function core.planFrame(segments, fx, fy, fux, fuy)
	local longest, ux, uy = -1, fux or 1, fuy or 0
	local sx, sy, count = 0, 0, 0
	for _, s in ipairs(segments or {}) do
		local dx, dy = s.x1 - s.x0, s.y1 - s.y0
		local length = math.sqrt(dx * dx + dy * dy)
		if length > longest and length > 0.01 then longest, ux, uy = length, dx / length, dy / length end
		sx, sy, count = sx + s.x0 + s.x1, sy + s.y0 + s.y1, count + 2
	end
	local norm = math.sqrt(ux * ux + uy * uy)
	if norm < 1e-6 then ux, uy, norm = 1, 0, 1 end
	ux, uy = ux / norm, uy / norm
	if count == 0 then return { cx = fx or 0, cy = fy or 0, ux = ux, uy = uy } end
	return { cx = sx / count, cy = sy / count, ux = ux, uy = uy }
end

function core.planPoint(frame, x, y)
	local dx, dy = x - frame.cx, y - frame.cy
	return dx * frame.ux + dy * frame.uy, -dx * frame.uy + dy * frame.ux
end

-- What a model of a station is on the plan, by its file's name and the ground it covers (square metres):
-- "P" platform, "B" building, "S" stairs or underpass, nil = not drawn (roofs, lamps, benches, waiting areas).
function core.planKind(name, area)
	local n = tostring(name or ""):lower():match("([^/]*)$") or ""
	if n:find("roof", 1, true) or n:find("^tn_") or n:find("wait_area", 1, true) then return nil end
	if n:find("stair", 1, true) or n:find("underpass", 1, true) or n:find("underground", 1, true)
		or n:find("escalator", 1, true) or n:find("lift", 1, true) or n:find("elevator", 1, true) then return "S" end
	if n:find("perron", 1, true) or n:find("platform", 1, true) or n:find("^rail_t_") then
		if (area or 0) < 6 then return nil end   -- a sign or a lamp named after the platform it stands on
		return "P"
	end
	if (area or 0) < 25 then return nil end       -- furniture
	return "B"
end

-- The scene for the native painter and what the window needs beside it.
--   quads:  { { kind = "P" | "B" | "S", x = { 4 world x }, y = { 4 world y } } }
--   tracks: { { n = platform number or 0, x = { world x ... }, y = { ... } } }
-- Returns the scene text (lines "P|B|S x y x y x y x y" and "T n x y x y ..."), the bounds { x0, y0, x1, y1 }
-- and the platform tags { { n, x, y } }: the left end of each platform's track.
function core.planScene(frame, quads, tracks)
	local lines, tags = {}, {}
	local x0, y0, x1, y1
	local function take(x, y)
		if x0 == nil then x0, y0, x1, y1 = x, y, x, y end
		x0, x1 = math.min(x0, x), math.max(x1, x)
		y0, y1 = math.min(y0, y), math.max(y1, y)
	end
	-- buildings first, platforms over them, stairs on top: the painter keeps this order per kind anyway
	for _, q in ipairs(quads or {}) do
		local parts = { q.kind }
		for i = 1, 4 do
			local a, c = core.planPoint(frame, q.x[i], q.y[i])
			take(a, c)
			parts[#parts + 1] = string.format("%.1f %.1f", a, c)
		end
		lines[#lines + 1] = table.concat(parts, " ")
	end
	local ends = {}
	for _, t in ipairs(tracks or {}) do
		local parts = { "T", tostring(t.n or 0) }
		for i = 1, #t.x do
			local a, c = core.planPoint(frame, t.x[i], t.y[i])
			take(a, c)
			parts[#parts + 1] = string.format("%.1f %.1f", a, c)
			if (t.n or 0) > 0 then
				local e = ends[t.n]
				if e == nil or a < e.x then ends[t.n] = { n = t.n, x = a, y = c } end
			end
		end
		if #t.x >= 2 then lines[#lines + 1] = table.concat(parts, " ") end
	end
	for _, e in pairs(ends) do tags[#tags + 1] = e end
	table.sort(tags, function(a, b) return a.n < b.n end)
	if x0 == nil then x0, y0, x1, y1 = -50, -20, 50, 20 end
	return table.concat(lines, "\n"), { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }, tags
end

-- "x0 y0 x1 y1 ux uy|n:x:y;n:x:y" for the window
function core.planInfoText(bounds, tags, frame)
	local parts = {}
	for _, t in ipairs(tags or {}) do parts[#parts + 1] = string.format("%d:%.1f:%.1f", t.n, t.x, t.y) end
	-- the frame's direction along the tracks goes with it, for the north arrow
	return string.format("%.1f %.1f %.1f %.1f %.4f %.4f|", bounds.x0, bounds.y0, bounds.x1, bounds.y1, frame and frame.ux or 1, frame and frame.uy or 0)
		.. table.concat(parts, ";")
end

-- the same as text for the window: "n:a0:a1:c;n:a0:a1:c|ba:bc" (the board's part may be missing)
function core.diagramText(list, ba, bc)
	if list == nil then return "" end
	local parts = {}
	for _, p in ipairs(list) do parts[#parts + 1] = string.format("%d:%.1f:%.1f:%.1f", p.n, p.a0, p.a1, p.c) end
	local text = table.concat(parts, ";")
	if ba ~= nil then text = text .. string.format("|%.1f:%.1f", ba, bc) end
	return text
end

-- The layouts a board can have (the player chooses one in the board's window), after real British boards.
core.LAYOUTS = {
	{ id = "station", name = "Station board: heading, three departures, station name" },
	{ id = "national", name = "National Rail: time, destination, platform, expected; clock" },
	{ id = "platform", name = "Platform: next departure with its calling points, then the following ones" },
	{ id = "metro", name = "Metro: number, destination, minutes; clock" },
	{ id = "bus", name = "Bus stop: line, destination, minutes; time" },
}
core.LAYOUT_DEFAULT = "national"

-- The colours of the lit dots (the window offers them; "r g b" for the native layer). A board's choice is kept
-- with its layout as "layout/colour" (one field in what is saved); no colour is amber.
core.COLOURS = {
	{ id = "amber", name = "Amber", rgb = "255 150 24" },
	{ id = "white", name = "White", rgb = "235 240 255" },
	{ id = "yellow", name = "Yellow", rgb = "255 210 40" },
	{ id = "green", name = "Green", rgb = "70 255 100" },
	{ id = "red", name = "Red", rgb = "255 55 35" },
	{ id = "blue", name = "Blue", rgb = "80 160 255" },
}
core.COLOUR_DEFAULT = "amber"

-- "national/white" -> "national", "white" (the default for what is missing or unknown)
function core.splitLayout(text)
	local layout, colour = tostring(text or ""):match("^([^/]*)/?(.*)$")
	local known = false
	for _, l in ipairs(core.LAYOUTS) do if l.id == layout then known = true end end
	if not known then layout = core.LAYOUT_DEFAULT end
	local rgb
	for _, c in ipairs(core.COLOURS) do if c.id == colour then rgb = c.rgb end end
	if rgb == nil then colour, rgb = core.COLOUR_DEFAULT, core.COLOURS[1].rgb end
	return layout, colour, rgb
end

local ORDINAL = { "1st", "2nd", "3rd", "4th", "5th" }

-- the vehicles to show, soonest first
local function sorted(vehicles)
	local list = {}
	for _, v in ipairs(vehicles or {}) do
		if type(v.eta) == "number" and v.eta >= 0 and v.eta <= core.MAX_AHEAD then list[#list + 1] = v end
	end
	table.sort(list, function(a, b)
		if a.eta ~= b.eta then return a.eta < b.eta end
		if a.place ~= b.place then return tostring(a.place) < tostring(b.place) end
		return tostring(a.platform) < tostring(b.platform)
	end)
	return list
end

local function minutes(eta)
	if eta < core.DUE then return "Due" end
	local m = math.floor(eta / 60 + 0.5)
	return m == 1 and "1min" or (m .. "mins")
end

-- "Calling at: A, B and C" - the whole list; the board scrolls it when it is longer than the row
local function callingText(names)
	if names == nil or #names == 0 then return "" end
	local list = {}
	for i, name in ipairs(names) do list[i] = plain(name, 30) end
	if #list == 1 then return "Calling at: " .. list[1] .. " only" end
	return "Calling at: " .. table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

-- The rows of a board in one of the layouts (see core.LAYOUTS); "station" is the station board below.
function core.layoutRows(layout, kind, clock, station, vehicles)
	local list = sorted(vehicles)
	local function at(eta) return hhmm((clock or 0) + eta) end
	local rows = { "", "", "", "", "" }
	if layout == "national" then
		-- three departures; the clock in the middle below (the headings are printed on the board's casing)
		for i = 1, 3 do
			local v = list[i]
			if v ~= nil then
				rows[i] = "<2 " .. at(v.eta) .. "\t<36 " .. plain(v.place, 40) .. "\t>192 " .. plain(v.platform, 3) .. "\t>238 "
					.. (v.eta < core.DUE and "Due" or "On time")
			end
		end
		if #list == 0 then rows[2] = "Sorry no service" end
		rows[4] = core.CLOCK
		return rows
	elseif layout == "platform" then
		-- the next departure with where it calls, then the two after it
		local v = list[1]
		if v ~= nil then
			rows[1] = "<2 " .. at(v.eta) .. "\t<36 " .. plain(v.platform, 3) .. "\t<54 " .. plain(v.place, 34) .. "\t>238 "
				.. (v.eta < core.DUE and "Due" or ("Exp " .. at(v.eta)))
			rows[2] = "~<2 " .. callingText(v.calling)   -- "~": scrolls along when it does not fit (native layer)
		else
			rows[2] = "Sorry no service"
		end
		for i = 2, 3 do
			local w = list[i]
			if w ~= nil then
				rows[i + 1] = "<2 " .. ORDINAL[i] .. "\t<26 " .. at(w.eta) .. "\t<58 " .. plain(w.platform, 3) .. "\t<76 " .. plain(w.place, 34)
			end
		end
		rows[5] = core.CLOCK
		return rows
	elseif layout == "metro" then
		for i = 1, 3 do
			local v = list[i]
			if v ~= nil then rows[i] = "<2 " .. i .. "\t<14 " .. plain(v.place, 40) .. "\t>238 " .. minutes(v.eta) end
		end
		if #list == 0 then rows[2] = "Sorry no service" end
		rows[4] = core.CLOCK
		return rows
	elseif layout == "bus" then
		for i = 1, 3 do
			local v = list[i]
			if v ~= nil then
				rows[i] = "<2 " .. plain(core.lineLabel(v.line), 6) .. "\t<34 " .. plain(v.place, 40) .. "\t>238 " .. minutes(v.eta)
			end
		end
		if #list == 0 then rows[2] = "Sorry no service" end
		rows[4] = ">238 Time " .. core.CLOCK
		return rows
	end
	return core.rows(kind, clock, station, vehicles)
end

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
