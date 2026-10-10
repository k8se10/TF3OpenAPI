-- TF3 Optimizations - road names: pure logic (no game API in this file, so it can be tested outside the game).
--
-- Terms: a SEGMENT is the game's own piece of road between two junction nodes (what the bulldozer removes).
-- A STREET is a chain of segments that carries one name. The game has no street object; this file builds them.

local core = {}

-- ---- Settings ------------------------------------------------------------------------------------------

-- At a junction of three or more segments, two segments continue as the same street when the bend between
-- them is at most this many degrees.
core.MAX_BEND_AT_JUNCTION = 35
-- Where exactly two segments meet (no junction, just a joint in the road) the street carries on through
-- bends up to this many degrees.
core.MAX_BEND_AT_JOINT = 75

-- Road classes, from the lane data: 3 = motorway-like, 2 = main road, 1 = ordinary street.
core.CLASS_MOTORWAY_SPEED = 27   -- m/s (about 100 km/h) and up
core.CLASS_MAIN_WIDTH = 16       -- metres of carriageway and up
core.CLASS_MAIN_SPEED = 19       -- m/s (about 70 km/h) and up

-- ---------------------------------------------------------------------------------------------------------

function core.classOf(seg)
	local speed, width = seg.sp or 0, seg.w or 0
	if speed >= core.CLASS_MOTORWAY_SPEED then return 3 end
	if width >= core.CLASS_MAIN_WIDTH or speed >= core.CLASS_MAIN_SPEED then return 2 end
	return 1
end

-- Position key of a segment: its two end points rounded to half a metre, in a fixed order. The game gives a
-- segment a new id whenever the road is split or rebuilt, so names are tied to this key, not to the id.
function core.segKey(seg)
	local function q(v) return math.floor(v * 2 + 0.5) end
	local a = q(seg.x0) .. "," .. q(seg.y0) .. "," .. q(seg.z0 or 0)
	local b = q(seg.x1) .. "," .. q(seg.y1) .. "," .. q(seg.z1 or 0)
	if a > b then a, b = b, a end
	return a .. "|" .. b
end

local function unit(x, y)
	local l = math.sqrt(x * x + y * y)
	if l < 1e-6 then return 0, 0, false end
	return x / l, y / l, true
end

-- Direction in which a segment leaves the given node (unit vector). Tangents point along the segment from
-- node0 to node1 at both ends; if a tangent is missing the straight line between the end points is used.
local function outgoing(seg, atNode0)
	local dx, dy, ok
	if atNode0 then
		dx, dy, ok = unit(seg.tx0 or 0, seg.ty0 or 0)
	else
		dx, dy, ok = unit(-(seg.tx1 or 0), -(seg.ty1 or 0))
	end
	if ok then return dx, dy end
	if atNode0 then
		dx, dy = unit(seg.x1 - seg.x0, seg.y1 - seg.y0)
	else
		dx, dy = unit(seg.x0 - seg.x1, seg.y0 - seg.y1)
	end
	return dx, dy
end

-- Union-find over segment indices.
local function find(parent, i)
	while parent[i] ~= i do
		parent[i] = parent[parent[i]]
		i = parent[i]
	end
	return i
end

local function union(parent, a, b)
	local ra, rb = find(parent, a), find(parent, b)
	if ra ~= rb then
		if ra < rb then parent[rb] = ra else parent[ra] = rb end
	end
end

