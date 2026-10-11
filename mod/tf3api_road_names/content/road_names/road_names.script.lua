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

local quiet = false   -- on re-scans the detail lines (those starting with two spaces) are left out of the log

local function log(msg)
	if quiet and tostring(msg):sub(1, 2) == "  " then return end
	local text = "[" .. MOD_ID .. "] " .. tostring(msg)
	if not pcall(function() debugPrint(text) end) then print(text) end
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
local choices = { abandoned = {}, names = {}, types = {}, styles = {}, cities = {} }
local lastExport = nil   -- the latest export as JSON text, for writing the map page on request

-- The player's cities plus, during development, the ones listed in names.lua.
local function activeCities()
	local list = {}
	for _, city in ipairs(names.devCities or {}) do list[#list + 1] = city end
	for _, city in ipairs(choices.cities) do list[#list + 1] = city end
	return list
end
local lastStreets = nil                  -- the streets of the latest read, by the id the labels carry
local CHANNEL = "tf3api_road_names"      -- messages from the road window (tf3api.post / take)
local UI_CHANNEL = "tf3api_road_names.ui"  -- messages to the road window
local postcodePlan = nil                 -- core.postcodePlan of the latest read

-- The road window works out the postcode of the spot that was clicked; it needs the plan for that.
local function sendPostcodes()
	if postcodePlan == nil then return end
	local okBridge, bridge = pcall(function() return tf3api end)
	if okBridge and type(bridge) == "table" and type(bridge.post) == "function" then
		pcall(bridge.post, UI_CHANNEL, "postcodes\t" .. core.postcodePlanToText(postcodePlan))
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

local function readTowns()
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
				if i > 1 then out[#out + 1] = "," end
				toJson(value[i], out)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			local first = true
			for k, v in pairs(value) do
				if not first then out[#out + 1] = "," end
				first = false
				toJson(tostring(k), out)
				out[#out + 1] = ":"
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
local function sendLabels(streets)
	local okBridge, bridge = pcall(function() return tf3api end)
	if not okBridge or type(bridge) ~= "table" or type(bridge.setRoadLabels) ~= "function" then
		log("names are not drawn in the world: the native layer (tf3api) is not installed or is too old")
		return
	end
	local lines = {}
	for index, s in ipairs(streets) do
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
			lines[#lines + 1] = string.format("S\t%s\t%d\t%s\t%s\t%d\t%s", shield, s.cls, ref, name, index, flags)
			for _, si in ipairs(s.segs) do
				local seg = segs[si]
				lines[#lines + 1] = string.format("G %.1f %.1f %.1f %.1f %.1f %.1f", seg.x0, seg.y0, seg.z0 or 0, seg.x1, seg.y1, seg.z1 or 0)
			end
		end
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
	local towns = linkTowns or readTowns()
	local streets, streetOf, joints = core.group(segs)
	core.markIsolated(streets, segs)
	for _, s in ipairs(streets) do
		-- the choice only applies while the road is cut off; joined up again, it is an ordinary road
		if choices.abandoned[s.key] and s.isolated then s.abandoned = true end
		s.typeChoice = choices.types[s.key]
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
	if linkJob ~= nil then
		local a, b = 0, 0
		for _, link in ipairs(linkJob.links or {}) do if link.kind == "A" then a = a + 1 else b = b + 1 end end
		log(string.format("links between towns: %d A, %d B, worked out in %.0f ms over %d frames", a, b, linkTime * 1000, linkFrames))
	end
	local t1 = clock()

	-- export: compact arrays, one row per segment and per street
	local out = { version = 2, towns = towns, hub = hubTown and towns[hubTown].name or "", streets = {}, segments = {}, templates = {} }
	out.postcodes = { sector = postcodePlan.sector, places = {} }
	for i, p in ipairs(postcodePlan.places) do out.postcodes.places[i] = { outward = p.outward, x = round1(p.x), y = round1(p.y), name = p.name } end
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
		}
	end
	sendLabels(streets)
	-- Written through the native bridge when it is there (a JSON file beside the game, in tf3api_out); the
	-- game's own userdata writer is the fallback, where the script environment has one.
	local saved, saveErr, savedAs = false, nil, nil
	local okBridge, bridge = pcall(function() return tf3api end)
	if okBridge and type(bridge) == "table" and type(bridge.writeFile) == "function" then
		local okJson, json = pcall(toJson, out)
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
		if message == "hello" then
			sendPostcodes()   -- the road window has (re)started and asks for what it needs
		elseif message == "export" then
			writeMapPage()
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

local function step()
	calls = calls + 1
	if phase == "failed" then return end
	if phase == "done" then
		local again = handleMessages()
		if again == "links" then
			quiet = true
			linkJob = core.startLinks(segs, linkTowns or readTowns(), names, activeCities())
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
			linkJob = core.startLinks(segs, linkTowns, names, activeCities())
			linkTime, linkFrames = 0, 0
			phase = "links"
		end
		return
	end
	if phase == "links" then
		local t0 = clock()
		local done = linkJob.done or linkJob:step()
		linkTime, linkFrames = linkTime + (clock() - t0), linkFrames + 1
		if done then phase = "finish" end
		return
	end
	if phase == "finish" then
		phase = "done"
		finish()
	end
end

local function guiUpdate()
	local ok, err = pcall(step)
	if not ok then
		phase = "failed"
		log("stopped after an error: " .. tostring(err))
	end
end

local M = { guiUpdate = guiUpdate }
function data() return M end
return M
