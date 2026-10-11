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

-- ordinaryGap: nil = pair motorway-class streets (the default). A number = pair the other streets instead,
-- with that distance between the carriageways; there only one-way segments count and the two must run
-- opposite ways, since an ordinary two-way road beside another is simply another road.
function core.pairCarriageways(streets, segs, ordinaryGap)
	local motorways = ordinaryGap == nil
	local cell = ordinaryGap or core.CARRIAGEWAY_GAP
	local grid, info = {}, {}
	local function cellKey(cx, cy) return cx .. ":" .. cy end
	for index, s in ipairs(streets) do
		if (motorways and s.cls == 3) or (not motorways and s.cls ~= 3 and not s.roundabout) then
			for _, si in ipairs(s.segs) do
				local seg = segs[si]
				if motorways or seg.oneway == 1 or seg.oneway == -1 then
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
					local alongsideEachOther = dot < -0.7 or (motorways and not (a.known and b.known) and dot > 0.7)
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

-- ---- Links between towns -----------------------------------------------------------------------------------

-- What makes a road an A road or a B road is what it connects, not how wide it is: A roads are the major
-- roads between important places, B roads the lesser links between towns, suburbs and the local network.
-- So the classification starts from the towns: the quickest drive between pairs of towns is worked out over
-- the road network (one-way roads respected, faster roads preferred), and the roads those drives use are
-- the links.
--   * primary towns: the biggest towns (the hub and the top lists.primaryTownShare of the rest)
--   * A links: each primary town to its nearest lists.primaryLinks primary towns
--   * radials: from the hub to primary towns in up to lists.zones different directions - the single-digit
--     A roads, which also bound the numbering zones
--   * B links: every town to its nearest lists.localLinks towns, where that is not already an A link
--
-- The search is one shortest-path run per town, which is too much for one frame on a big map, so it is a job:
--   local job = core.startLinks(segs, towns, lists);  repeat job:step() until job.done
-- job.links then lists { a, b, kind = "A"/"B", radial, primary, segs = {segment indices in driving order},
-- len, weight }, most important first; job.hubTown is the hub; job.size the road length in each town.
function core.startLinks(segs, towns, lists)
	local job = { done = false, links = {}, cursor = 1, sources = {}, targets = {}, size = {}, hubTown = nil }
	function job.step(self) return core.stepLinks(self) end
	if towns == nil or #towns < 2 then
		job.done = true
		return job
	end
	local cell = lists.townRadius
	local function cellOf(v) return math.floor(v / cell) end
	local townGrid = {}
	for t, town in ipairs(towns) do
		local key = cellOf(town.x) .. ":" .. cellOf(town.y)
		townGrid[key] = townGrid[key] or {}
		table.insert(townGrid[key], t)
		job.size[t] = 0
	end
	local adjacent, access, accessD = {}, {}, {}
	local function add(from, seg, to, cost)
		local list = adjacent[from]
		if list == nil then
			list = {}
			adjacent[from] = list
		end
		list[#list + 1] = { seg, to, cost }
	end
	for i, seg in ipairs(segs) do
		if seg.n0 ~= nil and seg.n1 ~= nil then
			local len = seg.len or math.sqrt((seg.x1 - seg.x0) ^ 2 + (seg.y1 - seg.y0) ^ 2)
			local cost = len / math.max(seg.sp or 0, 5)
			if seg.oneway ~= -1 then add(seg.n0, i, seg.n1, cost) end
			if seg.oneway ~= 1 then add(seg.n1, i, seg.n0, cost) end
			local mx, my = (seg.x0 + seg.x1) * 0.5, (seg.y0 + seg.y1) * 0.5
			local ordinary = core.classOf(seg) ~= 3
			local nearest, nearestD
			for ox = -1, 1 do
				for oy = -1, 1 do
					for _, t in ipairs(townGrid[(cellOf(mx) + ox) .. ":" .. (cellOf(my) + oy)] or {}) do
						local town = towns[t]
						local d = math.sqrt((mx - town.x) ^ 2 + (my - town.y) ^ 2)
						if d < cell and (nearestD == nil or d < nearestD) then nearest, nearestD = t, d end
						-- where a drive to or from this town starts: the ordinary road junction closest to its centre
						if ordinary then
							local d0 = (seg.x0 - town.x) ^ 2 + (seg.y0 - town.y) ^ 2
							local d1 = (seg.x1 - town.x) ^ 2 + (seg.y1 - town.y) ^ 2
							if accessD[t] == nil or d0 < accessD[t] then access[t], accessD[t] = seg.n0, d0 end
							if d1 < accessD[t] then access[t], accessD[t] = seg.n1, d1 end
						end
					end
				end
			end
			if nearest ~= nil then job.size[nearest] = job.size[nearest] + len end
		end
	end
	job.adjacent, job.access, job.segs = adjacent, access, segs

	-- the hub and the primary towns
	local bySize = {}
	for t = 1, #towns do bySize[t] = t end
	table.sort(bySize, function(a, b)
		if job.size[a] ~= job.size[b] then return job.size[a] > job.size[b] end
		return a < b
	end)
	job.hubTown = bySize[1]
	local primaryCount = math.min(#towns, math.max(lists.zones + 1, math.ceil(#towns * lists.primaryTownShare)))
	local primary = {}
	for rank = 1, primaryCount do primary[bySize[rank]] = true end
	job.primary = primary

	local function nearestTo(t, onlyPrimary)
		local list = {}
		for other = 1, #towns do
			if other ~= t and (not onlyPrimary or primary[other]) and access[other] ~= nil then
				list[#list + 1] = { town = other, d = (towns[other].x - towns[t].x) ^ 2 + (towns[other].y - towns[t].y) ^ 2 }
			end
		end
		table.sort(list, function(a, b)
			if a.d ~= b.d then return a.d < b.d end
			return a.town < b.town
		end)
		return list
	end
	local planned = {}
	local function plan(from, to, kind, radial)
		local key = math.min(from, to) .. "|" .. math.max(from, to)
		if planned[key] ~= nil then return end
		planned[key] = true
		if job.targets[from] == nil then
			job.targets[from] = {}
			job.sources[#job.sources + 1] = from
		end
		table.insert(job.targets[from], { town = to, kind = kind, radial = radial })
	end
	-- radials first: from the hub outwards in different directions
	local hub = job.hubTown
	if access[hub] ~= nil then
		local chosen, apart = {}, math.rad(360 / lists.zones * 0.6)
		for _, entry in ipairs(nearestTo(hub, true)) do
			if #chosen >= lists.zones then break end
			local bearing = math.atan2(towns[entry.town].x - towns[hub].x, towns[entry.town].y - towns[hub].y)
			local clear = true
			for _, other in ipairs(chosen) do
				local turn = math.abs(bearing - other)
				if turn > math.pi then turn = 2 * math.pi - turn end
				if turn < apart then clear = false end
			end
			if clear then
				chosen[#chosen + 1] = bearing
				plan(hub, entry.town, "A", true)
			end
		end
	end
	for t = 1, #towns do
		if primary[t] and access[t] ~= nil then
			local list = nearestTo(t, true)
			for k = 1, math.min(lists.primaryLinks, #list) do plan(t, list[k].town, "A", false) end
		end
	end
	for t = 1, #towns do
		if access[t] ~= nil then
			local list = nearestTo(t, false)
			for k = 1, math.min(lists.localLinks, #list) do plan(t, list[k].town, "B", false) end
		end
	end
	table.sort(job.sources)
	if #job.sources == 0 then job.done = true end
	return job
end

-- One shortest-path run: from the next town to every town it has a link planned to. Returns true when the
-- whole job is done.
function core.stepLinks(job)
	if job.done then return true end
	local from = job.sources[job.cursor]
	job.cursor = job.cursor + 1
	local adjacent, segs = job.adjacent, job.segs
	local wanted, remaining = {}, 0
	for _, target in ipairs(job.targets[from]) do
		local node = job.access[target.town]
		if wanted[node] == nil then
			wanted[node] = true
			remaining = remaining + 1
		end
	end
	-- Dijkstra with a binary heap of { cost, node }
	local best, via, settled = { [job.access[from]] = 0 }, {}, {}
	local heap, size = { { 0, job.access[from] } }, 1
	while size > 0 and remaining > 0 do
		local top = heap[1]
		heap[1] = heap[size]
		heap[size] = nil
		size = size - 1
		local i = 1
		while true do
			local l, r, m = i * 2, i * 2 + 1, i
			if l <= size and heap[l][1] < heap[m][1] then m = l end
			if r <= size and heap[r][1] < heap[m][1] then m = r end
			if m == i then break end
			heap[i], heap[m] = heap[m], heap[i]
			i = m
		end
		local cost, node = top[1], top[2]
		if not settled[node] then
			settled[node] = true
			if wanted[node] then remaining = remaining - 1 end
			for _, edge in ipairs(adjacent[node] or {}) do
				local to, total = edge[2], cost + edge[3]
				if not settled[to] and (best[to] == nil or total < best[to]) then
					best[to] = total
					via[to] = { edge[1], node }
					size = size + 1
					heap[size] = { total, to }
					local k = size
					while k > 1 do
						local parent = math.floor(k / 2)
						if heap[parent][1] <= heap[k][1] then break end
						heap[parent], heap[k] = heap[k], heap[parent]
						k = parent
					end
				end
			end
		end
	end
	for _, target in ipairs(job.targets[from]) do
		local node = job.access[target.town]
		if settled[node] and node ~= job.access[from] then
			local path, len = {}, 0
			while via[node] ~= nil do
				local seg = via[node][1]
				path[#path + 1] = seg
				len = len + (segs[seg].len or math.sqrt((segs[seg].x1 - segs[seg].x0) ^ 2 + (segs[seg].y1 - segs[seg].y0) ^ 2))
				node = via[node][2]
			end
			local ordered = {}
			for k = #path, 1, -1 do ordered[#ordered + 1] = path[k] end
			job.links[#job.links + 1] = { a = from, b = target.town, kind = target.kind, radial = target.radial,
				primary = job.primary[from] and job.primary[target.town] or false,
				segs = ordered, len = len, weight = job.size[from] + job.size[target.town] }
		end
	end
	if job.cursor > #job.sources then
		job.done = true
		job.adjacent, job.access, job.segs = nil, nil, nil
		table.sort(job.links, function(l, r)
			if l.radial ~= r.radial then return l.radial end
			if l.kind ~= r.kind then return l.kind == "A" end
			if l.weight ~= r.weight then return l.weight > r.weight end
			if l.len ~= r.len then return l.len > r.len end
			if l.a ~= r.a then return l.a < r.a end
			return l.b < r.b
		end)
	end
	return job.done
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
--   links:   optional, a finished job from core.startLinks: A and B roads then follow what the roads connect
--   keepRefs: optional map street key -> road number that must be kept, like keep for names
function core.name(streets, towns, lists, keep, segs, joints, links, keepRefs)
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
		if links ~= nil and links.hubTown ~= nil then hubTown = links.hubTown end
		hubX, hubY = towns[hubTown].x, towns[hubTown].y
	elseif #streets > 0 then
		for _, s in ipairs(streets) do hubX, hubY = hubX + s.x, hubY + s.y end
		hubX, hubY = hubX / #streets, hubY / #streets
	end

	-- zone 1 starts at north and the zones run clockwise, like the A1..A6 fan around London
	-- With links between towns, the zones are bounded by the single-digit roads themselves, as in Britain:
	-- the radials from the hub, numbered clockwise from north, and zone N lies between radial N and the next.
	local radialBearings, radialDigit = {}, {}
	if links ~= nil and links.links ~= nil and hubTown ~= nil then
		local list = {}
		for _, link in ipairs(links.links) do
			if link.radial then
				local bearing = math.deg(math.atan2(towns[link.b].x - hubX, towns[link.b].y - hubY))
				if bearing < 0 then bearing = bearing + 360 end
				list[#list + 1] = { town = link.b, bearing = bearing }
			end
		end
		table.sort(list, function(a, b) return a.bearing < b.bearing end)
		if #list >= 2 then
			for k, entry in ipairs(list) do
				radialBearings[k] = entry.bearing
				radialDigit[entry.town] = k
			end
		end
	end
	local function zoneOf(s)
		local bearing = math.deg(math.atan2(s.x - hubX, s.y - hubY))
		if bearing < 0 then bearing = bearing + 360 end
		if #radialBearings >= 2 then
			local zone = #radialBearings   -- before the first radial = the last zone, which wraps past north
			for k = 1, #radialBearings do
				if bearing >= radialBearings[k] then zone = k end
			end
			return zone
		end
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
	-- The short numbers (A1, A10) and motorway numbers are for roads with at least two lanes each way; a road
	-- with one lane each way is an A road of three digits or more at best. True when at least
	-- lists.dualShare of the given streets' length has two lanes per direction. Segments whose lane count is
	-- not known (segment.dirLanes == nil) do not count against the road.
	local function twoLanesEachWay(streetList)
		if segs == nil then return true end
		local total, narrow = 0, 0
		for _, index in ipairs(streetList) do
			for _, si in ipairs(streets[index].segs) do
				local seg = segs[si]
				local len = seg.len or math.sqrt((seg.x1 - seg.x0) ^ 2 + (seg.y1 - seg.y0) ^ 2)
				total = total + len
				if seg.dirLanes ~= nil and seg.dirLanes < 2 then narrow = narrow + len end
			end
		end
		return total == 0 or (total - narrow) >= lists.dualShare * total
	end
	-- A1, A10, A100, A1000. Five-digit A numbers are not given out: they are too rare in real life.
	local aPlan = { { digits = 0, first = 0, count = 1 }, { digits = 1, first = 0, count = 10 }, { digits = 2, first = 0, count = 100 },
		{ digits = 3, first = 0, count = 1000 } }
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
	-- numbers a road already has stay with it, and nobody else gets them
	if keepRefs ~= nil then
		for _, s in ipairs(streets) do
			local ref = keepRefs[s.key]
			if ref ~= nil then
				s.ref = ref
				usedRef[(ref:gsub("%(M%)$", ""))] = true
			end
		end
	end
	-- motorways first: a motorway-standard road long enough for a number of its own (both carriageways
	-- together). Without links between towns the older rule also applies: a motorway-standard stretch that
	-- a wide main road runs into and out of is that road's (M) section, not a motorway of its own.
	local linkedMode = links ~= nil and links.links ~= nil and #links.links > 0
	for _, route in ipairs(routeList) do
		local lead = streets[route.lead]
		local motorwayLen = route.len - route.mainLen
		local own = motorwayLen >= lists.motorwayMinLength and (linkedMode or route.mainLen == 0)
		if own then
			local motorwayStreets = {}
			for _, index in ipairs(route.members) do
				if streets[index].cls == 3 then motorwayStreets[#motorwayStreets + 1] = index end
			end
			own = twoLanesEachWay(motorwayStreets)
		end
		if own then
			local leadMotorway = lead
			if lead.cls ~= 3 then
				for _, index in ipairs(route.members) do
					if streets[index].cls == 3 then leadMotorway = streets[index]; break end
				end
			end
			local ref
			for _, index in ipairs(route.members) do   -- a carriageway that already has its number shares it
				local r = streets[index].ref
				if streets[index].cls == 3 and r ~= nil and r:sub(1, #lists.motorwayPrefix) == lists.motorwayPrefix then ref = ref or r end
			end
			ref = ref or take(lists.motorwayPrefix, zoneOf(leadMotorway), mCount, mPlan)
			for _, index in ipairs(route.members) do
				if streets[index].cls == 3 and streets[index].ref == nil then streets[index].ref = ref end
			end
		end
	end

	-- The other carriageway of an ordinary road: a drive from one town to another only uses one of the two,
	-- so whenever a street is given a number, the one-way street running the opposite way beside it gets the
	-- same number and its name.
	local twins = {}
	if segs ~= nil then
		for _, pair in ipairs(core.pairCarriageways(streets, segs, lists.carriagewayGap)) do
			twins[pair[1]] = twins[pair[1]] or {}
			twins[pair[2]] = twins[pair[2]] or {}
			table.insert(twins[pair[1]], pair[2])
			table.insert(twins[pair[2]], pair[1])
		end
	end
	local function numberTwins(index)
		for _, twin in ipairs(twins[index] or {}) do
			local t = streets[twin]
			if t.ref == nil then
				t.ref = streets[index].ref
				t.partOf = index
				numberTwins(twin)
			end
		end
	end

	-- ---- numbers from what the roads connect (see core.startLinks) ----
	local linked = links ~= nil and links.links ~= nil and #links.links > 0
	local aPrefix = lists.aRoadPrefix
	local function isARef(ref) return ref ~= nil and ref:sub(1, #aPrefix) == aPrefix end
	if linked then
		local streetOfSeg = {}
		for index, s in ipairs(streets) do
			for _, si in ipairs(s.segs) do streetOfSeg[si] = index end
		end
		local function segLength(si)
			local seg = segs[si]
			return seg.len or math.sqrt((seg.x1 - seg.x0) ^ 2 + (seg.y1 - seg.y0) ^ 2)
		end
		for _, link in ipairs(links.links) do
			-- the streets the drive runs along, in order, with how much of each it uses
			local usedLen, path = {}, {}
			for _, si in ipairs(link.segs) do
				local st = streetOfSeg[si]
				if st ~= nil then
					if usedLen[st] == nil then
						usedLen[st] = 0
						path[#path + 1] = st
					end
					usedLen[st] = usedLen[st] + segLength(si)
				end
			end
			-- its stretches that have no number yet; a road that already has one keeps it (the new road runs
			-- along it for that part and carries on with its own number afterwards)
			local isA = link.kind == "A"
			local stretches, current, total = {}, nil, 0
			for _, st in ipairs(path) do
				local s = streets[st]
				local enough = usedLen[st] >= math.min(0.5 * s.len, 300)   -- more than just crossing it
				if s.ref ~= nil or (not isA and s.cls == 3) then
					current = nil
				elseif enough then
					if current == nil then
						current = { streets = {}, len = 0 }
						stretches[#stretches + 1] = current
					end
					current.streets[#current.streets + 1] = st
					current.len = current.len + usedLen[st]
				end
			end
			for _, stretch in ipairs(stretches) do
				if stretch.len >= lists.linkStretchMinimum then total = total + stretch.len end
			end
			if total >= (isA and lists.aRoadLength or lists.bRoadCountryLength) then
				local first
				for _, stretch in ipairs(stretches) do
					if stretch.len >= lists.linkStretchMinimum then
						first = streets[stretch.streets[1]]
						break
					end
				end
				local ref
				local wide = true
				if isA then
					local all = {}
					for _, stretch in ipairs(stretches) do
						if stretch.len >= lists.linkStretchMinimum then
							for _, st in ipairs(stretch.streets) do all[#all + 1] = st end
						end
					end
					wide = twoLanesEachWay(all)
				end
				if isA and link.radial and wide then
					-- a single-digit road: the digit of the zone it leads into
					local digit = radialDigit[link.b] or zoneOf({ x = towns[link.b].x, y = towns[link.b].y })
					if not usedRef[aPrefix .. digit] then
						ref = aPrefix .. digit
						usedRef[ref] = true
					end
				end
				if ref == nil and isA then
					-- two digits at best for a link between primary towns, three for the others; a short one
					-- gets a longer number still
					ref = take(aPrefix, zoneOf(first), aCount, aPlan, math.max((link.primary and wide) and 2 or 3, aTier(total)))
				elseif ref == nil then
					ref = take(lists.bRoadPrefix, zoneOf(first), bCount, bPlan, total >= lists.bRoadThreeDigitLength and 1 or 2)
				end
				for _, stretch in ipairs(stretches) do
					if stretch.len >= lists.linkStretchMinimum then
						for _, st in ipairs(stretch.streets) do
							local s = streets[st]
							s.ref = (s.cls == 3) and (ref .. "(M)") or ref
							if s.cls ~= 3 then numberTwins(st) end
						end
					end
				end
			end
		end
	end

	-- Split carriageways. Where a numbered road divides into two one-way roads that run side by side and
	-- join again, both are that road: the second carriageway takes the same number and name instead of being
	-- treated as a road of its own. The same goes for the short connecting roads between the two.
	-- A group of one-way streets joined end to end (or one short street, lists.connectorMaxLength) with no
	-- number of its own adopts the number of a road that it meets at two or more places and runs alongside
	-- (within lists.parallelGap for lists.parallelShare of its length).
	local function adoptParallel()
		if segs == nil then return end
		local function baseRef(ref) return (ref:gsub("%(M%)$", "")) end
		local function segLen(seg) return seg.len or math.sqrt((seg.x1 - seg.x0) ^ 2 + (seg.y1 - seg.y0) ^ 2) end
		local gap = lists.parallelGap
		local function cellKey(x, y) return math.floor(x / gap) .. ":" .. math.floor(y / gap) end
		for _ = 1, 3 do
			local atNode, grid = {}, {}
			for index, s in ipairs(streets) do
				local numbered = s.ref ~= nil and s.cls ~= 3 and s.slipOf == nil
				for _, si in ipairs(s.segs) do
					local seg = segs[si]
					for _, n in ipairs({ seg.n0, seg.n1 }) do
						if n ~= nil then
							atNode[n] = atNode[n] or {}
							atNode[n][index] = true
						end
					end
					if numbered then
						local key = cellKey((seg.x0 + seg.x1) * 0.5, (seg.y0 + seg.y1) * 0.5)
						grid[key] = grid[key] or {}
						table.insert(grid[key], { x = (seg.x0 + seg.x1) * 0.5, y = (seg.y0 + seg.y1) * 0.5, ref = baseRef(s.ref) })
					end
				end
			end
			-- candidates, grouped: one-way streets that touch each other form one group
			local group, candidates = {}, {}
			local function root(i)
				while group[i] ~= i do
					group[i] = group[group[i]]
					i = group[i]
				end
				return i
			end
			local oneWayStreet = {}
			for index, s in ipairs(streets) do
				if s.ref == nil and s.cls ~= 3 and not s.roundabout and s.slipOf == nil then
					local oneWay = true
					for _, si in ipairs(s.segs) do
						local o = segs[si].oneway
						if o ~= 1 and o ~= -1 then oneWay = false; break end
					end
					if oneWay or s.len <= lists.connectorMaxLength then
						group[index] = index
						oneWayStreet[index] = oneWay
						candidates[#candidates + 1] = index
					end
				end
			end
			for _, here in pairs(atNode) do
				local first
				for index in pairs(here) do
					if oneWayStreet[index] then
						if first == nil then first = index else
							local a, b = root(first), root(index)
							if a ~= b then if a < b then group[b] = a else group[a] = b end end
						end
					end
				end
			end
			local members = {}
			for _, index in ipairs(candidates) do
				local r = root(index)
				members[r] = members[r] or {}
				table.insert(members[r], index)
			end
			local roots = {}
			for r in pairs(members) do roots[#roots + 1] = r end
			table.sort(roots)
			local any = false
			for _, r in ipairs(roots) do
				local isMember, total = {}, 0
				for _, index in ipairs(members[r]) do isMember[index] = true end
				-- the numbered roads this group meets, and at how many different places
				local meets = {}   -- ref -> { nodes = count, street = longest street met }
				local counted = {}
				for _, index in ipairs(members[r]) do
					for _, si in ipairs(streets[index].segs) do
						for _, n in ipairs({ segs[si].n0, segs[si].n1 }) do
							for other in pairs(n ~= nil and atNode[n] or {}) do
								local o = streets[other]
								if not isMember[other] and o.ref ~= nil and o.cls ~= 3 and o.slipOf == nil then
									local ref = baseRef(o.ref)
									local m = meets[ref]
									if m == nil then
										m = { nodes = 0, street = other }
										meets[ref] = m
									end
									if not counted[ref .. "|" .. tostring(n)] then
										counted[ref .. "|" .. tostring(n)] = true
										m.nodes = m.nodes + 1
									end
									if o.len > streets[m.street].len then m.street = other end
								end
							end
						end
					end
				end
				local best, bestShare
				for ref, m in pairs(meets) do
					if m.nodes >= 2 then
						local alongside
						total, alongside = 0, 0
						for _, index in ipairs(members[r]) do
							for _, si in ipairs(streets[index].segs) do
								local seg = segs[si]
								local mx, my, len = (seg.x0 + seg.x1) * 0.5, (seg.y0 + seg.y1) * 0.5, segLen(seg)
								total = total + len
								local near = false
								for ox = -1, 1 do
									for oy = -1, 1 do
										for _, p in ipairs(grid[(math.floor(mx / gap) + ox) .. ":" .. (math.floor(my / gap) + oy)] or {}) do
											if p.ref == ref and (p.x - mx) ^ 2 + (p.y - my) ^ 2 <= gap * gap then near = true end
										end
									end
								end
								if near then alongside = alongside + len end
							end
						end
						local share = total > 0 and alongside / total or 0
						if share >= lists.parallelShare and (best == nil or share > bestShare or (share == bestShare and ref < best)) then
							best, bestShare = ref, share
						end
					end
				end
				if best ~= nil then
					for _, index in ipairs(members[r]) do
						streets[index].ref = best
						streets[index].partOf = meets[best].street   -- and its name, see the end of core.name
					end
					any = true
				end
			end
			if not any then break end
		end
	end
	adoptParallel()

	-- Wide main roads that no link between towns runs along: still A roads (somebody built them wide for a
	-- reason), on longer numbers. A route that is partly numbered already keeps that number throughout.
	for _, route in ipairs(routeList) do
		local lead = streets[route.lead]
		if route.mainLen > 0 and route.len >= lists.aRoadLength then
			local ref
			for _, index in ipairs(route.members) do
				local r = streets[index].ref
				if streets[index].cls == 2 and isARef(r) then ref = r end
			end
			local numberedAlready = ref ~= nil
			for _, index in ipairs(route.members) do
				local s = streets[index]
				if s.ref == nil and (s.cls == 2 or s.cls == 3) then
					if ref == nil then
						local floor = (linked or not twoLanesEachWay(route.members)) and 3 or 1
						ref = take(aPrefix, zoneOf(lead), aCount, aPlan, math.max(floor, aTier(route.len)))
					end
					if s.cls == 2 then
						s.ref = ref
						numberTwins(index)
					elseif not numberedAlready or s.len < lists.motorwayMinLength then
						s.ref = ref .. "(M)"
					end
				end
			end
		end
	end
	-- A number that ended up on less road than a road of its kind needs (a few leftover pieces between other
	-- numbered roads) is withdrawn; those pieces can then be adopted by the road they sit on.
	do
		local total = {}
		for _, s in ipairs(streets) do
			if s.ref ~= nil and s.cls ~= 3 and (keepRefs == nil or keepRefs[s.key] == nil) then
				total[s.ref] = (total[s.ref] or 0) + s.len
			end
		end
		for _, s in ipairs(streets) do
			if s.ref ~= nil and s.cls ~= 3 and total[s.ref] ~= nil then
				local minimum = isARef(s.ref) and lists.aRoadLength or lists.bRoadCountryLength
				if total[s.ref] < minimum then
					usedRef[s.ref] = nil
					s.ref, s.partOf = nil, nil
				end
			end
		end
	end
	adoptParallel()   -- again, for the numbers the wide-road rule has just given out and the pieces just freed

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
			if s.cls == 2 or (isARef(s.ref) and s.cls ~= 3) or s.len >= lists.destinationMinLength then
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
			st.name = streets[st.partOf].name
			if st.ref == nil then st.ref = streets[st.partOf].ref end
			if st.ref ~= nil and st.name == "" then st.name = st.ref end
		end
	end
	-- with links between towns, a street's class says what it is, not how wide it was built: A roads are the
	-- main roads, everything else that is not a motorway is an ordinary road
	if linked then
		for _, st in ipairs(streets) do
			if st.cls ~= 3 then st.cls = (isARef(st.ref) and st.slipOf == nil) and 2 or 1 end
		end
	end
	return streets, hubTown
end

return core