-- Groups segments into streets.
--   segs: array of { n0, n1, x0, y0, z0, x1, y1, z1, tx0, ty0, tx1, ty1, len, w, sp, ... }
-- Returns: streets (array of { segs = {indices}, len, cls, x, y, key }), streetOf (segment index -> street index).
function core.group(segs)
	local parent, cls = {}, {}
	for i, seg in ipairs(segs) do
		parent[i] = i
		cls[i] = core.classOf(seg)
	end

	-- what meets at each node
	local atNode = {}
	for i, seg in ipairs(segs) do
		for side = 0, 1 do
			local node = side == 0 and seg.n0 or seg.n1
			if node ~= nil then
				local dx, dy = outgoing(seg, side == 0)
				local list = atNode[node]
				if list == nil then
					list = {}
					atNode[node] = list
				end
				list[#list + 1] = { i = i, dx = dx, dy = dy }
			end
		end
	end

	local cosJunction = -math.cos(math.rad(core.MAX_BEND_AT_JUNCTION))
	local cosJoint = -math.cos(math.rad(core.MAX_BEND_AT_JOINT))

	for _, list in pairs(atNode) do
		local n = #list
		if n == 2 then
			local a, b = list[1], list[2]
			-- a motorway does not turn into a side street at a joint, and the other way round
			local sameKind = (cls[a.i] == 3) == (cls[b.i] == 3)
			if a.i ~= b.i and sameKind and a.dx * b.dx + a.dy * b.dy <= cosJoint then
				union(parent, a.i, b.i)
			end
		elseif n >= 3 then
			-- straightest pairs first; equal class is preferred over a slightly straighter mismatch
			local pairsList = {}
			for p = 1, n - 1 do
				for q = p + 1, n do
					local a, b = list[p], list[q]
					if a.i ~= b.i then
						local dot = a.dx * b.dx + a.dy * b.dy
						if dot <= cosJunction then
							local score = dot
							if cls[a.i] == cls[b.i] then score = score - 0.12 end
							if segs[a.i].tmpl ~= nil and segs[a.i].tmpl == segs[b.i].tmpl then score = score - 0.04 end
							pairsList[#pairsList + 1] = { p = p, q = q, score = score }
						end
					end
				end
			end
			table.sort(pairsList, function(l, r)
				if l.score ~= r.score then return l.score < r.score end
				if l.p ~= r.p then return l.p < r.p end
				return l.q < r.q
			end)
			local used = {}
			for _, pr in ipairs(pairsList) do
				if not used[pr.p] and not used[pr.q] then
					used[pr.p], used[pr.q] = true, true
					union(parent, list[pr.p].i, list[pr.q].i)
				end
			end
		end
	end

	-- collect
	local byRoot, streets, streetOf = {}, {}, {}
	for i = 1, #segs do
		local root = find(parent, i)
		local s = byRoot[root]
		if s == nil then
			s = { segs = {}, len = 0, clsLen = { 0, 0, 0 } }
			byRoot[root] = s
			streets[#streets + 1] = s
		end
		s.segs[#s.segs + 1] = i
		local seg = segs[i]
		local len = seg.len or math.sqrt((seg.x1 - seg.x0) ^ 2 + (seg.y1 - seg.y0) ^ 2)
		s.len = s.len + len
		s.clsLen[cls[i]] = s.clsLen[cls[i]] + len
	end
	for index, s in ipairs(streets) do
		-- class = the one most of the street's length has
		local best = 1
		for c = 2, 3 do
			if s.clsLen[c] > s.clsLen[best] then best = c end
		end
		s.cls = best
		s.clsLen = nil
		-- label position: middle of the segment closest to the street's centre of length; key: smallest segment key
		local cx, cy, key = 0, 0, nil
		for _, i in ipairs(s.segs) do
			local seg = segs[i]
			cx = cx + (seg.x0 + seg.x1) * 0.5
			cy = cy + (seg.y0 + seg.y1) * 0.5
			local k = core.segKey(seg)
			if key == nil or k < key then key = k end
			streetOf[i] = index
		end
		cx, cy = cx / #s.segs, cy / #s.segs
		local bestD
		for _, i in ipairs(s.segs) do
			local seg = segs[i]
			local mx, my = (seg.x0 + seg.x1) * 0.5, (seg.y0 + seg.y1) * 0.5
			local d = (mx - cx) ^ 2 + (my - cy) ^ 2
			if bestD == nil or d < bestD then
				bestD = d
				s.x, s.y = mx, my
			end
		end
		s.key = key
	end
	return streets, streetOf
end

-- ---- Names ---------------------------------------------------------------------------------------------

-- Small string hash without bit operations (works the same in Lua 5.1 and 5.2).
function core.hash(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 2147483647
	end
	return h
end

-- Gives every street a name. Deterministic: the same street (same position key) gets the same name on every
-- run, as long as the name lists do not change.
--   streets: from core.group     towns: array of { name, x, y }     lists: road_names/names.lua
--   keep:    optional map street key -> name that must be kept (names already saved / chosen by the player)
function core.name(streets, towns, lists, keep)
	keep = keep or {}
	local used, usedBase = {}, {}
	for _, name in pairs(keep) do used[name] = true end

	local function nearestTownDistance(x, y)
		local best
		for _, town in ipairs(towns or {}) do
			local d = math.sqrt((town.x - x) ^ 2 + (town.y - y) ^ 2)
			if best == nil or d < best then best = d end
		end
		return best
	end

	-- longest streets first, so the best names go to the streets that matter and results are stable
	local order = {}
	for i = 1, #streets do order[i] = i end
	table.sort(order, function(a, b)
		if streets[a].len ~= streets[b].len then return streets[a].len > streets[b].len end
		return streets[a].key < streets[b].key
	end)

	local motorways = 0
	for _, index in ipairs(order) do
		local s = streets[index]
		local kept = keep[s.key]
		if kept ~= nil then
			s.name = kept
		elseif s.cls == 3 then
			-- route numbers for motorway-like roads, lowest numbers for the longest
			repeat
				motorways = motorways + 1
				s.name = lists.motorwayPrefix .. tostring(motorways)
			until not used[s.name]
		else
			local distance = nearestTownDistance(s.x, s.y)
			local inTown = distance ~= nil and distance < lists.townRadius
			local suffixes
			if s.cls == 2 then
				suffixes = inTown and lists.suffixMainTown or lists.suffixMainCountry
			elseif s.len < lists.shortStreet then
				suffixes = lists.suffixShort
			else
				suffixes = inTown and lists.suffixTown or lists.suffixCountry
			end
			local h = core.hash(s.key)
			local nBase, nSuffix = #lists.base, #suffixes
			local suffix = suffixes[math.floor(h / 7919) % nSuffix + 1]
			local name
			-- first choice: a base word no other street uses yet ("Poplar Street" and "Poplar Row" side by side reads badly)
			for attempt = 0, nBase - 1 do
				local base = lists.base[(h + attempt) % nBase + 1]
				if not usedBase[base] and not used[base .. " " .. suffix] then
					name = base .. " " .. suffix
					usedBase[base] = true
					break
				end
			end
			-- every base word is in use: reuse one with an ending that makes the full name unique
			if name == nil then
				for attempt = 0, nBase * nSuffix - 1 do
					local base = lists.base[(h + attempt) % nBase + 1]
					local candidate = base .. " " .. suffixes[(math.floor(h / 7919) + math.floor(attempt / nBase)) % nSuffix + 1]
					if not used[candidate] then
						name = candidate
						break
					end
				end
			end
			if name == nil then
				-- every combination is taken (a very large map): number them
				local base = lists.base[h % nBase + 1] .. " " .. suffixes[h % nSuffix + 1]
				local n = 2
				while used[base .. " " .. n] do n = n + 1 end
				name = base .. " " .. n
			end
			s.name = name
		end
		used[s.name] = true
	end
	return streets
end

return core
