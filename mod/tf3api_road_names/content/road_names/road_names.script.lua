-- TF3OpenAPI - road names, step 1: read the road network, group it into streets, name them, export.
--
-- Runs on the UI side (guiUpdate, once per frame) in small slices so the game never stalls:
--   1. waits a few seconds after the game has loaded
--   2. lists every street segment and reads a few hundred per frame
--   3. groups the segments into streets and names them (road_names/core.lua)
--   4. writes the result to <userdata>/tf3api_road_names/export.lua and a summary to crash_dump/stdout.txt
-- Read-only: nothing in the game or the save is changed. Log lines start "[tf3api_road_names]".

local MOD_ID = "tf3api_road_names"
local DIR, FILE = "tf3api_road_names", "export"

-- Segments whose road template contains one of these are not roads to name or draw on a street map.
local EXCLUDED_TEMPLATES = { "/airport/" }   -- taxiways and runways are built from street segments too

local START_DELAY = 5.0        -- seconds after the first call before the scan starts
local SEGMENTS_PER_FRAME = 250 -- segments read per frame
local LOG_TOP_STREETS = 15
local WATCH_SECONDS = 3.0      -- how often the road network is checked for changes once the names are up
local SLICE_SECONDS = 0.003    -- the naming work done in one frame: it is spread over as many frames as it needs
local breathe = function() end   -- gives way to the next frame when the slice is used up; set up further down

local quiet = false   -- on re-scans the detail lines (those starting with two spaces) are left out of the log

local function log(msg)
	if quiet and tostring(msg):sub(1, 2) == "  " then return end
	local text = "[" .. MOD_ID .. "] " .. tostring(msg)
	if not pcall(function() debugPrint(text) end) then print(text) end
	-- also into the native layer's log when it is there: on some game builds the game's own log shows nothing
	-- of what a script prints
	pcall(function() if tf3api ~= nil and tf3api.log ~= nil then tf3api.log(text) end end)
end

local function loadModule(name)
	local path = MOD_ID .. "::/road_names/" .. name
	local ok, mod = pcall(function() return ug_require(path) end)
	if ok and type(mod) == "table" then return mod end
	ok, mod = pcall(require, path)
	if ok and type(mod) == "table" then return mod end
	error("could not load " .. path .. ": " .. tostring(mod))
end

local core, names
local phase, startedAt, calls = "wait", nil, 0
local entities, cursor, segs, failed = nil, 1, {}, 0
local firstError
local linkJob, linkTowns, linkTime, linkFrames = nil, nil, 0, 0
-- The names and numbers given so far, by street key. A road keeps what it was given when the network is
-- read again after building work; only new roads get new names. Lives as long as this script state does
-- (it is not written into the save yet).
local remembered = { names = {}, refs = {} }
local ignoreAnnounced = false
-- What the player has decided about individual roads, by street key. Unlike the generated names these are
-- never thrown away by ignoreSavedData. In memory only for now (not written into the save yet).
-- abandoned[key] = true; names[key] = the player's name for the road; types[key] = N / B / A / AM / M;
-- styles[key] = both / number / name (what its label shows); cities: list of { name, polygon, scheme }
-- joins / splits: where the player took a road's end with the Adjust Road tool (pairs of segments that are one
-- street, or are not, whatever the automatic grouping would say; see core.group)
local choices = { abandoned = {}, names = {}, types = {}, styles = {}, cities = {}, joins = {}, splits = {} }
local lastExport = nil   -- the latest export as JSON text, for writing the map page on request

-- ---- Saved with the game ---------------------------------------------------------------------------------------
-- The game keeps each game script's state in the save. Ours is one text: the player's choices and the names
-- and numbers the roads have, a line each. The interface side cannot write the state, so it sends the text
-- to the simulation side as an event (handleEvent below), which stores it; the game writes it out whenever
-- it saves or autosaves. On load the interface side reads it back before the roads are first named.
local EVENT_ID = "tf3api_road_names"
local lastSavedText = nil
local pendingSaved = nil    -- text read from the save, applied once names.lua is loaded
local stateRead = false

local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

