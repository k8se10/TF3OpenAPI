-- TF3OpenAPI - road names: pure logic (no game API in this file, so it can be tested outside the game).
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

-- Road classes: 3 = motorway-like, 2 = main road, 1 = ordinary street. Decided from the road template's name
-- first, because the game's templates say what they are (".../street/highway/highway_new_large",
-- ".../town/town_new_medium", ".../country/country_old_small") and a segment's width includes its pavements,
-- so width alone puts every small town street among the main roads. Width and speed are the fallback for
-- templates (from mods) whose names say nothing. Seen on build 40408: small roads are 14-16 m wide overall,
-- medium 24 m, large 32 m; motorway templates run at 27.8-33.3 m/s.
core.CLASS_MOTORWAY_WORDS = { "/highway/", "motorway", "autobahn", "freeway" }
core.CLASS_MAIN_WORDS = { "_medium", "_large", "_xlarge", "lane" }      -- "lane" as in "five_lane"
core.CLASS_STREET_WORDS = { "_small", "_xsmall" }
core.CLASS_MOTORWAY_SPEED = 27   -- m/s (about 100 km/h) and up, when the name says nothing
core.CLASS_MAIN_WIDTH = 20       -- metres overall and up, when the name says nothing

-- ---------------------------------------------------------------------------------------------------------

local function hasWord(text, words)
	for _, word in ipairs(words) do
		if string.find(text, word, 1, true) then return true end
	end
	return false
end

