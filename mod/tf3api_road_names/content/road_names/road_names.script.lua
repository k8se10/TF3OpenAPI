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

local function log(msg)
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
	local width, speed = 0, 0
	local lanes = edge.laneConfigs
	for i = 1, count(lanes) do
		local okLane, lane = pcall(function() return lanes[i] end)
		if okLane and lane ~= nil then
			width = width + (tonumber(lane.width) or 0)
			local s = tonumber(lane.speed) or 0
			if s > speed then speed = s end
		end
	end
	seg.w, seg.sp = width, speed
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

local function finish()
	local t0 = clock()
	local towns = readTowns()
	local streets, streetOf, joints = core.group(segs)
	local _, hubTown = core.name(streets, towns, names, nil, segs, joints)
	local t1 = clock()

	-- export: compact arrays, one row per segment and per street
	local out = { version = 2, towns = towns, hub = hubTown and towns[hubTown].name or "", streets = {}, segments = {}, templates = {} }
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
			round1(seg.w), round1(seg.sp), ti, seg.kind,
		}
	end
	-- Written through the native bridge when it is there (a JSON file beside the game, in tf3api_out); the
	-- game's own userdata writer is the fallback, where the script environment has one.
	local saved, saveErr, savedAs = false, nil, nil
	local okBridge, bridge = pcall(function() return tf3api end)
	if okBridge and type(bridge) == "table" and type(bridge.writeFile) == "function" then
		local okJson, json = pcall(toJson, out)
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
	end
end

local function step()
	calls = calls + 1
	if phase == "done" or phase == "failed" then return end
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
		if cursor > count(entities) then phase = "finish" end
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
