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

-- ---- Roundabouts ---------------------------------------------------------------------------------------

-- A roundabout is a small closed loop of one-way segments, driven in one direction all the way round and
-- roughly circular. Returns ring: segment index -> roundabout number (nil for every other segment).
--   segs need: n0 n1 x0 y0 x1 y1, len, oneway (1 = node0 -> node1, -1 = the other way; 0/nil = not one-way)
core.ROUNDABOUT_MAX_PERIMETER = 500   -- metres
core.ROUNDABOUT_MAX_SEGMENTS = 16
core.ROUNDABOUT_ROUNDNESS = 0.35      -- every node within this share of the mean radius from the centre

function core.findRoundabouts(segs)
	local function ends(i)   -- tail node, head node in the direction of travel
		local seg = segs[i]
		if seg.oneway == 1 then return seg.n0, seg.n1 end
		if seg.oneway == -1 then return seg.n1, seg.n0 end
		return nil
	end
	local function length(i)
		local seg = segs[i]
		return seg.len or math.sqrt((seg.x1 - seg.x0) ^ 2 + (seg.y1 - seg.y0) ^ 2)
	end
	local function headPoint(i)
		local seg = segs[i]
		if seg.oneway == 1 then return seg.x1, seg.y1 end
		return seg.x0, seg.y0
	end
	local leaving = {}   -- node -> one-way segments that start there
	for i = 1, #segs do
		local tail = ends(i)
		if tail ~= nil then
			leaving[tail] = leaving[tail] or {}
			table.insert(leaving[tail], i)
		end
	end
	local function round(path)
		local cx, cy = 0, 0
		for _, i in ipairs(path) do
			local x, y = headPoint(i)
			cx, cy = cx + x, cy + y
		end
		cx, cy = cx / #path, cy / #path
		local radii, mean = {}, 0
		for k, i in ipairs(path) do
			local x, y = headPoint(i)
			radii[k] = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)
			mean = mean + radii[k]
		end
		mean = mean / #path
		if mean < 1 then return false end
		for _, r in ipairs(radii) do
			if math.abs(r - mean) > core.ROUNDABOUT_ROUNDNESS * mean then return false end
		end
		return true
	end
	local ring, count = {}, 0
	for start = 1, #segs do
		local startTail, startHead = ends(start)
		if startTail ~= nil and ring[start] == nil and startTail ~= startHead then
			local path, onPath, found = { start }, { [start] = true }, nil
			local function walk(node, total)
				if found then return end
				for _, nextSeg in ipairs(leaving[node] or {}) do
					if not onPath[nextSeg] and ring[nextSeg] == nil then
						local _, head = ends(nextSeg)
						local newTotal = total + length(nextSeg)
						if newTotal <= core.ROUNDABOUT_MAX_PERIMETER and #path < core.ROUNDABOUT_MAX_SEGMENTS then
							path[#path + 1] = nextSeg
							onPath[nextSeg] = true
							if head == startTail then
								if #path >= 3 and round(path) then
									found = {}
									for k, i in ipairs(path) do found[k] = i end
								end
							else
								walk(head, newTotal)
							end
							onPath[nextSeg] = nil
							path[#path] = nil
							if found then return end
						end
					end
				end
			end
			walk(startHead, length(start))
			if found then
				count = count + 1
				for _, i in ipairs(found) do ring[i] = count end
			end
		end
	end
	return ring, count
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
	-- a roundabout is one street of its own: its segments belong together, and no road is joined into a
	-- single street with a piece of the ring (which road the roundabout belongs to is decided further down)
	local ring = core.findRoundabouts(segs)
	local firstOfRing = {}
	for i = 1, #segs do
		if ring[i] ~= nil then
			if firstOfRing[ring[i]] == nil then firstOfRing[ring[i]] = i else union(parent, firstOfRing[ring[i]], i) end
		end
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
				if ring[i] == nil then list[#list + 1] = { i = i, dx = dx, dy = dy } end
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
		if ring[i] ~= nil then s.roundabout = true end
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

	-- A roundabout is a continuation of one of the roads that meet at it: the most important one (highest
	-- class, then longest). It takes that road's class here and its number and name in core.name
	-- (street.partOf). The road carries on across the roundabout, so the arms of that class on the same line
	-- - beside the main arm (its other carriageway) or opposite it - become one route with it.
	local ringNodes = {}   -- node -> roundabout street
	for index, s in ipairs(streets) do
		if s.roundabout then
			for _, i in ipairs(s.segs) do
				ringNodes[segs[i].n0], ringNodes[segs[i].n1] = index, index
			end
		end
	end
	local arms = {}   -- roundabout street -> list of { street, bearing from the roundabout's centre }
	for i, seg in ipairs(segs) do
		if ring[i] == nil then
			for side = 0, 1 do
				local node = side == 0 and seg.n0 or seg.n1
				local r = node ~= nil and ringNodes[node] or nil
				if r ~= nil then
					local x, y = side == 0 and seg.x0 or seg.x1, side == 0 and seg.y0 or seg.y1
					arms[r] = arms[r] or {}
					table.insert(arms[r], { street = streetOf[i], bearing = math.atan2(y - streets[r].y, x - streets[r].x) })
				end
			end
		end
	end
	for index, s in ipairs(streets) do
		if s.roundabout then
			-- centre of the ring (s.x, s.y is a point on it)
			local cx, cy = 0, 0
			for _, i in ipairs(s.segs) do
				cx, cy = cx + (segs[i].x0 + segs[i].x1) * 0.5, cy + (segs[i].y0 + segs[i].y1) * 0.5
			end
			cx, cy = cx / #s.segs, cy / #s.segs
			local best
			for _, arm in ipairs(arms[index] or {}) do
				local a = streets[arm.street]
				-- bearing recomputed from the real centre
				for _, i in ipairs(a.segs) do
					local seg = segs[i]
					if ringNodes[seg.n0] == index then arm.bearing = math.atan2(seg.y0 - cy, seg.x0 - cx) end
					if ringNodes[seg.n1] == index then arm.bearing = math.atan2(seg.y1 - cy, seg.x1 - cx) end
				end
				if best == nil then
					best = arm
				else
					local b = streets[best.street]
					if a.cls > b.cls or (a.cls == b.cls and (a.len > b.len or (a.len == b.len and a.key < b.key))) then best = arm end
				end
			end
			if best ~= nil then
				s.partOf = best.street
				s.cls = streets[best.street].cls
				routeJoints[#routeJoints + 1] = { index, best.street }
				for _, arm in ipairs(arms[index]) do
					if arm.street ~= best.street and streets[arm.street].cls == s.cls then
						local turn = math.abs(arm.bearing - best.bearing)
						if turn > math.pi then turn = 2 * math.pi - turn end
						if turn <= math.rad(45) or turn >= math.rad(120) then
							routeJoints[#routeJoints + 1] = { index, arm.street }
						end
					end
				end
			end
		end
	end
	return streets, streetOf, routeJoints
end

-- ---- Dual carriageways -----------------------------------------------------------------------------------

-- A motorway is usually built as two roads side by side, one per direction. They are one road with one
-- number, so the two are found and reported as a pair: for each motorway-class street, the other
-- motorway-class street that runs alongside it for most of its length. Where the direction of travel is
-- known for both, they must also run opposite ways; where it is not (the game does not always say), running
-- alongside is enough.
--   segs need: x0 y0 x1 y1, len, oneway (1 = traffic runs node0 -> node1, -1 = the other way, nil/0 = unknown)
-- Returns pairs of street indices, in the same form as the route joints from core.group.
core.CARRIAGEWAY_GAP = 60        -- metres: how far apart the two carriageways may be
core.CARRIAGEWAY_SHARE = 0.5     -- share of the shorter street's length that must run alongside the other

function core.pairCarriageways(streets, segs)
	local cell = core.CARRIAGEWAY_GAP
	local grid, info = {}, {}
	local function cellKey(cx, cy) return cx .. ":" .. cy end
	for index, s in ipairs(streets) do
		if s.cls == 3 then
			for _, si in ipairs(s.segs) do
				local seg = segs[si]
				do
					local known = seg.oneway == 1 or seg.oneway == -1
					local sign = known and seg.oneway or 1
					local dx, dy = seg.x1 - seg.x0, seg.y1 - seg.y0
					local l = math.sqrt(dx * dx + dy * dy)
					if l > 0.01 then
						local entry = { street = index, x = (seg.x0 + seg.x1) * 0.5, y = (seg.y0 + seg.y1) * 0.5,
							dx = dx / l * sign, dy = dy / l * sign, len = seg.len or l, known = known }
						info[#info + 1] = entry
						local key = cellKey(math.floor(entry.x / cell), math.floor(entry.y / cell))
						grid[key] = grid[key] or {}
						table.insert(grid[key], entry)
					end
				end
			end
		end
	end
	-- length of each street that has an opposite-direction neighbour, per neighbouring street
	local alongside, onewayLength = {}, {}
	for _, a in ipairs(info) do
		onewayLength[a.street] = (onewayLength[a.street] or 0) + a.len
		local cx, cy = math.floor(a.x / cell), math.floor(a.y / cell)
		local best, bestD
		for ox = -1, 1 do
			for oy = -1, 1 do
				for _, b in ipairs(grid[cellKey(cx + ox, cy + oy)] or {}) do
					local dot = a.dx * b.dx + a.dy * b.dy
					local alongsideEachOther = dot < -0.7 or (not (a.known and b.known) and dot > 0.7)
					if b.street ~= a.street and alongsideEachOther then
						local d = (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2
						if d <= cell * cell and (bestD == nil or d < bestD) then best, bestD = b.street, d end
					end
				end
			end
		end
		if best ~= nil then
			alongside[a.street] = alongside[a.street] or {}
			alongside[a.street][best] = (alongside[a.street][best] or 0) + a.len
		end
	end
	local pairsOut, done = {}, {}
	for a, others in pairs(alongside) do
		for b, length in pairs(others) do
			local shorter = math.min(onewayLength[a] or 0, onewayLength[b] or 0)
			local key = a < b and (a .. "|" .. b) or (b .. "|" .. a)
			if not done[key] and shorter > 0 and length >= core.CARRIAGEWAY_SHARE * shorter then
				done[key] = true
				pairsOut[#pairsOut + 1] = { math.min(a, b), math.max(a, b) }
			end
		end
	end
	table.sort(pairsOut, function(l, r)
		if l[1] ~= r[1] then return l[1] < r[1] end
		return l[2] < r[2]
	end)
	return pairsOut
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
	local function take(prefix, zone, counters, digitsPlan, firstTier)
		-- digitsPlan: tiers of { digits, first, count }, shortest numbers first, e.g. for A roads: the zone digit
		-- alone, zone + 1 digit, zone + 2 digits ... A road is given the next free number of its tier
		-- (firstTier, default 1 = the shortest numbers); when a tier is full it moves on to the next longer one.
		for tier = firstTier or 1, #digitsPlan do
			local plan = digitsPlan[tier]
			local key = zone .. ":" .. tier
			local rank = counters[key] or 0
			while rank < plan.count do
				rank = rank + 1
				local number = plan.digits == 0 and tostring(zone) or (tostring(zone) .. string.format("%0" .. plan.digits .. "d", plan.first + rank - 1))
				local ref = prefix .. number
				if not usedRef[ref] then
					usedRef[ref] = true
					counters[key] = rank
					return ref
				end
			end
			counters[key] = rank
		end
		-- every tier is full: keep counting past the longest
		local key = zone .. ":over"
		while true do
			counters[key] = (counters[key] or 0) + 1
			local ref = prefix .. tostring(zone) .. tostring(100000 + counters[key])
			if not usedRef[ref] then
				usedRef[ref] = true
				return ref
			end
		end
	end
	-- An A road's length decides how long a number it may have: the longest roads get the shortest numbers
	-- (lists.aRoadTierLength, longest tier first). Returns the tier a road of this length starts at.
	local function aTier(length)
		for tier, minimum in ipairs(lists.aRoadTierLength) do
			if length >= minimum then return tier end
		end
		return #lists.aRoadTierLength
	end
	local aPlan = { { digits = 0, first = 0, count = 1 }, { digits = 1, first = 0, count = 10 }, { digits = 2, first = 0, count = 100 },
		{ digits = 3, first = 0, count = 1000 }, { digits = 4, first = 0, count = 10000 } }
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
	local allJoints = {}
	for _, joint in ipairs(joints or {}) do allJoints[#allJoints + 1] = joint end
	if segs ~= nil then
		-- the two carriageways of a motorway are one route
		for _, pair in ipairs(core.pairCarriageways(streets, segs)) do allJoints[#allJoints + 1] = pair end
	end
	for _, joint in ipairs(allJoints) do
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
			local ref = take(lists.aRoadPrefix, zoneOf(lead), aCount, aPlan, aTier(route.len))
			for _, index in ipairs(route.members) do
				local s = streets[index]
				if s.cls == 2 then s.ref = ref elseif s.cls == 3 then s.ref = ref .. "(M)" end
			end
		elseif route.mainLen == 0 and lead.cls == 3 and route.len >= lists.motorwayMinLength then
			local ref = take(lists.motorwayPrefix, zoneOf(lead), mCount, mPlan)
			for _, index in ipairs(route.members) do
				if streets[index].cls == 3 then streets[index].ref = ref end
			end
		end
		-- anything else of motorway standard is a slip road or a link at a junction: see below
	end
	-- Slip roads and junction links belong to the motorway they join, not to the A road at their other end.
	-- A slip road here is a street that is short (lists.slipMaxLength, one mile), has no junction along its
	-- own length, and is either built to motorway standard or one-way throughout (the ordinary one-way links
	-- between a motorway's slip roads and a roundabout or side road): it takes the number of the M road it touches, even where the route
	-- rules above had made it part of an A road. A street that is longer, or that other roads join part-way
	-- along, is a road in its own right and keeps what the route rules gave it.
	-- Where a slip road touches several numbered roads the longest wins, and an M road always beats an
	-- A road's motorway section. Repeated so that a slip road made of several streets is covered end to end.
	if segs ~= nil then
		local atNode = {}   -- node -> { street index -> number of that street's segments ending there }
		for index, s in ipairs(streets) do
			for _, si in ipairs(s.segs) do
				for _, n in ipairs({ segs[si].n0, segs[si].n1 }) do
					if n ~= nil then
						atNode[n] = atNode[n] or {}
						atNode[n][index] = (atNode[n][index] or 0) + 1
					end
				end
			end
		end
		local prefix = lists.motorwayPrefix
		local function isMotorwayNumber(ref) return ref ~= nil and ref:sub(1, #prefix) == prefix end
		local function isSlipRoad(index)
			local s = streets[index]
			if s.len > lists.slipMaxLength or s.roundabout then return false end
			if s.cls ~= 3 then
				for _, si in ipairs(s.segs) do
					if segs[si].oneway ~= 1 and segs[si].oneway ~= -1 then return false end
				end
			end
			for _, si in ipairs(s.segs) do
				for _, n in ipairs({ segs[si].n0, segs[si].n1 }) do
					local here = n ~= nil and atNode[n] or nil
					if here ~= nil and (here[index] or 0) >= 2 then   -- a point along the street, not one of its ends
						for other in pairs(here) do
							if other ~= index then return false end   -- another road joins here
						end
					end
				end
			end
			return true
		end
		local slip = {}
		for index in ipairs(streets) do slip[index] = isSlipRoad(index) end
		for _ = 1, 4 do
			local taken, any = {}, false
			for _, index in ipairs(order) do
				local s = streets[index]
				if slip[index] and not isMotorwayNumber(s.ref) then
					local best, bestIsM
					for _, si in ipairs(s.segs) do
						for _, n in ipairs({ segs[si].n0, segs[si].n1 }) do
							for other in pairs(n ~= nil and atNode[n] or {}) do
								local o = streets[other]
								if other ~= index and (o.cls == 3 or o.slipOf ~= nil) and o.ref ~= nil then
									local isM = isMotorwayNumber(o.ref)
									-- an A road's motorway section is only a source for a slip road with no number at all
									if isM or s.ref == nil then
										local better = best == nil or (isM and not bestIsM)
											or (isM == bestIsM and (o.len > streets[best].len or (o.len == streets[best].len and o.key < streets[best].key)))
										if better then best, bestIsM = other, isM end
									end
								end
							end
						end
					end
					if best ~= nil and streets[best].ref ~= s.ref then taken[index] = streets[best].ref end
				end
			end
			for index, ref in pairs(taken) do
				streets[index].ref = ref
				streets[index].slipOf = ref   -- known by this number only, like the motorway itself
				any = true
			end
			if not any then break end
		end
	end
	for _, index in ipairs(order) do
		local s = streets[index]
		-- B roads: the numbered roads below the A roads - ordinary roads long enough to link towns, suburbs
		-- and the local network. Any ordinary road of lists.bRoadLength counts wherever it runs; out in the
		-- country a shorter one (lists.bRoadCountryLength) does too. The longer ones get three digits, the
		-- rest four.
		if s.cls == 1 and s.ref == nil and not s.roundabout
			and (s.len >= lists.bRoadLength or (not inTown[index] and s.len >= lists.bRoadCountryLength)) then
			s.ref = take(lists.bRoadPrefix, zoneOf(s), bCount, bPlan, s.len >= lists.bRoadThreeDigitLength and 1 or 2)
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
		elseif (s.cls == 3 or s.slipOf ~= nil) and s.ref ~= nil then
			s.name = s.ref   -- motorways are known by their number only; so are their slip roads
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
		if s.name ~= "" then used[s.name] = true end
	end
	-- a roundabout carries the number and name of the road it is part of
	for _, st in ipairs(streets) do
		if st.partOf ~= nil and streets[st.partOf] ~= nil and keep[st.key] == nil then
			st.name, st.ref = streets[st.partOf].name, streets[st.partOf].ref
		end
	end
	return streets, hubTown
end

return core