function core.classOf(seg)
	local name = string.lower(tostring(seg.tmpl or ""))
	if hasWord(name, core.CLASS_MOTORWAY_WORDS) then return 3 end
	if hasWord(name, core.CLASS_MAIN_WORDS) then return 2 end
	if hasWord(name, core.CLASS_STREET_WORDS) then return 1 end
	if (seg.sp or 0) >= core.CLASS_MOTORWAY_SPEED then return 3 end
	if (seg.w or 0) >= core.CLASS_MAIN_WIDTH then return 2 end
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
-- Returns: streets (array of { segs = {indices}, len, cls, x, y, key }), streetOf (segment index -> street index),
--          routeJoints (pairs of street indices where one road carries on at a different standard).
function core.group(segs)
	local parent, cls, joints = {}, {}, {}
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
			if a.i ~= b.i and a.dx * b.dx + a.dy * b.dy <= cosJoint then
				if sameKind then
					union(parent, a.i, b.i)
				else
					-- the road carries on, but changes between ordinary and motorway standard: two streets, one route
					joints[#joints + 1] = { a.i, b.i }
				end
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
	-- joints as pairs of streets
	local routeJoints = {}
	for _, joint in ipairs(joints) do
		local a, b = streetOf[joint[1]], streetOf[joint[2]]
		if a ~= b then routeJoints[#routeJoints + 1] = { a, b } end
	end
	return streets, streetOf, routeJoints
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

-- Gives every street a name and, where it earns one, a road number - following how British roads work:
--
--   * A road's NAME and its NUMBER are separate things. Streets have names; classified routes also carry a
--     number (A206 runs along streets that each have their own name). Motorways are known by number only.
--   * Numbers are zonal. The map is divided into zones fanning out clockwise from north around the hub town
--     (the largest town - the map's "London"); the first digit of a number is the zone the road lies in.
--   * Shorter numbers mean more important roads: in each zone the longest main road is A<zone>, the next ten
--     are A<zone>0-A<zone>9, the rest get three digits. B roads get three, then four digits. Motorways are
--     M<zone>, then M<zone>0-M<zone>9.
--   * A motorway-standard stretch that an A road runs into and out of is that road's motorway section: A1(M).
--   * One- and two-digit A roads are the primary routes (green signs); longer numbers are non-primary.
--   * Names: every town has a High Street; a main road is usually named after the town it leads to
--     ("London Road" is the road to London); everything else gets a generated name.
--
-- Deterministic: the same road network gives the same names and numbers on every run.
--   streets: from core.group        towns: array of { name, x, y }      lists: road_names/names.lua
--   keep:    optional map street key -> name that must be kept (already saved / chosen by the player)
--   segs:    the segment array core.group was given (needed for destination names)
--   joints:  routeJoints from core.group (needed for A(M) sections)
function core.name(streets, towns, lists, keep, segs, joints)
	keep = keep or {}
	towns = towns or {}
	local used, usedBase = {}, {}
	for _, name in pairs(keep) do used[name] = true end

	local function distance(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

	local function nearestTown(x, y, except)
		local best, bestD
		for index, town in ipairs(towns) do
			if index ~= except then
				local d = distance(town.x, town.y, x, y)
				if bestD == nil or d < bestD then best, bestD = index, d end
			end
		end
		return best, bestD
	end

	-- longest streets first, so the best names and lowest numbers go to the streets that matter
	local order = {}
	for i = 1, #streets do order[i] = i end
	table.sort(order, function(a, b)
		if streets[a].len ~= streets[b].len then return streets[a].len > streets[b].len end
		return streets[a].key < streets[b].key
	end)

	-- which town each street belongs to (if any)
	local townOf, inTown = {}, {}
	for index, s in ipairs(streets) do
		local t, d = nearestTown(s.x, s.y)
		townOf[index] = t
		inTown[index] = d ~= nil and d < lists.townRadius
	end

	-- the hub: the town with the most road in it; without towns, the middle of the road network
	local hubX, hubY, hubTown = 0, 0, nil
	if #towns > 0 then
		local roadIn = {}
		for index, s in ipairs(streets) do
			if inTown[index] then roadIn[townOf[index]] = (roadIn[townOf[index]] or 0) + s.len end
		end
		for index = 1, #towns do
			if hubTown == nil or (roadIn[index] or 0) > (roadIn[hubTown] or 0) then hubTown = index end
		end
		hubX, hubY = towns[hubTown].x, towns[hubTown].y
	elseif #streets > 0 then
		for _, s in ipairs(streets) do hubX, hubY = hubX + s.x, hubY + s.y end
		hubX, hubY = hubX / #streets, hubY / #streets
	end

	-- zone 1 starts at north and the zones run clockwise, like the A1..A6 fan around London
	local function zoneOf(s)
		local bearing = math.deg(math.atan2(s.x - hubX, s.y - hubY))
		if bearing < 0 then bearing = bearing + 360 end
		local zone = math.floor(bearing / (360 / lists.zones)) + 1
		if zone > lists.zones then zone = lists.zones end
		return zone
	end

	-- ---- road numbers ----
	local usedRef = {}
	local function take(prefix, zone, counters, digitsPlan)
		-- digitsPlan: list of { digits, first, count } tried in turn, e.g. A: zone alone, zone+1 digit, zone+2 digits
		local n = counters[zone] or 0
		while true do
			n = n + 1
			local rank, number = n, nil
			for _, plan in ipairs(digitsPlan) do
				if rank <= plan.count then
					number = plan.digits == 0 and tostring(zone) or (tostring(zone) .. string.format("%0" .. plan.digits .. "d", plan.first + rank - 1))
					break
				end
				rank = rank - plan.count
			end
			if number == nil then number = tostring(zone) .. tostring(1000 + rank) end
			local ref = prefix .. number
			if not usedRef[ref] then
				usedRef[ref] = true
				counters[zone] = n
				return ref
			end
		end
	end
	local aPlan = { { digits = 0, first = 0, count = 1 }, { digits = 1, first = 0, count = 10 }, { digits = 2, first = 0, count = 100 } }
	local mPlan = { { digits = 0, first = 0, count = 1 }, { digits = 1, first = 0, count = 10 }, { digits = 2, first = 0, count = 100 } }
	local bPlan = { { digits = 2, first = 0, count = 100 }, { digits = 3, first = 0, count = 1000 } }
	local aCount, mCount, bCount = {}, {}, {}

	-- A numbered ROUTE can run along several streets: where a main road becomes motorway-standard for a stretch
	-- and then ordinary again, it is still one route (A1 - A1(M) - A1). Routes are built from the joints
	-- core.group reported; a street that has none is a route on its own.
	local routeOf = {}
	for i = 1, #streets do routeOf[i] = i end
	local function routeRoot(i)
		while routeOf[i] ~= i do
			routeOf[i] = routeOf[routeOf[i]]
			i = routeOf[i]
		end
		return i
	end
	for _, joint in ipairs(joints or {}) do
		local ra, rb = routeRoot(joint[1]), routeRoot(joint[2])
		if ra ~= rb then
			if ra < rb then routeOf[rb] = ra else routeOf[ra] = rb end
		end
	end
	local routes, routeList = {}, {}
	for _, index in ipairs(order) do   -- longest street first: it leads its route
		local s = streets[index]
		local root = routeRoot(index)
		local route = routes[root]
		if route == nil then
			route = { members = {}, len = 0, mainLen = 0, lead = index }
			routes[root] = route
			routeList[#routeList + 1] = route
		end
		route.members[#route.members + 1] = index
		if s.cls >= 2 then route.len = route.len + s.len end
		if s.cls == 2 then route.mainLen = route.mainLen + s.len end
	end
	table.sort(routeList, function(l, r)
		if l.len ~= r.len then return l.len > r.len end
		return streets[l.lead].key < streets[r.lead].key
	end)
	for _, route in ipairs(routeList) do
		local lead = streets[route.lead]
		if route.mainLen > 0 and route.len >= lists.aRoadLength then
			-- an A road; its motorway-standard stretches are the (M) sections of the same number
			local ref = take(lists.aRoadPrefix, zoneOf(lead), aCount, aPlan)
			for _, index in ipairs(route.members) do
				local s = streets[index]
				if s.cls == 2 then s.ref = ref elseif s.cls == 3 then s.ref = ref .. "(M)" end
			end
		elseif route.mainLen == 0 and lead.cls == 3 then
			local ref = take(lists.motorwayPrefix, zoneOf(lead), mCount, mPlan)
			for _, index in ipairs(route.members) do
				if streets[index].cls == 3 then streets[index].ref = ref end
			end
		else
			-- a main road too short for a number; any motorway-standard stub on it still needs an identity
			for _, index in ipairs(route.members) do
				if streets[index].cls == 3 then streets[index].ref = take(lists.motorwayPrefix, zoneOf(streets[index]), mCount, mPlan) end
			end
		end
	end
	for _, index in ipairs(order) do
		local s = streets[index]
		if s.cls == 1 and not inTown[index] and s.len >= lists.bRoadLength then
			s.ref = take(lists.bRoadPrefix, zoneOf(s), bCount, bPlan)
		end
	end

	-- ---- names ----
	-- every town has a High Street: the longest ordinary street close to its centre
	local highStreet = {}
	for _, town in ipairs(towns) do
		for _, index in ipairs(order) do
			local s = streets[index]
			if s.cls ~= 3 and keep[s.key] == nil and not highStreet[index] and s.len <= lists.highStreetMaxLength
				and distance(town.x, town.y, s.x, s.y) < lists.highStreetRadius then
				highStreet[index] = true
				break   -- order is longest first
			end
		end
	end

	-- the town a street leads to: from the street's town, look along the street to its far end, and take the
	-- other town that lies closest to that direction (within lists.destinationAngle degrees)
	local function destination(index)
		local s, from = streets[index], townOf[index]
		if segs == nil or from == nil or #towns < 2 then return nil end
		local fx, fy = towns[from].x, towns[from].y
		local ex, ey, far = nil, nil, 0
		for _, si in ipairs(s.segs) do
			local seg = segs[si]
			for _, p in ipairs({ { seg.x0, seg.y0 }, { seg.x1, seg.y1 } }) do
				local d = distance(fx, fy, p[1], p[2])
				if d > far then ex, ey, far = p[1], p[2], d end
			end
		end
		if ex == nil or far < lists.destinationMinReach then return nil end
		local dx, dy = (ex - fx) / far, (ey - fy) / far
		local best, bestCos = nil, math.cos(math.rad(lists.destinationAngle))
		for other, town in ipairs(towns) do
			if other ~= from then
				local d = distance(fx, fy, town.x, town.y)
				if d > 1 then
					local c = ((town.x - fx) * dx + (town.y - fy) * dy) / d
					if c > bestCos then best, bestCos = other, c end
				end
			end
		end
		return best
	end
	local destinationUsed = {}   -- "<from town>|<name>" so one town does not get two London Roads

	for _, index in ipairs(order) do
		local s = streets[index]
		local kept = keep[s.key]
		if kept ~= nil then
			s.name = kept
		elseif s.cls == 3 then
			s.name = s.ref   -- motorways are known by their number only
		elseif highStreet[index] then
			s.name = lists.highStreet
		else
			local name
			-- main roads and long roads are named after where they go
			if s.cls == 2 or s.len >= lists.destinationMinLength then
				local to = destination(index)
				if to ~= nil then
					local candidate = towns[to].name .. " " .. lists.destinationSuffix
					local slot = tostring(townOf[index]) .. "|" .. candidate
					if not destinationUsed[slot] then
						destinationUsed[slot] = true
						name = candidate
					end
				end
			end
			if name == nil then
				local suffixes
				if s.cls == 2 then
					suffixes = inTown[index] and lists.suffixMainTown or lists.suffixMainCountry
				elseif s.len < lists.shortStreet then
					suffixes = lists.suffixShort
				else
					suffixes = inTown[index] and lists.suffixTown or lists.suffixCountry
				end
				local h = core.hash(s.key)
				local nBase, nSuffix = #lists.base, #suffixes
				local suffix = suffixes[math.floor(h / 7919) % nSuffix + 1]
				-- first choice: a base word no other street uses yet ("Poplar Street" beside "Poplar Row" reads badly)
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
			end
			s.name = name
		end
		used[s.name] = true
	end
	return streets, hubTown
end

return core