local function serializeChoices()
	local lines = { "v1" }
	for _, key in ipairs(sortedKeys(choices.names)) do lines[#lines + 1] = "n\t" .. key .. "\t" .. choices.names[key] end
	for _, key in ipairs(sortedKeys(choices.types)) do lines[#lines + 1] = "t\t" .. key .. "\t" .. choices.types[key] end
	for _, key in ipairs(sortedKeys(choices.styles)) do lines[#lines + 1] = "s\t" .. key .. "\t" .. choices.styles[key] end
	for _, key in ipairs(sortedKeys(choices.abandoned)) do lines[#lines + 1] = "a\t" .. key end
	for _, key in ipairs(sortedKeys(choices.joins)) do lines[#lines + 1] = "j\t" .. key end
	for _, key in ipairs(sortedKeys(choices.splits)) do lines[#lines + 1] = "x\t" .. key end
	for _, city in ipairs(choices.cities) do
		local numbers = {}
		for _, p in ipairs(city.polygon or {}) do numbers[#numbers + 1] = string.format("%.0f %.0f", p[1], p[2]) end
		lines[#lines + 1] = "c\t" .. tostring(city.name) .. "\t" .. tostring(city.scheme or "grid") .. "\t" .. table.concat(numbers, " ")
	end
	for _, key in ipairs(sortedKeys(remembered.names)) do
		lines[#lines + 1] = "r\t" .. key .. "\t" .. tostring(remembered.names[key]) .. "\t" .. tostring(remembered.refs[key] or "")
	end
	return table.concat(lines, "\n")
end

-- withNames = false leaves the generated names and numbers out (the ignoreSavedData development switch):
-- what the player chose is always restored.
local function restoreChoices(text, withNames)
	local counts = { n = 0, t = 0, s = 0, a = 0, c = 0, r = 0, j = 0, x = 0 }
	for line in tostring(text):gmatch("[^\n]+") do
		local fields = {}
		for value in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = value end
		local kind, key = fields[1], fields[2]
		if kind == "n" and key and fields[3] then choices.names[key] = fields[3]
		elseif kind == "t" and key and fields[3] then choices.types[key] = fields[3]
		elseif kind == "s" and key and fields[3] then choices.styles[key] = fields[3]
		elseif kind == "a" and key then choices.abandoned[key] = true
		elseif kind == "j" and key then choices.joins[key] = true
		elseif kind == "x" and key then choices.splits[key] = true
		elseif kind == "c" and key and fields[4] then
			local numbers, polygon = {}, {}
			for value in fields[4]:gmatch("%S+") do numbers[#numbers + 1] = tonumber(value) end
			for k = 1, #numbers - 1, 2 do polygon[#polygon + 1] = { numbers[k], numbers[k + 1] } end
			if #polygon >= 3 then choices.cities[#choices.cities + 1] = { name = key, scheme = fields[3], polygon = polygon } end
		elseif kind == "r" and key and fields[3] and withNames then
			remembered.names[key] = fields[3]
			if fields[4] ~= nil and fields[4] ~= "" then remembered.refs[key] = fields[4] end
		else
			kind = nil
		end
		if kind ~= nil and counts[kind] ~= nil then counts[kind] = counts[kind] + 1 end
	end
	return counts
end

-- Hands the current choices and names to the simulation side, which keeps them for the next save.
local function saveToGame()
	if inWorker then return end   -- the game's side does this, once it has the names back
	local text = serializeChoices()
	if text == lastSavedText then return end
	local ok, err = pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", EVENT_ID, "setChoices", { text = text }))
	end)
	if ok then
		if lastSavedText == nil then log(string.format("road names and choices are kept with the game from now on (%d KB)", math.floor(#text / 1024) + 1)) end
		lastSavedText = text
	else
		log("could not hand the road names to the game for saving: " .. tostring(err))
	end
end

-- Simulation side. These two run in the game's simulation threads, each with its own Lua state, so nothing
-- is kept in variables here: only the state the game gives us.
local function update(_params, state, _dt)
	if state ~= nil and not state:hasEventSubscriptions() then state:subscribeToEvent("setChoices") end
end

local function handleEvent(_params, state, _src, id, name, param)
	if id ~= EVENT_ID or name ~= "setChoices" or state == nil then return end
	if type(param) == "table" and type(param.text) == "string" then state:set({ version = 1, text = param.text }) end
end

-- The player's cities plus, during development, the ones listed in names.lua.
local function activeCities()
	local list = {}
	for _, city in ipairs(names.devCities or {}) do list[#list + 1] = city end
	-- the player's own are outlines drawn on the map: only those may have London-style postcodes
	for _, city in ipairs(choices.cities) do
		list[#list + 1] = { name = city.name, polygon = city.polygon, scheme = city.scheme, drawn = true }
	end
	return list
end
local lastStreets = nil                  -- the streets of the latest read, by the id the labels carry
local CHANNEL = "tf3api_road_names"      -- messages from the road window (tf3api.post / take)
local UI_CHANNEL = "tf3api_road_names.ui"  -- messages to the road window
local postcodePlan = nil                 -- core.postcodePlan of the latest read

local junctionsText = nil   -- the junctions of the latest read, as sent to the windows
local postcodeText = nil    -- the postcode plan as text, when it came back from the worker and not from a pass here

-- The road window works out the postcode of the spot that was clicked; it needs the plan for that. The
-- junction window needs to know each junction: one line each,
--   motorway | number | of | x | y | points | to previous | to next | road ; road ; ...
local function sendPostcodes()
	if postcodePlan == nil and postcodeText == nil then return end
	local okBridge, bridge = pcall(function() return tf3api end)
	if okBridge and type(bridge) == "table" and type(bridge.post) == "function" then
		pcall(bridge.post, UI_CHANNEL, "postcodes\t" .. (postcodePlan ~= nil and core.postcodePlanToText(postcodePlan) or postcodeText))
		if junctionsText ~= nil then pcall(bridge.post, UI_CHANNEL, "junctions\t" .. junctionsText) end
		-- the player's cities, for the list in the mod's panel: name | scheme | points, a line each
		local cityLines = {}
		for _, city in ipairs(choices.cities) do
			cityLines[#cityLines + 1] = string.format("%s|%s|%d", tostring(city.name), city.scheme == "compass" and "compass" or "grid", #(city.polygon or {}))
		end
		pcall(bridge.post, UI_CHANNEL, "cities\t" .. table.concat(cityLines, "\n"))
	end
end
local ABANDONED_BADGE = "Abandoned"

local function clock()
	local ok, t = pcall(os.clock)
	return ok and t or 0
end

-- engine vectors: fields x/y/z, or array-like
local function xyz(v)
	if v == nil then return nil end
	local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
	if ok and type(x) == "number" then return x, y, z or 0 end
	ok, x, y, z = pcall(function() return v[1], v[2], v[3] end)
	if ok and type(x) == "number" then return x, y, z or 0 end
	return nil
end

local function count(list)
	if list == nil then return 0 end
	local ok, n = pcall(function() return #list end)
	if ok and type(n) == "number" and n > 0 then return n end
	ok, n = pcall(function() return list:size() end)
	if ok and type(n) == "number" then return n end
	return 0
end

local excluded = 0

-- Both ends of a transport-network lane, as x, y pairs; nil when the geometry cannot be read.
local function laneEnds(geometry)
	local ok, a, b = pcall(function()
		local calc = api.type.EdgeGeometry.calcPos
		return calc(geometry, 0)[1], calc(geometry, 1)[1]
	end)
	if ok and a ~= nil and b ~= nil then
		local ax, ay = xyz(a)
		local bx, by = xyz(b)
		if ax ~= nil and bx ~= nil then return ax, ay, bx, by end
	end
	for _, field in ipairs({ "cubicSpline", "cubicOffsetSpline", "straight" }) do
		local okPos, pos = pcall(function() return geometry[field].pos end)
		if okPos and pos ~= nil and count(pos) >= 2 then
			local ax, ay = xyz(pos[1])
			local bx, by = xyz(pos[2])
			if ax ~= nil and bx ~= nil then return ax, ay, bx, by end
		end
	end
	return nil
end

-- Direction of travel from the game's own routing data: every street segment carries a transport network,
-- the lanes vehicles are routed over, each with the modes allowed on it and whether it may only be driven
-- one way. Returns 1 (all car lanes run node0 -> node1), -1 (all run the other way), 0 (both ways or
-- unknown), and a short note for the log.
local function travelDirection(entity, seg)
	local okTn, tn = pcall(function() return api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_NETWORK) end)
	if not okTn or tn == nil then return 0, "no transport network" end
	local okMode, car = pcall(function() return api.type.enum.TransportMode.CAR end)
	local sx, sy = seg.x1 - seg.x0, seg.y1 - seg.y0
	local lanes, carLanes, forward, backward, unread = count(tn.edges), 0, 0, 0, 0
	for i = 1, lanes do
		local okLane, lane = pcall(function() return tn.edges[i] end)
		if okLane and lane ~= nil then
			local okCar, isCar = pcall(function() return okMode and lane.transportModes[car] == true end)
			if okCar and isCar then
				carLanes = carLanes + 1
				local ax, ay, bx, by = laneEnds(lane.geometry)
				local okOne, oneWay = pcall(function() return lane.forwardOnly end)
				if ax == nil then
					unread = unread + 1
				elseif okOne and oneWay == false then
					forward, backward = forward + 1, backward + 1
				elseif (bx - ax) * sx + (by - ay) * sy >= 0 then
					forward = forward + 1
				else
					backward = backward + 1
				end
			end
		end
	end
	local note = string.format("%d lanes, %d for cars: %d forward, %d backward, %d unreadable", lanes, carLanes, forward, backward, unread)
	-- lanes for cars in each direction: all of them on a one-way road, the smaller side on a two-way one
	local perDirection = nil
	if forward > 0 and backward == 0 then perDirection = forward
	elseif backward > 0 and forward == 0 then perDirection = backward
	elseif forward > 0 and backward > 0 then perDirection = math.min(forward, backward) end
	if forward > 0 and backward == 0 then return 1, note, perDirection end
	if backward > 0 and forward == 0 then return -1, note, perDirection end
	return 0, note, perDirection
end

local function readSegment(entity)
	local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
	if edge == nil then return nil end
	local template = tostring(edge.roadTemplate or "")
	for _, part in ipairs(EXCLUDED_TEMPLATES) do
		if string.find(template, part, 1, true) then
			excluded = excluded + 1
			return false
		end
	end
	local x0, y0, z0 = xyz(edge.position0)
	local x1, y1, z1 = xyz(edge.position1)
	if x0 == nil or x1 == nil then return nil end
	local tx0, ty0 = xyz(edge.tangent0)
	local tx1, ty1 = xyz(edge.tangent1)
	local seg = {
		id = entity, n0 = edge.node0, n1 = edge.node1,
		x0 = x0, y0 = y0, z0 = z0, x1 = x1, y1 = y1, z1 = z1,
		tx0 = tx0 or 0, ty0 = ty0 or 0, tx1 = tx1 or 0, ty1 = ty1 or 0,
		tmpl = template,
		kind = tostring(edge.type or ""),
	}
	-- carriageway width and top speed from the lanes
	local width, speed, forward, backward = 0, 0, 0, 0
	local lanes = edge.laneConfigs
	for i = 1, count(lanes) do
		local okLane, lane = pcall(function() return lanes[i] end)
		if okLane and lane ~= nil then
			width = width + (tonumber(lane.width) or 0)
			local s = tonumber(lane.speed) or 0
			if s > speed then speed = s end
			if lane.forward == true then forward = forward + 1 elseif lane.forward == false then backward = backward + 1 end
		end
	end
	seg.w, seg.sp = width, speed
	-- kept for the log: what the game reports for lane directions on this segment
	local okRaw, raw = pcall(function() return lanes[1].forward end)
	seg.lanes, seg.fw, seg.bw, seg.fwRaw = count(lanes), forward, backward, okRaw and tostring(raw) or "(unreadable)"
	-- one-way: every lane runs the same way (1 = node0 to node1, -1 = the reverse, 0 = two-way)
	seg.oneway = (forward > 0 and backward == 0) and 1 or ((backward > 0 and forward == 0) and -1 or 0)
	-- the routing data is the better source; the lane list above is only the fallback
	local routed, note, perDirection = travelDirection(entity, seg)
	seg.routeNote = note
	seg.dirLanes = perDirection   -- nil when the routing data could not be read
	if routed ~= 0 then seg.oneway = routed end
	local d = tonumber(edge.distance)
	seg.len = (d ~= nil and d > 0) and d or math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
	return seg
end

-- Every street segment on the map. The engine refuses to enumerate street segments by component type
-- ("Cannot loop over this component type", seen on build 40408), so the street system's own node-to-segments
-- map is the source; enumerating all edges and keeping the street ones is the fallback.
local function listStreetSegments()
	local list, seen = {}, {}
	local okMap, map = pcall(function() return api.engine.system.streetSystem.getNode2StreetEdgeMap() end)
	if okMap and map ~= nil then
		pcall(function()
			for _, segments in pairs(map) do
				for i = 1, count(segments) do
					local e = segments[i]
					if e ~= nil and not seen[e] then
						seen[e] = true
						list[#list + 1] = e
					end
				end
			end
		end)
		-- a fixed order, so the export lists segments the same way on every run
		pcall(table.sort, list)
		if #list > 0 then return list, "the street system's node map" end
	end
	local okAll, all = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.BASE_EDGE)
	if okAll and all ~= nil then
		for i = 1, count(all) do
			local e = all[i]
			local okStreet, street = pcall(api.engine.getComponent, e, api.type.ComponentType.BASE_EDGE_STREET)
			if okStreet and street ~= nil then list[#list + 1] = e end
		end
		if #list > 0 then return list, "all edges, filtered to streets" end
	end
	error("could not list street segments: node map " .. tostring(okMap and "empty" or map) .. "; edge list " .. tostring(okAll and "empty" or all))
end

-- In the worker's Lua state there is no game to read from: the towns and stations come with the job.
local workerTowns, workerStations, inWorker = nil, nil, false

local function readTowns()
	if workerTowns ~= nil then return workerTowns end
	local towns = {}
	local ok, list = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.TOWN)
	if not ok or list == nil then return towns end
	for i = 1, count(list) do
		local e = list[i]
		pcall(function()
			local name = api.engine.util.getEntityName(e)
			local bv = api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME)
			local ax, ay = xyz(bv.bbox.min)
			local bx, by = xyz(bv.bbox.max)
			towns[#towns + 1] = { name = tostring(name), x = (ax + bx) * 0.5, y = (ay + by) * 0.5 }
		end)
	end
	return towns
end

-- Whether a station group is a railway station: the station system says which carriers call there. A bus
-- stop, a harbour or an airport is not what Station Road is named after. When the game does not say, the
-- answer is no.
local function isRailwayStation(group)
	local ok, result = pcall(function() return api.engine.system.stationSystem.getCarriers(group, -1, -1) end)
	if not ok or result == nil then return false end
	local okRail, rail = pcall(function() return api.type.enum.Carrier.RAIL end)
	local found = false
	pcall(function()
		local carriers = result[1]
		for i = 1, count(carriers) do
			if (okRail and carriers[i] == rail) or tostring(carriers[i]):upper():find("RAIL", 1, true) then found = true end
		end
	end)
	return found
end

local stationsSeen = 0   -- every station group of the latest read, railway or not (for the log)

-- Where the railway stations are (the middle of each station group). Empty when the game does not say.
local function readStations()
	if workerStations ~= nil then return workerStations end
	local stations = {}
	stationsSeen = 0
	local ok, list = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.STATION_GROUP)
	if not ok or list == nil then return stations end
	for i = 1, math.min(count(list), 2000) do
		local e = list[i]
		stationsSeen = stationsSeen + 1
		if isRailwayStation(e) then pcall(function()
			local bv = api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME)
			local ax, ay = xyz(bv.bbox.min)
			local bx, by = xyz(bv.bbox.max)
			stations[#stations + 1] = { x = (ax + bx) * 0.5, y = (ay + by) * 0.5 }
		end) end
	end
	return stations
end

local function round1(v) return math.floor(v * 10 + 0.5) / 10 end

-- JSON text for a value made of tables, strings, numbers and booleans. A table with a first element is
-- written as an array, any other table as an object.
local function toJson(value, out)
	local top = out == nil
	out = out or {}
	local kind = type(value)
	if kind == "table" then
		if value[1] ~= nil or next(value) == nil then
			out[#out + 1] = "["
			for i = 1, #value do
				if i % 64 == 0 then breathe() end
				if i > 1 then out[#out + 1] = "," end
				toJson(value[i], out)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			-- keys in a fixed order, so that the same data always gives the same text
			local keys = {}
			for k in pairs(value) do keys[#keys + 1] = tostring(k) end
			table.sort(keys)
			for n, k in ipairs(keys) do
				if n > 1 then out[#out + 1] = "," end
				toJson(k, out)
				out[#out + 1] = ":"
				local v = value[k]
				if v == nil then v = value[tonumber(k)] end
				toJson(v, out)
			end
			out[#out + 1] = "}"
		end
	elseif kind == "string" then
		out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(c)
			if c == '"' then return '\\"' end
			if c == "\\" then return "\\\\" end
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = "0"
		elseif value == math.floor(value) and math.abs(value) < 1e15 then
			out[#out + 1] = string.format("%d", value)
		else
			out[#out + 1] = string.format("%.2f", value)
		end
	elseif kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	else
		out[#out + 1] = "null"
	end
	if top then return table.concat(out) end
end

-- Which sign a road number is shown on: M = motorway (also an A road's motorway section), A = primary
-- A road (one or two digits), B = everything else with a number, - = no number.
local function shieldOf(ref)
	if ref == nil or ref == "" then return "-" end
	if ref:sub(1, 1) == "M" or ref:sub(-3) == "(M)" then return "M" end
	local digits = ref:match("%d+") or ""
	if ref:sub(1, 1) == "A" and #digits <= 2 then return "A" end
	return "B"
end

-- Hands the roads to the native side, which draws their names in the world (format: road_labels.h in the
-- native source). Every road uses the default label style for now: number and name.
local lastJunctions = {}   -- motorway junctions of the latest read: { ref, number, x, y }

local function sendLabels(streets)
	local okBridge, bridge = pcall(function() return tf3api end)
	if not okBridge or type(bridge) ~= "table" or type(bridge.setRoadLabels) ~= "function" then
		log("names are not drawn in the world: the native layer (tf3api) is not installed or is too old")
		return
	end
	local lines = {}
	for index, s in ipairs(streets) do
		breathe()
		local ref = s.ref or ""
		local name = (s.name == ref) and "" or (s.name or "")
		local shield = shieldOf(ref)
		-- what the label shows is the road's own choice: number and name (the default), number only, or name
		-- only. A road with only one of the two shows that one whatever was chosen.
		local style = choices.styles[s.key]
		if style == "number" and ref ~= "" then name = "" end
		if style == "name" and name ~= "" then shield, ref = "-", "" end
		-- an abandoned road has no number: a grey badge saying so, and its name
		if s.abandoned then shield, ref = "X", ABANDONED_BADGE end
		-- flags come back with a click: i = cut off from the road network, a = marked abandoned,
		-- T + letter = the type the player chose (N, B, A, X for A(M), M), S + letter = the label style chosen
		-- (b both, n number, m name)
		local typeChoice, styleChoice = choices.types[s.key], choices.styles[s.key]
		local flags = (s.isolated and "i" or "") .. (s.abandoned and "a" or "")
			.. (typeChoice and ("T" .. (typeChoice == "AM" and "X" or typeChoice)) or "")
			.. (styleChoice and ("S" .. (styleChoice == "both" and "b" or styleChoice == "number" and "n" or "m")) or "")
		if ref ~= "" or name ~= "" then
			-- what the road can carry, for its window: L lanes each way, V speed limit in m/s, C vehicles an
			-- hour each way, W 1 = one-way
			local info = ""
			local stats = core.streetStats(s, segs)
			if stats ~= nil then
				info = string.format("L%d;V%.1f;C%d;W%d", stats.lanes, stats.speed, stats.perDirection, stats.oneWay and 1 or 0)
			end
			lines[#lines + 1] = string.format("S\t%s\t%d\t%s\t%s\t%d\t%s\t%s", shield, s.cls, ref, name, index, flags, info)
			for _, si in ipairs(s.segs) do
				local seg = segs[si]
				lines[#lines + 1] = string.format("G %.1f %.1f %.1f %.1f %.1f %.1f", seg.x0, seg.y0, seg.z0 or 0, seg.x1, seg.y1, seg.z1 or 0)
			end
		end
	end
	-- motorway junction numbers: a black badge at each junction, on a short piece of its own so that it only
	-- shows from fairly close (id 0: it is not a road and opens no window)
	for index, junction in ipairs(lastJunctions) do
		-- the id is the junction's place in the list and the flag J says it is a junction, so that a click on
		-- it opens the junction's own window
		lines[#lines + 1] = string.format("S\tJ\t3\t%d\t\t%d\tJ\t", junction.number, index)
		lines[#lines + 1] = string.format("G %.1f %.1f %.1f %.1f %.1f %.1f", junction.x - 40, junction.y, junction.z or 0, junction.x + 40, junction.y, junction.z or 0)
	end
	local okCall, taken, why = pcall(bridge.setRoadLabels, table.concat(lines, "\n"))
	if okCall and type(taken) == "number" then
		log(string.format("%d roads handed to the native layer for drawing", taken))
	else
		log("road names were not accepted by the native layer: " .. tostring(why or taken))
	end
end

local function finish()
	local t0 = clock()
	if inWorker then quiet = false end
	local towns = linkTowns or readTowns()
	local streets, streetOf, joints = core.group(segs, choices)
	core.markIsolated(streets, segs)
	for _, s in ipairs(streets) do
		-- the choice only applies while the road is cut off; joined up again, it is an ordinary road
		if choices.abandoned[s.key] and s.isolated then s.abandoned = true end
		s.typeChoice = choices.types[s.key]
	end
	-- the road each railway station stands on
	local stations = readStations()
	if #stations > 0 then
		local reach = names.stationReach * names.stationReach
		local marked = 0
		for _, station in ipairs(stations) do
			breathe()
			local best, bestD
			for i, seg in ipairs(segs) do
				local d = ((seg.x0 + seg.x1) * 0.5 - station.x) ^ 2 + ((seg.y0 + seg.y1) * 0.5 - station.y) ^ 2
				if d <= reach and (bestD == nil or d < bestD) then best, bestD = i, d end
			end
			if best ~= nil and not streets[streetOf[best]].station then
				streets[streetOf[best]].station = true
				marked = marked + 1
			end
		end
		log(string.format("%d railway stations (of %d stations of all kinds), %d roads with a railway station on them", #stations, stationsSeen, marked))
	end
	-- names to keep: what earlier reads gave, and over that what the player typed (never thrown away)
	local keepNames = {}
	lastStreets = streets
	postcodePlan = core.postcodePlan(towns, linkJob and linkJob.size or nil, names, activeCities())
	for _, name in ipairs(postcodePlan.demoted or {}) do
		log("city '" .. tostring(name) .. "' asked for London-style postcodes, but another city has them: postcodes are unique on a map, so it gets an ordinary area of its own")
	end
	for _, city in ipairs(linkJob and linkJob.cities or {}) do
		local inside = {}
		for _, t in ipairs(city.towns) do inside[#inside + 1] = tostring(towns[t].name) end
		log(string.format("city '%s': %d towns (%s), centre %s", city.name, #city.towns, table.concat(inside, ", "),
			city.centre and tostring(towns[city.centre].name) or "none"))
	end
	sendPostcodes()
	if names.ignoreSavedData then
		remembered = { names = {}, refs = {} }
		if not ignoreAnnounced then
			ignoreAnnounced = true
			log("ignoreSavedData is ON (names.lua): every read names and numbers the roads from scratch")
		end
	end
	for key, name in pairs(remembered.names) do keepNames[key] = name end
	for key, name in pairs(choices.names) do keepNames[key] = name end
	local _, hubTown = core.name(streets, towns, names, keepNames, segs, joints, linkJob, remembered.refs)
	local known, new = 0, 0
	for _, s in ipairs(streets) do
		if remembered.names[s.key] ~= nil then known = known + 1 else new = new + 1 end
		remembered.names[s.key] = s.name
		remembered.refs[s.key] = s.ref
	end
	if known > 0 then log(string.format("%d roads kept their names and numbers, %d are new", known, new)) end
	saveToGame()
	if linkJob ~= nil then
		local a, b = 0, 0
		for _, link in ipairs(linkJob.links or {}) do if link.kind == "A" then a = a + 1 else b = b + 1 end end
		log(string.format("links between towns: %d A, %d B, worked out in %.0f ms over %d frames", a, b, linkTime * 1000, linkFrames))
	end
	local t1 = clock()

	-- export: compact arrays, one row per segment and per street
	local out = { version = 2, towns = towns, hub = hubTown and towns[hubTown].name or "", streets = {}, segments = {}, templates = {} }
	out.postcodes = { sector = postcodePlan.sector, places = {} }
	for i, p in ipairs(postcodePlan.places) do
		out.postcodes.places[i] = { code = p.code, number = p.number, count = p.count, x = round1(p.x), y = round1(p.y), name = p.name, city = p.city or 0 }
	end
	out.cities = {}
	for i, city in ipairs(linkJob and linkJob.cities or {}) do
		local outline, inside = {}, {}
		for _, p in ipairs(city.polygon) do outline[#outline + 1] = round1(p[1]); outline[#outline + 1] = round1(p[2]) end
		for _, t in ipairs(city.towns) do inside[#inside + 1] = tostring(towns[t].name) end
		out.cities[i] = { name = city.name, scheme = city.scheme, x = round1(city.x), y = round1(city.y), outline = outline, towns = inside }
	end
	local templateIndex = {}
	for i, s in ipairs(streets) do
		out.streets[i] = { s.name, s.cls, round1(s.len), round1(s.x), round1(s.y), #s.segs, s.ref or "" }
	end
	for i, seg in ipairs(segs) do
		breathe()
		local ti = templateIndex[seg.tmpl]
		if ti == nil then
			ti = #out.templates + 1
			out.templates[ti] = seg.tmpl
			templateIndex[seg.tmpl] = ti
		end
		out.segments[i] = {
			streetOf[i], round1(seg.x0), round1(seg.y0), round1(seg.x1), round1(seg.y1),
			round1(seg.tx0), round1(seg.ty0), round1(seg.tx1), round1(seg.ty1),
			round1(seg.w), round1(seg.sp), ti, seg.kind, seg.oneway or 0,
			tonumber(seg.n0) or 0, tonumber(seg.n1) or 0, seg.dirLanes or 0,   -- the game's own node ids, and lanes each way
		}
	end
	-- motorway junctions, numbered from the hub end; their height is that of the nearest road node
	lastJunctions = core.junctions(streets, segs, hubTown and towns[hubTown] or { x = 0, y = 0 }, names)
	for _, junction in ipairs(lastJunctions) do
		local bestD
		for _, seg in ipairs(segs) do
			local d = (seg.x0 - junction.x) ^ 2 + (seg.y0 - junction.y) ^ 2
			if bestD == nil or d < bestD then bestD, junction.z = d, seg.z0 end
		end
	end
	out.junctions = {}
	for i, junction in ipairs(lastJunctions) do
		out.junctions[i] = { ref = junction.ref, number = junction.number, x = round1(junction.x), y = round1(junction.y), connects = junction.connects }
	end
	if #lastJunctions > 0 then log(string.format("%d motorway junctions numbered", #lastJunctions)) end
	do
		local lines = {}
		for i, junction in ipairs(lastJunctions) do
			local roads = {}
			for k, road in ipairs(junction.connects or {}) do roads[k] = (tostring(road):gsub("[|;\n\t]", " ")) end
			lines[i] = string.format("%s|%d|%d|%.0f|%.0f|%d|%.0f|%.0f|%s", junction.ref, junction.number, junction.of or 0, junction.x, junction.y,
				junction.points or 0, junction.toPrevious or -1, junction.toNext or -1, table.concat(roads, ";"))
		end
		junctionsText = table.concat(lines, "\n")
		sendPostcodes()
	end
	sendLabels(streets)
	-- Written through the native bridge when it is there (a JSON file beside the game, in tf3api_out); the
	-- game's own userdata writer is the fallback, where the script environment has one.
	local saved, saveErr, savedAs = false, nil, nil
	local okBridge, bridge = pcall(function() return tf3api end)
	if okBridge and type(bridge) == "table" and type(bridge.writeFile) == "function" then
		-- not through pcall: the work may give way to the next frame in the middle of it, which a protected
		-- call would not allow on every Lua version. An error here ends the naming pass with a log line.
		local okJson, json = true, toJson(out)
		if okJson then lastExport = json end
		if okJson then
			local okCall, wrote, why = pcall(bridge.writeFile, "road_export.json", json)
			saved, saveErr = okCall and wrote == true, why or (not okCall and wrote) or nil
			if saved then savedAs = string.format("tf3api_out/road_export.json (%d KB)", math.floor(#json / 1024)) end
		else
			saveErr = "could not build the JSON text: " .. tostring(json)
		end
	end
	if not saved and app ~= nil and type(app.saveUserdata) == "function" then
		saved, saveErr = pcall(app.saveUserdata, DIR, FILE, out)
		if saved then savedAs = DIR .. "/" .. FILE .. ".lua (game userdata folder)" end
	end
	if not saved and saveErr == nil then saveErr = "no native bridge and no userdata writer in this script environment" end
	local t2 = clock()

	local total = 0
	for _, s in ipairs(streets) do total = total + s.len end
	if hubTown ~= nil then log("hub town for road numbering: " .. towns[hubTown].name) end
	log(string.format("done: %d segments (%d unreadable) in %d streets, %.1f km of road, %d towns; grouping+naming %.0f ms, export %.0f ms",
		#segs, failed, #streets, total / 1000, #towns, (t1 - t0) * 1000, (t2 - t1) * 1000))
	if not saved then log("export NOT written: " .. tostring(saveErr)) else log("export written: " .. savedAs) end
	if excluded > 0 then log(string.format("left out %d segments that are not roads (airport taxiways and runways)", excluded)) end
	-- which road templates the map is built from, most used first (to tune the road classes against)
	local templateCount, templateOrder = {}, {}
	for _, seg in ipairs(segs) do
		if templateCount[seg.tmpl] == nil then
			templateCount[seg.tmpl] = { n = 0, w = seg.w, sp = seg.sp, cls = core.classOf(seg) }
			templateOrder[#templateOrder + 1] = seg.tmpl
		end
		templateCount[seg.tmpl].n = templateCount[seg.tmpl].n + 1
	end
	table.sort(templateOrder, function(a, b) return templateCount[a].n > templateCount[b].n end)
	for rank = 1, math.min(14, #templateOrder) do
		local name = templateOrder[rank]
		local t = templateCount[name]
		log(string.format("  template %5d x  class %d  width %4.1f m  top speed %4.1f m/s  %s", t.n, t.cls, t.w, t.sp, name))
	end
	if firstError ~= nil then log("first read error: " .. firstError) end

	local order = {}
	for i = 1, #streets do order[i] = i end
	table.sort(order, function(a, b) return streets[a].len > streets[b].len end)
	for rank = 1, math.min(LOG_TOP_STREETS, #order) do
		local s = streets[order[rank]]
		log(string.format("  %2d. %-28s %-6s %6.0f m, %3d segments, class %d", rank, s.name, s.ref or "", s.len, #s.segs, s.cls))
	end
	if #segs > 0 then
		local s = segs[1]
		log(string.format("  sample segment: template '%s', kind '%s', width %.1f, speed %.1f, length %.1f", s.tmpl, s.kind, s.w, s.sp, s.len))
		for _, seg in ipairs(segs) do
			if core.classOf(seg) == 3 then
				log(string.format("  sample motorway segment: %d lanes, %d forward, %d backward, first lane's forward = %s, template '%s'",
					seg.lanes or 0, seg.fw or 0, seg.bw or 0, tostring(seg.fwRaw), seg.tmpl))
				log("  its routing data: " .. tostring(seg.routeNote) .. string.format(" -> one-way flag %d", seg.oneway or 0))
				break
			end
		end
	end
end

-- A number that changes when street segments are built, removed or replaced (an upgrade replaces the
-- segment): how many there are and a checksum of their ids.
local function networkSignature(list)
	local sum = 0
	for i = 1, #list do
		local id = tonumber(list[i]) or 0
		sum = (sum + id * (1 + i % 7)) % 2147483647
	end
	return #list .. ":" .. sum
end

local signature, pendingSignature, lastWatch, watchCost = nil, nil, 0, nil

-- Once the names are up: look at the road network every WATCH_SECONDS; when it has changed and then stayed
-- the same for one more check (the player has finished that bit of building), read it again.
local function watch()
	local now = clock()
	if now - lastWatch < WATCH_SECONDS then return end
	local okList, list = pcall(listStreetSegments)
	lastWatch = clock()
	if watchCost == nil then
		watchCost = lastWatch - now
		log(string.format("watching the road network for changes: one check takes %.1f ms, every %.0f s", watchCost * 1000, WATCH_SECONDS))
	end
	if not okList then return end
	local current = networkSignature(list)
	if current == signature then
		pendingSignature = nil
		return
	end
	if current ~= pendingSignature then
		pendingSignature = current   -- still changing: wait for it to settle
		return
	end
	log(string.format("the road network changed (%d segments now): reading it again", #list))
	quiet = true
	signature, pendingSignature = current, nil
	entities, cursor, segs, failed, firstError, excluded = list, 1, {}, 0, nil, 0
	phase = "read"
end

-- Tells the player something through the road window's channel (and the log).
local function notify(text)
	log(text)
	local okBridge, bridge = pcall(function() return tf3api end)
	if okBridge and type(bridge) == "table" and type(bridge.post) == "function" then pcall(bridge.post, UI_CHANNEL, "notice\t" .. text) end
end

-- Writes the street map as a web page (tf3api_out/road_map.html) from the latest read: the same page
-- tools/road_map.py makes, straight from the game.
local function writeMapPage()
	local okBridge, bridge = pcall(function() return tf3api end)
	if not okBridge or type(bridge) ~= "table" or type(bridge.writeFile) ~= "function" then
		notify("The map page needs the native layer (tf3api), which is not installed.")
		return false
	end
	if lastExport == nil then
		notify("The roads have not been read yet. Try again in a moment.")
		return false
	end
	local okPage, viewer = pcall(loadModule, "viewer_page.lua")
	if not okPage or type(viewer.page) ~= "string" then
		notify("The map page template could not be loaded.")
		return false
	end
	local page = viewer.page:gsub("__TITLE__", function() return "Transport Fever 3 street map" end)
	page = page:gsub("__DATA__", function() return lastExport end)
	local okCall, wrote, why = pcall(bridge.writeFile, "road_map.html", page)
	if okCall and wrote == true then
		notify(string.format("Street map written: tf3api_out\\road_map.html in the game folder (%d KB).", math.floor(#page / 1024)))
		return true
	end
	notify("The map page could not be written: " .. tostring(why or wrote))
	return false
end

-- Messages from the interface:
--   rename <tab> road id <tab> new name      (empty = back to an automatic name)
--   type <tab> road id <tab> N, B, A, AM, M or auto
--   style <tab> road id <tab> both, number, name or auto
--   export                                  (write the street map as a web page)
--   abandon <tab> road id <tab> 1 or 0
--   city <tab> name <tab> grid or compass <tab> x y x y ...   (an outline; replaces a city of the same name)
--   city-remove <tab> name
--   hello                                                     (the road window asks for the postcode plan)
-- Returns "names" when the roads have to be named again, "links" when the links between towns have to be
-- worked out again first (a city changed), or nil.
-- ---- Adjust Road ------------------------------------------------------------------------------------------------
-- The tool in the interface shows a road as a line with a circle at each end, and lets the player take an end
-- somewhere else. It asks here for the road's line, and tells here where an end was let go. A road is known to
-- the tool by one of its segments (the position key of it): road numbers on labels change with every naming.

-- the road that has the segment with this key, as the roads are grouped now: its street and its line
local function roadWithSegment(segmentKey)
	local streets, streetOf = core.group(segs, choices)
	for i, seg in ipairs(segs) do
		if core.segKey(seg) == segmentKey then
			local street = streets[streetOf[i]]
			local chain, why = core.streetChain(segs, street)
			return street, chain, why
		end
	end
	return nil, nil, "the road is gone"
end

-- what the tool draws: "extent <tab> key <tab> x0 y0 x1 y1;... <tab> first end x y, last end x y"
local function extentMessage(segmentKey, street, chain, why)
	if chain == nil then return "extent-none\t" .. tostring(why or "the road is not a single line") end
	local parts = {}
	for _, i in ipairs(chain.segs) do
		parts[#parts + 1] = string.format("%.1f %.1f %.1f %.1f", segs[i].x0, segs[i].y0, segs[i].x1, segs[i].y1)
	end
	local function at(node, i)
		if segs[i].n0 == node then return segs[i].x0, segs[i].y0 end
		return segs[i].x1, segs[i].y1
	end
	local ax, ay = at(chain.nodes[1], chain.segs[1])
	local bx, by = at(chain.nodes[#chain.nodes], chain.segs[#chain.segs])
	return string.format("extent\t%s\t%s\t%.1f %.1f %.1f %.1f", segmentKey, table.concat(parts, ";"), ax, ay, bx, by)
end

local function postToInterface(text)
	local okBridge, bridge = pcall(function() return tf3api end)
	if okBridge and type(bridge) == "table" and type(bridge.post) == "function" then pcall(bridge.post, UI_CHANNEL, text) end
end

-- an end of the road was let go at (x, y). Returns true when the roads changed.
local function adjustRoad(segmentKey, whichEnd, x, y)
	local street, chain, why = roadWithSegment(segmentKey)
	if chain == nil then
		postToInterface(extentMessage(segmentKey, street, chain, why))
		return false
	end
	local oldKey = street.key
	-- a segment that stays in the road whatever happens: the one at the end that is not being moved
	local staying = (whichEnd == 2) and chain.segs[1] or chain.segs[#chain.segs]
	local stayingKey = core.segKey(segs[staying])
	local what, count = core.adjustExtent(segs, chain, whichEnd, x, y, choices)
	if what == nil then
		log("adjust road: nothing changed (" .. tostring(count) .. ")")
		postToInterface("notice\t" .. tostring(count))
		postToInterface(extentMessage(stayingKey, street, chain, nil))
		return false
	end
	local newStreet, newChain, newWhy = roadWithSegment(stayingKey)
	-- the road keeps what it had (its name, its number, its type ...): those are kept by the road's key, which is
	-- the smallest key among its segments and may be another one now
	if newStreet ~= nil and newStreet.key ~= oldKey then
		for _, map in ipairs({ choices.names, choices.types, choices.styles, choices.abandoned, remembered.names, remembered.refs }) do
			if map[oldKey] ~= nil then
				map[newStreet.key] = map[oldKey]
				map[oldKey] = nil
			end
		end
	end
	log(string.format("adjust road: %s by %d segment(s)", what, count))
	postToInterface(extentMessage(stayingKey, newStreet, newChain, newWhy))
	return true
end

local function handleMessages()
	local okBridge, bridge = pcall(function() return tf3api end)
	if not okBridge or type(bridge) ~= "table" or type(bridge.take) ~= "function" then return false end
	local changed, relink = false, false
	for _ = 1, 20 do
		local ok, message = pcall(bridge.take, CHANNEL)
		if not ok or type(message) ~= "string" then break end
		local id, value = message:match("^abandon\t(%d+)\t([01])$")
		local street = id and lastStreets and lastStreets[tonumber(id)] or nil
		local editId, editWhat, editValue = message:match("^(%a+)\t(%d+)\t(.*)$")
		if editId == "rename" or editId == "type" or editId == "style" then
			editId, editWhat = tonumber(editWhat), editId
		else
			editId, editWhat, editValue = nil, nil, nil
		end
		local cityName, scheme, outline = message:match("^city\t([^\t]+)\t([^\t]*)\t(.*)$")
		local removeName = message:match("^city%-remove\t([^\t]+)$")
		local extentId = message:match("^extent\t(%d+)$")
		local adjustKey, adjustEnd, adjustX, adjustY = message:match("^adjust\t([^\t]+)\t([12])\t([%-%d%.]+)\t([%-%d%.]+)$")
		if extentId ~= nil then
			-- the Adjust Road tool was opened on the road with this label number
			local road = lastStreets and lastStreets[tonumber(extentId)] or nil
			if road == nil or core == nil then
				postToInterface("extent-none\tthe road is gone")
			else
				local okExtent, err = pcall(function()
					local found, chain, why = roadWithSegment(road.key)
					postToInterface(extentMessage(road.key, found, chain, why))
				end)
				if not okExtent then log("adjust road: " .. tostring(err)) end
			end
		elseif adjustKey ~= nil then
			local okAdjust, moved = pcall(adjustRoad, adjustKey, tonumber(adjustEnd), tonumber(adjustX), tonumber(adjustY))
			if not okAdjust then
				log("adjust road: " .. tostring(moved))
			elseif moved then
				relink = true
			end
		elseif message == "hello" then
			sendPostcodes()   -- the road window has (re)started and asks for what it needs
		elseif message == "export" then
			-- the map page is made where the last pass ran
			if workerState == "ready" then pcall(tf3api.workerRun, "X export") else writeMapPage() end
		elseif editWhat ~= nil then
			local road = lastStreets and lastStreets[editId] or nil
			if road == nil then
				notify("That road is no longer there.")
			elseif editWhat == "rename" then
				local text = tostring(editValue):gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 48)
				local taken = false
				for _, other in ipairs(lastStreets) do
					-- a name belongs to one road: the pieces of this road may share it, nothing else may
					if other ~= road and other.partOf == nil and text ~= "" and tostring(other.name):lower() == text:lower() then taken = true end
				end
				if taken then
					notify("Another road is already called " .. text .. ". A name can only be used once on a map.")
				else
					choices.names[road.key] = (text ~= "") and text or nil
					remembered.names[road.key] = nil
					log(text ~= "" and string.format("'%s' renamed to '%s'", tostring(road.name), text) or string.format("'%s' goes back to an automatic name", tostring(road.name)))
					changed = true
				end
			elseif editWhat == "type" then
				local valid = { N = true, B = true, A = true, AM = true, M = true }
				choices.types[road.key] = valid[editValue] and editValue or nil
				-- what was remembered for it was worked out for the old type (a motorway has no street name)
				remembered.refs[road.key] = nil
				remembered.names[road.key] = nil
				log(string.format("'%s' road type: %s", tostring(road.name), valid[editValue] and editValue or "automatic"))
				changed = true
			else
				local valid = { both = true, number = true, name = true }
				choices.styles[road.key] = valid[editValue] and editValue or nil
				log(string.format("'%s' label: %s", tostring(road.name), valid[editValue] and editValue or "default"))
				changed = true
			end
		elseif cityName ~= nil or removeName ~= nil then
			local name = cityName or removeName
			for i = #choices.cities, 1, -1 do
				if choices.cities[i].name == name then table.remove(choices.cities, i) end
			end
			if cityName ~= nil then
				local numbers, polygon = {}, {}
				for value in outline:gmatch("%S+") do numbers[#numbers + 1] = tonumber(value) end
				for k = 1, #numbers - 1, 2 do polygon[#polygon + 1] = { numbers[k], numbers[k + 1] } end
				if #polygon >= 3 then
					choices.cities[#choices.cities + 1] = { name = name, polygon = polygon, scheme = scheme }
					log(string.format("city '%s' defined (%d points, %s postcodes)", name, #polygon, scheme == "compass" and "compass" or "grid"))
				else
					log("city '" .. name .. "' not defined: its outline needs at least three points")
				end
			else
				log("city '" .. name .. "' removed")
			end
			relink = true
		elseif street == nil then
			log("message not understood or the road is gone: " .. message:gsub("\t", " "))
		elseif value == "1" and not street.isolated then
			log("'" .. tostring(street.name) .. "' is still joined to the road network: it cannot be marked abandoned")
		else
			choices.abandoned[street.key] = (value == "1") or nil
			log(string.format("'%s' %s", tostring(street.name), value == "1" and "marked abandoned" or "no longer abandoned"))
			changed = true
		end
	end
	if relink then return "links" end
	return changed and "names" or nil
end

-- ---- On the worker thread --------------------------------------------------------------------------------------
-- With the native layer's worker (tf3api.workerStart / workerRun / workerTake) the whole naming pass runs in a
-- Lua state of its own on another thread: this same script is loaded there (worker_pre.lua, worker.lua), is
-- handed the roads as text, and does exactly what finish() does here - it IS finish(), running there. The
-- labels, the export and the messages to the windows go out from the worker directly; what comes back is
-- what this side has to know: each street's key, name, number and state, and the log lines.
-- Without a worker the pass runs here, a slice a frame.
local workerState = "unknown"   -- unknown, ready, off
local workerJobId, workerSubmitted = nil, 0

-- This file's own folder, relative to the game folder ("mods/release/<mod>/content/road_names/"), from the
-- position Lua puts in front of an error message.
local function ownFolder()
	local path
	-- the debug library says it outright, where there is one
	local okDebug, source = pcall(function() return debug.getinfo(1, "S").source end)
	if okDebug and type(source) == "string" and #source > 1 then path = source end
	if path == nil then
		local _, message = pcall(function() error("x") end)
		message = tostring(message)
		path = message:match('^%[string "([^"]+)"%]') or message:match("^(.-):%d+:")
	end
	if path == nil then return nil end
	path = path:gsub("^@", "")
	path = path:gsub("\\", "/")
	if path:sub(1, 3) == "..." then return nil end   -- shortened by Lua: not a usable path
	return path:match("^(.*/)[^/]*$")
end

local function startWorker()
	if workerState ~= "unknown" then return workerState == "ready" end
	workerState = "off"
	local okBridge, bridge = pcall(function() return tf3api end)
	if not okBridge or type(bridge) ~= "table" or type(bridge.workerStart) ~= "function" then return false end
	local okAvailable, available = pcall(bridge.workerAvailable)
	if not okAvailable or available ~= true then
		log("no worker thread in this game build: the naming runs here, a slice a frame")
		return false
	end
	local folder = ownFolder()
	if folder == nil then
		log("could not tell where this mod's files are: the naming runs here, a slice a frame")
		return false
	end
	local files = {}
	for _, name in ipairs({ "worker_pre.lua", "core.lua", "names.lua", "viewer_page.lua", "road_names.script.lua", "worker.lua" }) do
		files[#files + 1] = folder .. name
	end
	local okStart, started, why = pcall(bridge.workerStart, table.concat(files, "\n"))
	if okStart and started == true then
		workerState = "ready"
		log("naming runs on the worker thread from now on")
		return true
	end
	log("the worker thread was not started (" .. tostring(why or started) .. "): the naming runs here, a slice a frame")
	return false
end

-- The roads and everything the pass needs, as text for the worker: a line each.
--   O key=value ...                    counts for the log
--   M index <tab> template             a road template's name
--   G n0 n1 x0 y0 z0 x1 y1 z1 tx0 ty0 tx1 ty1 len w sp oneway lanes template-index kind
--   W x y <tab> name                   a town        P x y   a railway station (Q n = stations of all kinds)
--   then the player's choices and the remembered names, as serializeChoices writes them
local function serializeInput(command)
	local lines = { "O failed=" .. failed .. " excluded=" .. excluded }
	if command ~= nil then lines[#lines + 1] = "X " .. command end
	local templateIndex, templateCount = {}, 0
	for _, seg in ipairs(segs) do
		breathe()
		local ti = templateIndex[seg.tmpl]
		if ti == nil then
			templateCount = templateCount + 1
			ti = templateCount
			templateIndex[seg.tmpl] = ti
			lines[#lines + 1] = "M " .. ti .. "\t" .. tostring(seg.tmpl)
		end
		lines[#lines + 1] = string.format("G %d %d %.2f %.2f %.2f %.2f %.2f %.2f %.3f %.3f %.3f %.3f %.2f %.2f %.2f %d %d %d %s",
			tonumber(seg.n0) or 0, tonumber(seg.n1) or 0, seg.x0, seg.y0, seg.z0 or 0, seg.x1, seg.y1, seg.z1 or 0,
			seg.tx0 or 0, seg.ty0 or 0, seg.tx1 or 0, seg.ty1 or 0, seg.len or 0, seg.w or 0, seg.sp or 0, seg.oneway or 0,
			seg.dirLanes or -1, ti, (tostring(seg.kind or ""):gsub("%s", "_")))
	end
	for _, town in ipairs(linkTowns or readTowns()) do
		lines[#lines + 1] = string.format("W %.2f %.2f\t%s", town.x, town.y, (tostring(town.name):gsub("[\t\n]", " ")))
	end
	for _, station in ipairs(readStations()) do lines[#lines + 1] = string.format("P %.2f %.2f", station.x, station.y) end
	lines[#lines + 1] = "Q " .. stationsSeen
	lines[#lines + 1] = serializeChoices()
	return table.concat(lines, "\n")
end

-- What the game's side needs back from a pass, as text: a line a street
--   S id <tab> key <tab> name <tab> number <tab> flags (i isolated, p part of another road)
-- then P <the postcode plan>, J <the junctions, lines joined by \30>, L <a log line>.
local function serializeOutput(streets)
	local lines = {}
	for index, s in ipairs(streets) do
		lines[#lines + 1] = string.format("S %d\t%s\t%s\t%s\t%s", index, s.key, tostring(s.name or ""), tostring(s.ref or ""),
			(s.isolated and "i" or "") .. (s.partOf ~= nil and "p" or ""))
	end
	if postcodePlan ~= nil then lines[#lines + 1] = "P " .. core.postcodePlanToText(postcodePlan) end
	if junctionsText ~= nil then lines[#lines + 1] = "J " .. (junctionsText:gsub("\n", "\30")) end
	for _, text in ipairs(WORKER_LOG or {}) do lines[#lines + 1] = "L " .. (tostring(text):gsub("\n", " ")) end
	return table.concat(lines, "\n")
end

-- In the worker: one job. The text is what serializeInput wrote.
local finishPass   -- finish(), defined further down
local function workerJob(input)
	inWorker = true
	breathe = function() end
	WORKER_LOG = {}
	core = core or loadModule("core.lua")
	names = names or loadModule("names.lua")
	local command = nil
	local templates, towns, stations, choiceLines = {}, {}, {}, {}
	segs, failed, excluded, stationsSeen = {}, 0, 0, 0
	for line in tostring(input):gmatch("[^\n]+") do
		local kind = line:sub(1, 2)
		if kind == "G " then
			local v = {}
			for value in line:gmatch("%S+") do v[#v + 1] = value end
			local lanes = tonumber(v[18])
			segs[#segs + 1] = { n0 = tonumber(v[2]), n1 = tonumber(v[3]), x0 = tonumber(v[4]), y0 = tonumber(v[5]), z0 = tonumber(v[6]),
				x1 = tonumber(v[7]), y1 = tonumber(v[8]), z1 = tonumber(v[9]), tx0 = tonumber(v[10]), ty0 = tonumber(v[11]),
				tx1 = tonumber(v[12]), ty1 = tonumber(v[13]), len = tonumber(v[14]), w = tonumber(v[15]), sp = tonumber(v[16]),
				oneway = tonumber(v[17]), dirLanes = (lanes ~= nil and lanes >= 0) and lanes or nil, tmpl = templates[tonumber(v[19])] or "",
				kind = v[20] or "" }
		elseif kind == "M " then
			local index, name = line:match("^M (%d+)\t(.*)$")
			if index ~= nil then templates[tonumber(index)] = name end
		elseif kind == "W " then
			local x, y, name = line:match("^W (%S+) (%S+)\t(.*)$")
			if x ~= nil then towns[#towns + 1] = { name = name, x = tonumber(x), y = tonumber(y) } end
		elseif kind == "P " then
			local x, y = line:match("^P (%S+) (%S+)$")
			if x ~= nil then stations[#stations + 1] = { x = tonumber(x), y = tonumber(y) } end
		elseif kind == "Q " then
			stationsSeen = tonumber(line:sub(3)) or 0
		elseif kind == "O " then
			failed, excluded = tonumber(line:match("failed=(%d+)")) or 0, tonumber(line:match("excluded=(%d+)")) or 0
		elseif kind == "X " then
			command = line:sub(3)
		else
			choiceLines[#choiceLines + 1] = line
		end
	end
	if command == "export" then
		-- the map page, from the pass this state did last
		WORKER_LOG = {}
		writeMapPage()
		return serializeOutput({})
	end
	choices = { abandoned = {}, names = {}, types = {}, styles = {}, cities = {}, joins = {}, splits = {} }
	remembered = { names = {}, refs = {} }
	restoreChoices(table.concat(choiceLines, "\n"), true)
	workerTowns, workerStations, linkTowns = towns, stations, towns
	linkJob = core.startLinks(segs, towns, names, activeCities())
	while not linkJob.done do linkJob:step() end
	linkTime, linkFrames = 0, 0
	finishPass()
	return serializeOutput(lastStreets)
end

-- On the game's side: what a finished worker job says. Returns false when the text is not a pass's result.
local function applyWorkerOutput(text)
	local streets = {}
	local newNames, newRefs = {}, {}
	for line in tostring(text):gmatch("[^\n]+") do
		local kind = line:sub(1, 2)
		if kind == "S " then
			local fields = {}
			for value in (line:sub(3) .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = value end
			local index = tonumber(fields[1])
			if index ~= nil and fields[2] ~= nil then
				local flags = fields[5] or ""
				streets[index] = { key = fields[2], name = fields[3] or "", ref = (fields[4] ~= nil and fields[4] ~= "") and fields[4] or nil,
					isolated = flags:find("i", 1, true) ~= nil or nil, partOf = flags:find("p", 1, true) ~= nil and 0 or nil }
				newNames[fields[2]], newRefs[fields[2]] = streets[index].name, streets[index].ref
			end
		elseif kind == "P " then
			postcodePlan, postcodeText = nil, line:sub(3)
		elseif kind == "J " then
			junctionsText = line:sub(3):gsub("\30", "\n")
		elseif kind == "L " then
			local line2 = line:sub(3):gsub("^%[" .. MOD_ID .. "%] ", "")
			if not (quiet and line2:sub(1, 2) == "  ") then log(line2) end
		end
	end
	if #streets == 0 then return false end
	lastStreets = streets
	remembered = { names = newNames, refs = newRefs }
	return true
end

-- Runs a long piece of work a slice at a time: each call does up to SLICE_SECONDS of it. The work runs in a
-- coroutine and the long loops in core.lua (and the ones below that call breathe) give way when the slice is
-- used up. Returns true when the work is finished.
local sliced, sliceEnd, sliceChecks = nil, 0, 0
local startedJob = nil   -- the links job while it is being set up
local slicedFrames, slicedTime = 0, 0

breathe = function()
	sliceChecks = sliceChecks + 1
	if sliceChecks % 32 ~= 0 then return end   -- the clock is not free either
	if clock() < sliceEnd then return end
	-- only from inside the work's own coroutine (Lua 5.2 also reports the main one, with a second value)
	local running, isMain = coroutine.running()
	if running ~= nil and not isMain then coroutine.yield() end
end

local function runSliced(work)
	if sliced == nil then
		sliced = coroutine.create(work)
		slicedFrames, slicedTime = 0, 0
	end
	local started = clock()
	sliceEnd = started + SLICE_SECONDS
	core.breathe = breathe
	local ok, err = coroutine.resume(sliced)
	core.breathe = nil
	slicedFrames, slicedTime = slicedFrames + 1, slicedTime + (clock() - started)
	if not ok then
		sliced = nil
		error(err, 0)
	end
	if coroutine.status(sliced) == "dead" then
		sliced = nil
		return true
	end
	return false
end

local function step()
	calls = calls + 1
	if phase == "failed" then return end
	if phase == "done" then
		local again = handleMessages()
		if again == "links" then
			quiet = true
			linkTowns = linkTowns or readTowns()
			linkJob = nil
			linkTime, linkFrames = 0, 0
			phase = "links"    -- a city changed: which roads link the towns has to be worked out again
			return
		elseif again == "names" then
			quiet = true
			phase = "finish"   -- name and draw again from the segments already read
			return
		end
		watch()
		return
	end
	if phase == "wait" then
		startedAt = startedAt or clock()
		if clock() - startedAt < START_DELAY then return end
		-- the native bridge is optional; say whether this script environment can see it
		local okBridge, bridge = pcall(function() return tf3api end)
		if okBridge and type(bridge) == "table" then
			log("native bridge visible here: API version " .. tostring(bridge.version))
			pcall(bridge.log, "road_names: hello from the game-script UI state")
			local okW, wrote, why = pcall(bridge.writeFile, "bridge_test.txt", "written by tf3api_road_names through the native bridge\n")
			log("native bridge writeFile test: " .. tostring(okW and wrote) .. (why and (" (" .. tostring(why) .. ")") or ""))
		else
			log("native bridge not visible in this script environment")
		end
		core = loadModule("core.lua")
		names = loadModule("names.lua")
		if pendingSaved ~= nil then
			local counts = restoreChoices(pendingSaved, not names.ignoreSavedData)
			lastSavedText = names.ignoreSavedData and nil or pendingSaved
			log(string.format("from the save: %d renamed roads, %d road types, %d label styles, %d abandoned, %d cities, %d road names%s",
				counts.n, counts.t, counts.s, counts.a, counts.c, counts.r, names.ignoreSavedData and " (generated names not used: ignoreSavedData is on)" or ""))
			pendingSaved = nil
		end
		local source
		entities, source = listStreetSegments()
		signature = networkSignature(entities)
		phase = "read"
		return
	end
	if phase == "read" then
		local last = math.min(count(entities), cursor + SEGMENTS_PER_FRAME - 1)
		for i = cursor, last do
			local ok, seg = pcall(readSegment, entities[i])
			if ok and seg == false then
				-- not a road (see EXCLUDED_TEMPLATES)
			elseif ok and seg ~= nil then
				segs[#segs + 1] = seg
			else
				failed = failed + 1
				if firstError == nil and not ok then firstError = tostring(seg) end
			end
		end
		cursor = last + 1
		if cursor > count(entities) then
			-- next: which roads link the towns (one shortest-path run per frame)
			linkTowns = readTowns()
			linkJob = nil
			linkTime, linkFrames = 0, 0
			phase = "links"
		end
		return
	end
	if phase == "links" and startWorker() then
		phase = "finish"   -- the worker works the links out itself
		return
	end
	if phase == "links" then
		local t0 = clock()
		if linkJob == nil then
			-- setting the job up walks every segment: a slice at a time as well
			-- (the result is kept outside this function: the work started on an earlier frame)
			if runSliced(function() startedJob = core.startLinks(segs, linkTowns, names, activeCities()) end) then
				linkJob, startedJob = startedJob, nil
			end
		else
			local done = linkJob.done or linkJob:step()
			if done then phase = "finish" end
		end
		linkTime, linkFrames = linkTime + (clock() - t0), linkFrames + 1
		return
	end
	if phase == "finish" and startWorker() then
		-- hand the pass to the worker: put the roads into text (a slice a frame), then wait for its answer
		if workerJobId == nil then
			if runSliced(function() startedJob = serializeInput(nil) end) then
				local text = startedJob
				startedJob = nil
				local okRun, id = pcall(tf3api.workerRun, text)
				if okRun and type(id) == "number" then
					workerJobId, workerSubmitted = id, clock()
				else
					log("the worker did not take the job: the naming runs here this time")
					workerState = "off"
				end
			end
			return
		end
		local okTake, id, succeeded, text = pcall(tf3api.workerTake)
		if okTake and id == workerJobId then
			workerJobId = nil
			if succeeded == true and applyWorkerOutput(text) then
				saveToGame()
				log(string.format("named on the worker thread; the answer came after %.0f ms", (clock() - workerSubmitted) * 1000))
				phase = "done"
			else
				log("the worker's pass failed (" .. tostring(text):sub(1, 300) .. "): the naming runs here from now on")
				workerState = "off"
			end
		elseif clock() - workerSubmitted > 60 then
			workerJobId = nil
			log("no answer from the worker after a minute: the naming runs here from now on")
			workerState = "off"
		end
		return
	end
	if phase == "finish" then
		if runSliced(finish) then
			phase = "done"
			if slicedFrames > 1 then
				log(string.format("naming spread over %d frames, %.1f ms of work in the longest slice allowed, %.0f ms in all", slicedFrames, SLICE_SECONDS * 1000, slicedTime * 1000))
			end
		end
	end
end

local function guiUpdate(_params, state, _guiState)
	if not stateRead then
		stateRead = true
		local okState, saved = pcall(function() return state:get() end)
		if okState and type(saved) == "table" and type(saved.text) == "string" then pendingSaved = saved.text end
	end
	local ok, err = pcall(step)
	if not ok then
		phase = "failed"
		log("stopped after an error: " .. tostring(err))
	end
end

finishPass = finish
local M = { guiUpdate = guiUpdate, update = update, handleEvent = handleEvent, workerJob = workerJob,
	status = function() return phase, slicedFrames end }   -- for tests and diagnostics
function data() return M end
return M
