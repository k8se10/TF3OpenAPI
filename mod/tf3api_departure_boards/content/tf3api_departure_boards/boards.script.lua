-- TF3OpenAPI - departure boards: what the boards show.
--
-- The lit dots of a board are written into its texture by the TF3OpenAPI native layer; this script says what
-- to write (tf3api.boardRows, tf3api.boardClock). Without the native layer nothing here does anything and a
-- board shows the picture it ships with.
--
-- How a board works, as in the older game's displays mod (re_notes/boards/reference_tf2_displays.md):
--   * place it near a station and it joins that station by itself - no number, no setting;
--   * once joined it is that station's board for good;
--   * a departures board lists the vehicles leaving the station, an arrivals board those approaching it:
--     place, line, platform, time ("Due" when it is about to), the station's name, a clock;
--   * "Sorry no service" when nothing is known; the "not connected" lines while it has joined no station.
--
-- Joining rebuilds the board once (a build command, like placing it): the station and the screen it uses
-- are kept in the board's own settings, so nothing of this script is stored in the save.
--
-- Everything read from the game is read a little at a time: boards are looked for a few hundred
-- constructions per frame, and one screen is worked out at a time.

local MOD_ID = "tf3api_departure_boards"
local MOD = "[" .. MOD_ID .. "] "

local function log(text)
	pcall(function() if tf3api ~= nil and tf3api.log ~= nil then tf3api.log(MOD .. text) end end)
end

local function loadModule(name)
	local path = MOD_ID .. "::/" .. MOD_ID .. "/" .. name
	local ok, mod = pcall(function() return ug_require(path) end)
	if ok and type(mod) == "table" then return mod end
	ok, mod = pcall(require, path)
	if ok and type(mod) == "table" then return mod end
	return nil
end

-- how often things are looked at, in frames
local SURVEY_PER_FRAME = 250      -- constructions looked at per frame while searching for boards
local SURVEY_PAUSE = 240          -- frames between two searches
local SCREEN_EVERY = 20           -- frames between working out two screens
local REBUILD_EVERY = 30          -- frames between two boards being rebuilt
local VEHICLES_PER_LINE = 16      -- vehicles of a line that are asked for their whereabouts

local state = {
	bridge = nil,        -- false once it is known to be missing
	core = nil,
	lastSecond = nil,    -- the clock value last sent
	told = false,
	failures = 0,
	frame = 0,
	-- the search for boards and stations
	survey = nil,        -- { entities, cursor, boards } while a search runs
	surveyAt = 0,        -- frame at which the next search starts
	boards = {},         -- found boards
	content = {},        -- [slot] = { station = group, kind = }
	stationName = {},    -- [group] = name
	rebuilds = {},       -- boards waiting to be rebuilt: { board =, station =, slot = }
	rebuildAt = 0,
	asked = {},          -- [board id] = frame at which its rebuild was sent (not asked again until the next search has seen it)
	toldNoStation = {},  -- [board id] = true once said
	-- the screens
	nextSlot = 0,
	screenAt = 0,
	sent = {},           -- [slot] = the rows last sent, joined
	toldScreens = 0,
	toldRebuilds = 0,
	choices = {},        -- [board id] = { platforms = "1,3", mode = } chosen in the board's window
}

local function bridge()
	if state.bridge == nil then
		local ok, t = pcall(function() return tf3api end)
		if ok and type(t) == "table" and type(t.boardClock) == "function" then
			state.bridge = t
			state.core = loadModule("boards_core.lua")
			log("the native layer is there: the boards' clock runs" .. (type(t.boardRows) == "function" and "" or " (an older layer: no departures)")
				.. (state.core == nil and " (the rules could not be loaded: no departures)" or ""))
		else
			state.bridge = false   -- no native layer: the boards keep their shipped picture
		end
	end
	return state.bridge
end

-- The boards' clock, in seconds, for the game's running time in milliseconds: the running time read as a
-- clock, so at normal game speed a second of play is a second on the board. It only ever goes forward,
-- stands still while the game is paused and runs with the game's speed; times of arrival, which the game
-- counts in the same time, can be shown on it. It is the same clock as the TF3OpenAPI day clock mod's.
-- (Not the time of day of the sky: in the game's usual setting the sky does not run through a day.)
local function clockOf(gameTime)
	if type(gameTime) ~= "number" or gameTime < 0 then return nil end
	return math.floor(gameTime / 1000) % 86400
end

local function gameTimeNow()
	local ok, value = pcall(function()
		return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	end)
	if ok and type(value) == "number" then return value end
	return nil
end

-- where a construction stands, from its placement (the game's 4 x 4 numbers, by column)
local function placeOf(transf)
	local ok, x, y = pcall(function() local c = transf:cols(3); return c.x, c.y end)
	if ok and type(x) == "number" and type(y) == "number" then return x, y end
	ok, x, y = pcall(function() return transf[13], transf[14] end)
	if ok and type(x) == "number" and type(y) == "number" then return x, y end
	return nil
end

-- a construction's place in full: where it stands, its height, and the direction of its second axis on the
-- ground (for a station built along its first axis, the direction across the platforms)
local function frameOf(transf)
	local ok, x, y, z, ux, uy = pcall(function()
		local c, a = transf:cols(3), transf:cols(1)
		return c.x, c.y, c.z, a.x, a.y
	end)
	if ok and type(x) == "number" and type(z) == "number" and type(ux) == "number" then return x, y, z, ux, uy end
	ok, x, y, z, ux, uy = pcall(function() return transf[13], transf[14], transf[15], transf[5], transf[6] end)
	if ok and type(x) == "number" and type(z) == "number" and type(ux) == "number" then return x, y, z, ux, uy end
	return nil
end

local function nameOf(entity)
	local ok, name = pcall(function() return api.engine.getComponent(entity, api.type.ComponentType.NAME).name end)
	if ok and type(name) == "string" then return name end
	return ""
end

-- ---- stations ---------------------------------------------------------------------------------------------

-- every station group with its place and, where the game says it, its outline on the ground
local function stations()
	local out = {}
	local ok, problem = pcall(function()
		local toConstruction = api.engine.system.streetConnectorSystem.getStation2ConstructionMap()
		for _, group in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.STATION_GROUP)) do
			local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
			local entry
			for _, station in ipairs(comp.stations) do
				local construction = toConstruction[station]
				if construction ~= nil then
					local x, y = placeOf(api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION).transf)
					if x ~= nil then
						if entry == nil then
							entry = { id = group, name = nameOf(group), x = x, y = y }
							local _, _, z, ux, uy = frameOf(api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION).transf)
							entry.z, entry.upX, entry.upY = z, ux, uy
						end
						pcall(function()
							local box = api.engine.getComponent(construction, api.type.ComponentType.BOUNDING_VOLUME).bbox
							local x0, y0, x1, y1 = box.min.x, box.min.y, box.max.x, box.max.y
							if type(x0) == "number" and type(x1) == "number" and x1 >= x0 and y1 >= y0 then
								entry.x0 = math.min(entry.x0 or x0, x0)
								entry.y0 = math.min(entry.y0 or y0, y0)
								entry.x1 = math.max(entry.x1 or x1, x1)
								entry.y1 = math.max(entry.y1 or y1, y1)
							end
						end)
					end
				end
			end
			if entry ~= nil then out[#out + 1] = entry end
		end
	end)
	if not ok and not state.toldStations then
		state.toldStations = true
		log("stations could not be listed: " .. tostring(problem))
	end
	return out
end

-- The platforms of a station group: the terminal numbers of its stations, from 1 (several stations in a group
-- are numbered on: their terminals follow each other).
local function platformsOf(group)
	local out = {}
	pcall(function()
		local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
		local n = 0
		for _, station in ipairs(comp.stations) do
			local s = api.engine.getComponent(station, api.type.ComponentType.STATION)
			for _ = 1, #s.terminals do
				n = n + 1
				out[#out + 1] = n
			end
		end
	end)
	return out
end

-- The track lines of a station group's platforms, for the plan in a board's window: the edges each terminal's
-- trains stop on, as world positions (numbered as platformsOf numbers them). An edge of a construction may be
-- kept in the construction's own frame: whichever of the two lies nearer the station is taken.
local function endsOf(geometry)
	for _, kind in ipairs({ "straight", "cubicSpline", "cubicOffsetSpline" }) do
		local ok, a, b = pcall(function()
			local pos = geometry[kind].pos
			return pos[1], pos[2]
		end)
		if ok and a ~= nil and b ~= nil and type(a.x) == "number" and type(b.x) == "number" then return a.x, a.y, b.x, b.y end
	end
	local ok, x0, y0, x1, y1 = pcall(function()
		local arc = geometry.arc
		local r, s, e = arc.radius, arc.startAngle, arc.startAngle + arc.angle
		return arc.center.x + r * math.cos(s), arc.center.y + r * math.sin(s), arc.center.x + r * math.cos(e), arc.center.y + r * math.sin(e)
	end)
	if ok and type(x0) == "number" and type(y1) == "number" then return x0, y0, x1, y1 end
	return nil
end

local function segmentsOf(group)
	local out = {}
	local ok, problem = pcall(function()
		local toConstruction = api.engine.system.streetConnectorSystem.getStation2ConstructionMap()
		local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
		local networks = {}
		local n = 0
		for _, station in ipairs(comp.stations) do
			local transf
			pcall(function() transf = api.engine.getComponent(toConstruction[station], api.type.ComponentType.CONSTRUCTION).transf end)
			local ox, oy, ax, ay, bx, by
			pcall(function()
				local c1, c2, c3 = transf:cols(1), transf:cols(2), transf:cols(3)
				ax, ay, bx, by, ox, oy = c1.x, c1.y, c2.x, c2.y, c3.x, c3.y
			end)
			local s = api.engine.getComponent(station, api.type.ComponentType.STATION)
			for _, terminal in ipairs(s.terminals) do
				n = n + 1
				-- the edges its trains stop on: listed, or the one its stopping point is on
				local places = {}
				local okEdges, whyEdges = pcall(function()
					for _, at in ipairs(terminal.vehicleEdges) do places[#places + 1] = { at.edgeId.entity, at.edgeId.index } end
				end)
				if not okEdges and state.segmentsWhy == nil then state.segmentsWhy = "vehicleEdges: " .. tostring(whyEdges) end
				if #places == 0 then
					local okNode, whyNode = pcall(function() places[1] = { terminal.vehicleNodeId.entity, -1 } end)
					if not okNode and state.segmentsWhy == nil then state.segmentsWhy = "vehicleNodeId: " .. tostring(whyNode) end
				end
				for _, at in ipairs(places) do
					local entity, index = at[1], at[2]
					local x0, y0, x1, y1
					local okRead, whyRead = pcall(function()
						local network = networks[entity]
						if network == nil then
							local okNet, net = pcall(api.engine.getComponent, entity, api.type.ComponentType.TRANSPORT_NETWORK)
							network = okNet and net or false
							networks[entity] = network
						end
						local edge = network and index >= 0 and network.edges[index + 1] or nil
						if edge ~= nil then x0, y0, x1, y1 = endsOf(edge.geometry) end
						if x0 == nil then
							-- a piece of track of its own: its two ends
							local e = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
							if e ~= nil then x0, y0, x1, y1 = e.position0.x, e.position0.y, e.position1.x, e.position1.y end
						end
					end)
					if not okRead and state.segmentsWhy == nil then state.segmentsWhy = "edge: " .. tostring(whyRead) end
					if x0 ~= nil then
						if ox ~= nil and (x0 - ox) ^ 2 + (y0 - oy) ^ 2 > 1500 * 1500 then
							-- far from the station: taken to be in the construction's own frame
							x0, y0 = ox + x0 * ax + y0 * bx, oy + x0 * ay + y0 * by
							x1, y1 = ox + x1 * ax + y1 * bx, oy + x1 * ay + y1 * by
						end
						out[#out + 1] = { n = n, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
					end
				end
			end
		end
	end)
	if not ok and not state.toldSegments then
		state.toldSegments = true
		log("the station's track lines could not be read: " .. tostring(problem))
	end
	if #out == 0 and not state.toldNoSegments then
		state.toldNoSegments = true
		log("no platform's stopping track could be read" .. (state.segmentsWhy ~= nil and (" (" .. state.segmentsWhy .. ")") or " (the terminals list none)"))
	end
	return out
end

-- The plan of a station group for the board windows: its platform, building and stairs models as boxes on the
-- ground, its tracks, all in the station's own frame (see boards_core "The station plan"). Worked out once per
-- station and kept until something is built or removed.
local PLAN_EVERY = 1800   -- frames between two readings of a station's plan when nothing was built
local PLAN_REACH = 600    -- metres a platform's track is followed through the network when it is not the station's own
local function planOf(group)
	local core = state.core
	local segments = segmentsOf(group)
	local quads, tracks = {}, {}
	local fx, fy, fux, fuy
	local modelInfo = {}
	local planCount = { instances = 0 }
	local ok, problem = pcall(function()
		local toConstruction = api.engine.system.streetConnectorSystem.getStation2ConstructionMap()
		local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
		local seen = {}
		for _, station in ipairs(comp.stations) do
			local construction = toConstruction[station]
			if construction ~= nil and not seen[construction] then
				seen[construction] = true
				local con = api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION)
				pcall(function()
					local c1, c3 = con.transf:cols(1), con.transf:cols(3)
					if fx == nil then fx, fy, fux, fuy = c3.x, c3.y, c1.x, c1.y end
				end)
				-- the station's own tracks
				for _, edge in ipairs(con.frozenEdges or {}) do
					pcall(function()
						local e = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
						local p0, p1, t0, t1 = e.position0, e.position1, e.tangent0, e.tangent1
						local xs, ys = {}, {}
						for i = 0, 6 do
							local t = i / 6
							local h00, h10 = 2 * t ^ 3 - 3 * t ^ 2 + 1, t ^ 3 - 2 * t ^ 2 + t
							local h01, h11 = -2 * t ^ 3 + 3 * t ^ 2, t ^ 3 - t ^ 2
							xs[#xs + 1] = h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x
							ys[#ys + 1] = h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y
						end
						tracks[#tracks + 1] = { n = 0, x = xs, y = ys, node0 = e.node0, node1 = e.node1, edge = edge }
					end)
				end
				-- its models, as the ground they cover: the construction's own and those of its sub-constructions
				local holders = { construction }
				pcall(function() for _, sub in ipairs(con.subconstructions) do holders[#holders + 1] = sub end end)
				for _, holder in ipairs(holders) do
				local okModels, whyModels = pcall(function()
					local list = api.engine.getComponent(holder, api.type.ComponentType.MODEL_INSTANCE_LIST)
					if list == nil then return end
					for _, instance in ipairs(list.fatInstances) do
						planCount.instances = planCount.instances + 1
						local info = modelInfo[instance.modelId]
						if info == nil then
							info = false
							local okInfo, whyInfo = pcall(function()
								local box = api.res.modelRep.get(instance.modelId).boundingInfo
								local lo, hi = box.bbMin, box.bbMax
								local area = math.abs((hi.x - lo.x) * (hi.y - lo.y))
								local name = api.res.modelRep.getName(instance.modelId)
								if planCount.sample == nil then planCount.sample = tostring(name) end
								local kind = core.planKind(name, area)
								if kind ~= nil then info = { kind = kind, x0 = lo.x, y0 = lo.y, x1 = hi.x, y1 = hi.y } end
							end)
							if not okInfo and planCount.why == nil then planCount.why = "model: " .. tostring(whyInfo) end
							modelInfo[instance.modelId] = info
						end
						if info then
							pcall(function()
								local c1, c2, c3 = instance.transf:cols(0), instance.transf:cols(1), instance.transf:cols(3)   -- columns count from 0: x axis, y axis, place
								local xs, ys = {}, {}
								for _, corner in ipairs({ { info.x0, info.y0 }, { info.x1, info.y0 }, { info.x1, info.y1 }, { info.x0, info.y1 } }) do
									xs[#xs + 1] = c3.x + corner[1] * c1.x + corner[2] * c2.x
									ys[#ys + 1] = c3.y + corner[1] * c1.y + corner[2] * c2.y
								end
								quads[#quads + 1] = { kind = info.kind, x = xs, y = ys }
							end)
						end
					end
				end)
				if not okModels and planCount.why == nil then planCount.why = "model list: " .. tostring(whyModels) end
				end
			end
		end
	end)
	if not ok and not state.toldPlanFault then
		state.toldPlanFault = true
		log("the station's plan could not be read: " .. tostring(problem))
	end
	-- Which platform each track is. A terminal names the node its trains stop at (build 40420: an entity with a
	-- one-node network and no list of stopping edges); its platform's track is the station's track pieces from
	-- that node on, both ways, up to a set of points (a node more than two pieces meet at) or the station's end.
	local platformOfNode, platformIndexOfNode = {}, {}
	pcall(function()
		local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
		local n = 0
		for _, station in ipairs(comp.stations) do
			local s = api.engine.getComponent(station, api.type.ComponentType.STATION)
			for _, terminal in ipairs(s.terminals) do
				n = n + 1
				pcall(function()
					platformOfNode[terminal.vehicleNodeId.entity] = n
					platformIndexOfNode[terminal.vehicleNodeId.entity] = terminal.vehicleNodeId.index
				end)
			end
		end
	end)
	local atNode = {}
	for i, track in ipairs(tracks) do
		for _, node in ipairs({ track.node0, track.node1 }) do
			if node ~= nil then
				atNode[node] = atNode[node] or {}
				table.insert(atNode[node], i)
			end
		end
	end
	-- Each platform's track from the game's own record of it: the terminal's stopping point (where its trains
	-- stop) lies on that platform's track, so the station's track piece passing through that point is the
	-- platform's; from there the track is followed piece by piece, both ways, up to points. A stopping point is
	-- a node of the game's network: its place is read from the node itself.
	local function pointOf(node, index)
		local x, y
		pcall(function()
			local p = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE).position
			x, y = p.x, p.y
		end)
		if x == nil then
			pcall(function()
				local network = api.engine.getComponent(node, api.type.ComponentType.TRANSPORT_NETWORK)
				local entry = network.nodes[(index or 0) + 1]
				local p = entry.pos or entry.position
				x, y = p.x, p.y
			end)
		end
		return x, y
	end
	local function distanceTo(track, x, y)
		local best = math.huge
		for k = 1, #track.x - 1 do
			local ax, ay, bx, by = track.x[k], track.y[k], track.x[k + 1], track.y[k + 1]
			local dx, dy = bx - ax, by - ay
			local length2 = dx * dx + dy * dy
			local s = length2 > 0 and math.max(0, math.min(1, ((x - ax) * dx + (y - ay) * dy) / length2)) or 0
			local px, py = ax + s * dx, ay + s * dy
			best = math.min(best, (x - px) ^ 2 + (y - py) ^ 2)
		end
		return math.sqrt(best)
	end
	local tagged = 0
	local where = {}
	for node, n in pairs(platformOfNode) do
		local x, y = pointOf(node, platformIndexOfNode[node])
		local start, startD
		if x ~= nil then
			for k, track in ipairs(tracks) do
				local d = distanceTo(track, x, y)
				if startD == nil or d < startD then start, startD = k, d end
			end
		end
		if start ~= nil and startD < 3 then
			tagged = tagged + 1
			local open, seen = { { start, nil } }, {}
			while #open > 0 do
				local item = table.remove(open)
				local k, from = item[1], item[2]
				if not seen[k] and tracks[k].n == 0 then
					seen[k] = true
					tracks[k].n = n
					for _, side in ipairs({ tracks[k].node0, tracks[k].node1 }) do
						if side ~= nil and side ~= from then
							local next = atNode[side] or {}
							if #next <= 2 then
								for _, other in ipairs(next) do if other ~= k then open[#open + 1] = { other, side } end end
							end
						end
					end
				end
			end
		end
		where[#where + 1] = string.format("P%d stops at %s -> %s", n, x ~= nil and string.format("(%.1f, %.1f)", x, y) or "an unreadable point",
			start ~= nil and string.format("track piece %s, %.1f m off", tostring(tracks[start].edge), startD) or "no track piece")
	end
	if not state.toldWhere then
		state.toldWhere = true
		table.sort(where)
		log("platforms from the game's terminals: " .. table.concat(where, "; "))
	end
	-- A platform whose track is not one of the station's own pieces (track drawn freely through a station, with
	-- the stopping node on it): its track is followed through the game's network from the stopping node, both
	-- ways, up to points or PLAN_REACH metres. Pieces already drawn are not added twice.
	local haveEdge = {}
	for _, track in ipairs(tracks) do if track.edge ~= nil then haveEdge[track.edge] = true end end
	local function pieceOf(edge, n)
		local okPiece, piece = pcall(function()
			local e = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
			local p0, p1, t0, t1 = e.position0, e.position1, e.tangent0, e.tangent1
			local xs, ys = {}, {}
			for i = 0, 6 do
				local s = i / 6
				local h00, h10 = 2 * s ^ 3 - 3 * s ^ 2 + 1, s ^ 3 - 2 * s ^ 2 + s
				local h01, h11 = -2 * s ^ 3 + 3 * s ^ 2, s ^ 3 - s ^ 2
				xs[#xs + 1] = h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x
				ys[#ys + 1] = h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y
			end
			return { n = n, x = xs, y = ys, node0 = e.node0, node1 = e.node1, edge = edge, length = e.distance or 0 }
		end)
		return okPiece and piece or nil
	end
	for node, n in pairs(platformOfNode) do
		local okWalk = pcall(function()
			local streets = api.engine.system.streetSystem
			local found = false
			for _, track in ipairs(tracks) do if track.n == n then found = true end end
			if found then return end
			local open, walked = {}, 0
			for _, edge in ipairs(streets.getNodeTrackSegments(node)) do open[#open + 1] = { edge, node } end
			local guard = 0
			while #open > 0 and guard < 200 do
				guard = guard + 1
				local item = table.remove(open, 1)
				local edge, from = item[1], item[2]
				if not haveEdge[edge] then
					local piece = pieceOf(edge, n)
					if piece ~= nil then
						haveEdge[edge] = true
						tracks[#tracks + 1] = piece
						walked = walked + piece.length
						local other = piece.node0 == from and piece.node1 or piece.node0
						local next = streets.getNodeTrackSegments(other)
						if #next <= 2 and walked < PLAN_REACH then
							for _, nextEdge in ipairs(next) do if nextEdge ~= edge then open[#open + 1] = { nextEdge, other } end end
						end
					end
				end
			end
			tagged = tagged + 1
		end)
		if not okWalk and not state.toldWalk then
			state.toldWalk = true
			log("a platform's track could not be followed through the network")
		end
	end
	if not state.toldTagged then
		state.toldTagged = true
		local count = 0
		for _ in pairs(platformOfNode) do count = count + 1 end
		log(string.format("platform tracks found from the stopping nodes: %d of %d", tagged, count))
	end
	for _, s in ipairs(segments) do tracks[#tracks + 1] = { n = s.n, x = { s.x0, s.x1 }, y = { s.y0, s.y1 } } end
	-- What the game says about this station, written out once a session for study (tf3api_out/station_plan_<id>.txt).
	if not state.dumpedPlan and type(state.bridge) == "table" and type(state.bridge.writeFile) == "function" then
		state.dumpedPlan = true
		local out = {}
		local function say(...) out[#out + 1] = string.format(...) end
		local function try(what, fn)
			local okTry, why = pcall(fn)
			if not okTry then say("  !! %s: %s", what, tostring(why)) end
		end
		local function v3(v) return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z) end
		try("station", function()
			local toConstruction = api.engine.system.streetConnectorSystem.getStation2ConstructionMap()
			local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
			for _, station in ipairs(comp.stations) do
				local construction = toConstruction[station]
				say("station %s construction %s", tostring(station), tostring(construction))
				local con = api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION)
				try("transf", function()
					say("  file %s", tostring(con.fileName))
					say("  transf cols: %s %s %s %s", v3(con.transf:cols(0)), v3(con.transf:cols(1)), v3(con.transf:cols(2)), v3(con.transf:cols(3)))
				end)
				try("bounds", function()
					local box = api.engine.getComponent(construction, api.type.ComponentType.BOUNDING_VOLUME).bbox
					say("  bounding volume %s .. %s", v3(box.min), v3(box.max))
				end)
				try("edges", function()
					say("  frozenEdges %d, frozenNodes %d, subconstructions %d", #con.frozenEdges, #con.frozenNodes, #con.subconstructions)
					for i, edge in ipairs(con.frozenEdges) do
						if i <= 80 then
							try("edge", function()
								local e = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
								say("  edge %s: %s -> %s  tangents %s %s  type %s", tostring(edge), v3(e.position0), v3(e.position1), v3(e.tangent0), v3(e.tangent1), tostring(e.type))
							end)
						end
					end
				end)
				try("terminals", function()
					local s = api.engine.getComponent(station, api.type.ComponentType.STATION)
					say("  terminals %d", #s.terminals)
					for i, terminal in ipairs(s.terminals) do
						try("terminal", function()
							local node = terminal.vehicleNodeId
							say("  terminal %d: vehicleNodeId entity %s index %s; vehicleEdges %d; personNodes %d; personEdges %d", i, tostring(node.entity), tostring(node.index),
								#terminal.vehicleEdges, #terminal.personNodes, #terminal.personEdges)
							for k, at in ipairs(terminal.vehicleEdges) do
								if k <= 4 then say("    vehicleEdge %d: entity %s index %s param %s", k, tostring(at.edgeId.entity), tostring(at.edgeId.index), tostring(at.param)) end
							end
							for k, at in ipairs(terminal.personEdges) do
								if k <= 3 then say("    personEdge %d: entity %s index %s", k, tostring(at.entity), tostring(at.index)) end
							end
							try("network", function()
								local network = api.engine.getComponent(node.entity, api.type.ComponentType.TRANSPORT_NETWORK)
								say("    network of entity %s: %d nodes, %d edges", tostring(node.entity), #network.nodes, #network.edges)
								local shown = 0
								for k, edge in ipairs(network.edges) do
									local c0, c1 = edge.conns[1], edge.conns[2]
									if (c0.index == node.index and c0.entity == node.entity) or (c1.index == node.index and c1.entity == node.entity) then
										shown = shown + 1
										if shown <= 4 then
											local x0, y0, x1, y1 = endsOf(edge.geometry)
											say("    edge %d at that node: conns (%s,%s) (%s,%s) length %s ends %s %s -> %s %s", k - 1, tostring(c0.entity), tostring(c0.index),
												tostring(c1.entity), tostring(c1.index), tostring(edge.geometry.length), tostring(x0), tostring(y0), tostring(x1), tostring(y1))
										end
									end
								end
								say("    edges at that node: %d", shown)
							end)
						end)
					end
				end)
				local holders = { construction }
				try("subs", function() for _, sub in ipairs(con.subconstructions) do holders[#holders + 1] = sub end end)
				for _, holder in ipairs(holders) do
					try("models", function()
						local list = api.engine.getComponent(holder, api.type.ComponentType.MODEL_INSTANCE_LIST)
						say("  holder %s: %s", tostring(holder), list ~= nil and (#list.fatInstances .. " models") or "no model list")
						if list == nil then return end
						for i, instance in ipairs(list.fatInstances) do
							if i <= 300 then
								try("model", function()
									local name = api.res.modelRep.getName(instance.modelId)
									local t = instance.transf
									local line = string.format("    %s  at %s  x-axis %s y-axis %s", tostring(name), v3(t:cols(3)), v3(t:cols(0)), v3(t:cols(1)))
									try("box", function()
										local box = api.res.modelRep.get(instance.modelId).boundingInfo
										line = line .. string.format("  box %s .. %s", v3(box.bbMin), v3(box.bbMax))
									end)
									say("%s", line)
								end)
							end
						end
					end)
				end
			end
		end)
		pcall(state.bridge.writeFile, "station_plan_" .. tostring(group) .. ".txt", table.concat(out, "\n"))
		log("what the game says about this station is written to tf3api_out/station_plan_" .. tostring(group) .. ".txt")
	end
	local frame = core.planFrame(segments, fx, fy, fux, fuy)
	local scene, bounds, tags = core.planScene(frame, quads, tracks)
	if not state.toldPlanMade then
		state.toldPlanMade = true
		log(string.format("station plan of %s: %d model box(es) of %d model(s) (first: %s%s), %d track piece(s), %d platform tag(s); %.0f x %.0f m",
			tostring(state.stationName[group]), #quads, planCount.instances, tostring(planCount.sample), planCount.why ~= nil and ("; " .. planCount.why) or "",
			#tracks, #tags, bounds.x1 - bounds.x0, bounds.y1 - bounds.y0))
	end
	return { frame = frame, scene = scene, info = core.planInfoText(bounds, tags, frame) }
end

-- Choices made in a board's window: "set\tid\tplatforms\tmode". Kept for the session at once, and written into
-- the board itself by rebuilding it, so that they stay with the save.
local savePlaced, forgetBoard   -- defined further down, with the list of built boards

local function takeChoices()
	local b = state.bridge
	if type(b) ~= "table" or type(b.take) ~= "function" then return end
	for _ = 1, 16 do
		local ok, message = pcall(b.take, MOD_ID)
		if not ok or type(message) ~= "string" then return end
		local watch = message:match("^watch\t(%d*)$")
		if watch ~= nil then state.watching = tonumber(watch); state.animAt = 0 end
		if message == "plans" then   -- a board window asks for the stations' plans again
			state.plans = nil
			state.surveyAt = state.frame
		end
		local forget = tonumber(message:match("^forget\t(%d+)$"))
		if forget ~= nil then forgetBoard(forget, "removed in its window") end
		local id, platforms, mode, layout = message:match("^set\t(%d+)\t([^\t]*)\t([^\t]*)\t?([^\t]*)$")
		if layout == nil or layout == "" then layout = state.core.LAYOUT_DEFAULT end
		id = tonumber(id)
		if id ~= nil then
			state.choices[id] = { platforms = platforms, mode = mode == "cycle" and "cycle" or "merged", layout = layout }
			log(string.format("board %d: platforms %s, %s", id, platforms ~= "" and platforms or "all", mode))
			for _, board in ipairs(state.boards) do
				if board.id == id and board.asset then
					board.platforms = platforms ~= "" and platforms or nil
					board.mode = state.choices[id].mode
					board.layout = layout
					local p = board.placedIndex ~= nil and state.placed ~= nil and state.placed[board.placedIndex] or nil
					if p ~= nil then
						p.platforms, p.mode, p.layout = platforms, board.mode, layout
						savePlaced()
					end
				elseif board.id == id and board.station ~= nil then
					board.platforms = platforms ~= "" and platforms or nil
					board.mode = state.choices[id].mode
					board.layout = layout
					state.rebuilds[#state.rebuilds + 1] = { board = board, station = board.station, slot = board.slot or 0, keep = true }
				end
			end
			state.surveyAt = state.frame   -- work the screens out again now
		end
	end
end

-- ---- looking for the boards (a little per frame), joining them, giving them screens ------------------------

local function readBoard(entity)
	local comp = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
	local file = tostring(comp.fileName)
	-- (diagnostic: what the game calls a few constructions, and any that look like ours)
	state.seenFiles = state.seenFiles or {}
	if #state.seenFiles < 4 or (file:lower():find("board", 1, true) and #state.seenFiles < 12) then
		state.seenFiles[#state.seenFiles + 1] = string.format("%d=%s(%s)", entity, file, type(comp.fileName))
	end
	if file:find(MOD_ID, 1, true) == nil or file:find("board_", 1, true) == nil then return nil end
	local x, y = placeOf(comp.transf)
	if x == nil then error("a board's place could not be read from its placement") end
	local _, _, z = frameOf(comp.transf)
	local board = { id = entity, file = file, x = x, y = y, z = z or 0, transf = comp.transf,
		kind = file:find("arrivals", 1, true) ~= nil and state.core.ARRIVALS or state.core.DEPARTURES }
	pcall(function()
		local station = tonumber(comp.params.station)
		if station ~= nil and station > 0 then board.station = station end
		local screen = tonumber(comp.params.screen)
		if screen ~= nil and screen >= 1 and board.station ~= nil then board.slot = math.floor(screen) - 1 end
		if type(comp.params.platforms) == "string" then board.platforms = comp.params.platforms end
		if comp.params.mode == "cycle" then board.mode = "cycle" end
	end)
	-- a choice made in the board's window this session counts before what the board was built with
	local chosen = state.choices[entity]
	if chosen ~= nil then board.platforms, board.mode, board.layout = chosen.platforms, chosen.mode, chosen.layout end
	if board.platforms == "" then board.platforms = nil end
	return board
end

local function surveyDone(boards, total)
	local core = state.core
	local list = #boards > 0 and stations() or {}
	state.stationName = {}
	state.stationPos = state.stationPos or {}
	for _, station in ipairs(list) do
		state.stationName[station.id] = station.name
		state.stationPos[station.id] = { x = station.x, y = station.y }
	end
	state.rebuilds = {}
	-- a board that has joined no station yet joins the nearest one in reach
	for _, board in ipairs(boards) do
		if board.station == nil then
			local near = core.nearby(board.x, board.y, list)
			if #near > 0 then
				board.station = near[1].station.id
				board.joining = true
				if #near > 1 and not state.toldNoStation[board.id] then
					log(string.format("board %d: %d stations in reach; joining the nearest, %s", board.id, #near, near[1].station.name))
				end
			elseif not state.toldNoStation[board.id] then
				state.toldNoStation[board.id] = true
				log(string.format("board %d: cannot find a nearby station to join (within %d m of one)", board.id, core.JOIN_REACH))
			end
		end
	end
	local change, content, full = core.allocate(boards)
	state.content = content
	-- The game does not let assets be clicked: the native layer is told where the boards are, and the
	-- board window (gui/tf3api_boards) is told what to show about each.
	-- (Boards are plain constructions now and the game itself opens their window; our own click spots are
	-- only for boards the game cannot pick, which there are none of: the list is kept empty.)
	-- The game cannot select a board it has put into an asset group: those get our own click (the native
	-- layer) and our own window.
	if type(state.bridge) == "table" and type(state.bridge.boardSpots) == "function" then
		local lines = {}
		for _, board in ipairs(boards) do if board.asset then lines[#lines + 1] = string.format("%d %.2f %.2f %.2f 1.8", board.id, board.x, board.y, (board.z or 0) + 1.7) end end
		pcall(state.bridge.boardSpots, table.concat(lines, "\n"))
	end
	-- the plan of each joined station for the board windows (drawn there, from the tracks its trains stop on)
	state.plans = state.plans or {}
	for _, board in ipairs(boards) do
		local group = board.station
		if group ~= nil then
			-- worked out when first needed, after anything is built, and again every half minute or so (a
			-- station changed through its own settings, a platform added); sent to the windows when it differs
			local plan = state.plans[group]
			if plan == nil or state.frame - (plan.at or 0) > PLAN_EVERY then
				local fresh = planOf(group)
				fresh.at = state.frame
				local changed = plan == nil or plan.scene ~= fresh.scene or plan.info ~= fresh.info
				plan = fresh
				state.plans[group] = plan
				if changed and type(state.bridge) == "table" and type(state.bridge.post) == "function" then
					pcall(state.bridge.post, MOD_ID .. ".ui", table.concat({ "plan", tostring(group), plan.info, plan.scene }, "\t"))
				end
			end
			local a, c = core.planPoint(plan.frame, board.x, board.y)
			board.diagram = string.format("%d %.1f %.1f", group, a, c)   -- its station and its place on the plan
		end
	end
	if type(state.bridge) == "table" and type(state.bridge.post) == "function" then
		for _, board in ipairs(boards) do
			local platforms = board.station ~= nil and platformsOf(board.station) or {}
			pcall(state.bridge.post, MOD_ID .. ".ui", table.concat({ "board", tostring(board.id),
				board.station ~= nil and tostring(state.stationName[board.station] or "") or "", tostring(board.kind),
				table.concat(platforms, ","), tostring(board.platforms or ""), tostring(board.mode or "merged"), tostring(board.layout or state.core.LAYOUT_DEFAULT),
				tostring(board.group or ""), "", board.diagram or "" }, "\t"))
		end
	end
	for _, board in ipairs(boards) do
		local slot = change[board.id]
		if slot ~= nil and state.asked[board.id] == nil then
			state.rebuilds[#state.rebuilds + 1] = { board = board, station = board.station, slot = slot }
		end
	end
	state.asked = {}
	if #full > 0 and not state.toldFull then
		state.toldFull = true
		log(string.format("%d board(s) have no screen: all %d different screens are in use", #full, core.SLOTS))
	end
	if #boards ~= #state.boards or #state.rebuilds > 0 then
		local screens = 0
		for _ in pairs(content) do screens = screens + 1 end
		log(string.format("%d board(s) among %d constructions; %d screen(s) in use; %d board(s) to be joined", #boards, total, screens, #state.rebuilds))
	end
	state.boards = boards
end

-- The models of our boards (every screen's), as the game numbers them: a board the game has put into an asset
-- group is no construction, and is known only by its model.
local function boardModels()
	if state.models ~= nil then return state.models end
	local models = {}
	pcall(function()
		local names = { { MOD_ID .. "::/" .. MOD_ID .. "/board_modern_pole.mdl", 0 } }
		for slot = 0, 31 do names[#names + 1] = { string.format("%s::/%s/board_modern_pole_%02d.mdl", MOD_ID, MOD_ID, slot), slot } end
		-- every style in every casing colour (screen 1: what a board built from the menu shows)
		for _, style in ipairs({ "board_modern_pole", "board_heritage_pole", "board_hanging" }) do
			for casing = 0, 15 do names[#names + 1] = { string.format("%s::/%s/%s_c%d.mdl", MOD_ID, MOD_ID, style, casing), 0 } end
		end
		for _, entry in ipairs(names) do
			local ok, id = pcall(api.res.modelRep.find, entry[1])
			if ok and type(id) == "number" and id >= 0 then models[id] = entry[2] end   -- the screen the model shows
		end
	end)
	state.models = models
	return models
end

-- The boards in an asset group: one per instance of a board model. Their id is the group's entity number
-- times 64 plus the instance's place (a group can hold several boards built together).
local function readAssetBoards(entity, out)
	local models = boardModels()
	local list = api.engine.getComponent(entity, api.type.ComponentType.MODEL_INSTANCE_LIST)
	if list == nil then return end
	local count = 0
	for i, instance in ipairs(list.fatInstances) do
		local slot = models[instance.modelId]
		if slot ~= nil then
			local x, y = placeOf(instance.transf)
			local _, _, z = frameOf(instance.transf)
			if x ~= nil then
				count = count + 1
				local id = entity * 64 + (i - 1)
				local board = { id = id, group = entity, asset = true, fixed = true, file = "asset", x = x, y = y, z = z or 0, transf = instance.transf,
					kind = state.core.DEPARTURES, slot = slot }
				local chosen = state.choices[id]
				if chosen ~= nil then board.platforms, board.mode, board.station, board.layout = chosen.platforms, chosen.mode, chosen.station, chosen.layout end
				if board.platforms == "" then board.platforms = nil end
				out[#out + 1] = board
			end
		end
	end
end

local function surveyStep()
	local survey = state.survey
	if survey == nil then
		if state.frame < state.surveyAt or #state.rebuilds > 0 then return end
		local ok, entities = pcall(function() return api.engine.getEntitiesWithComponent(api.type.ComponentType.CONSTRUCTION) end)
		if not ok or type(entities) ~= "table" then
			if not state.toldSurvey then
				state.toldSurvey = true
				log("the game's constructions could not be listed: " .. tostring(entities))
			end
			state.surveyAt = state.frame + SURVEY_PAUSE
			return
		end
		-- asset groups too: the game puts anything it takes for an asset into one
		local okGroups, groups = pcall(function() return api.engine.getEntitiesWithComponent(api.type.ComponentType.ASSET_GROUP) end)
		if not okGroups or type(groups) ~= "table" then groups = {} end
		state.survey = { entities = entities, groups = groups, cursor = 1, groupCursor = 1, boards = {} }
		return
	end
	local last = math.min(#survey.entities, survey.cursor + SURVEY_PER_FRAME - 1)
	for i = survey.cursor, last do
		local ok, board = pcall(readBoard, survey.entities[i])
		if ok and board ~= nil then
			survey.boards[#survey.boards + 1] = board
		elseif not ok then
			survey.failed = (survey.failed or 0) + 1
			survey.why = survey.why or tostring(board)
		end
	end
	survey.cursor = last + 1
	if survey.cursor <= #survey.entities then return end
	if not survey.placedTaken then
		survey.placedTaken = true
		for i, p in ipairs(state.placed or {}) do
			local id = 1000 + i   -- not an entity of the game: our own number
			local board = { id = id, placedIndex = i, asset = true, fixed = true, file = "placed", x = p.x, y = p.y, z = p.z,
				kind = p.kind == "arrivals" and state.core.ARRIVALS or state.core.DEPARTURES, slot = 0,
				platforms = p.platforms ~= "" and p.platforms or nil, mode = p.mode, layout = p.layout }
			-- the game's entity at that spot, for the live picture in the window
			pcall(function()
				local near = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), 3, api.type.ComponentType.ASSET_GROUP)
				if type(near) == "table" and near[1] ~= nil then board.group = near[1] end
			end)
			survey.boards[#survey.boards + 1] = board
			survey.inGroups = (survey.inGroups or 0) + 1
		end
	end
	if survey.groupCursor <= #survey.groups then
		local lastGroup = math.min(#survey.groups, survey.groupCursor + SURVEY_PER_FRAME - 1)
		for i = survey.groupCursor, lastGroup do
			local before = #survey.boards
			local ok, why = pcall(readAssetBoards, survey.groups[i], survey.boards)
			if not ok then
				survey.failed = (survey.failed or 0) + 1
				survey.why = survey.why or tostring(why)
			end
			survey.inGroups = (survey.inGroups or 0) + (#survey.boards - before)
		end
		survey.groupCursor = lastGroup + 1
		if survey.groupCursor <= #survey.groups then return end
	end
	do
		state.survey = nil
		state.surveyAt = state.frame + SURVEY_PAUSE
		if not state.toldFirstSurvey then
			state.toldFirstSurvey = true
			log(string.format("first search: %d constructions and %d asset groups looked at, %d board(s) found (%d in asset groups), %d could not be read%s",
				#survey.entities, #survey.groups, #survey.boards, survey.inGroups or 0, survey.failed or 0, survey.why ~= nil and (" (" .. survey.why .. ")") or ""))

		end
		state.surveys = (state.surveys or 0) + 1
		if state.surveys <= 3 or #survey.boards ~= (state.lastBoardCount or 0) then
			state.lastBoardCount = #survey.boards
			log(string.format("search %d: %d board(s) (%d in asset groups)", state.surveys, #survey.boards, survey.inGroups or 0))
		end
		if false then log(string.format("search %d: %d board(s); constructions seen: %s", state.surveys, #survey.boards,
			table.concat(state.seenFiles or {}, "; "))) end
		state.seenFiles = {}
		surveyDone(survey.boards, #survey.entities)
	end
end

-- Rebuilds a board with its station and its screen in its settings: the old one out, the new one in, in one
-- build command.
local function rebuildStep()
	if #state.rebuilds == 0 or state.frame < state.rebuildAt then return end
	state.rebuildAt = state.frame + REBUILD_EVERY
	local job = table.remove(state.rebuilds, 1)
	local board = job.board
	state.asked[board.id] = state.frame
	local ok, problem = pcall(function()
		local entity = api.type.SimpleProposal.ConstructionEntity.new()
		entity.fileName = board.file
		entity.params = { station = job.station, screen = job.slot + 1, seed = 0,
			platforms = board.platforms or "", mode = board.mode or "merged" }
		entity.transf = board.transf
		entity.name = "Departure board"
		entity.playerEntity = api.engine.util.getPlayer()
		local proposal = api.type.SimpleProposal.new()
		proposal.constructionsToAdd[1] = entity
		proposal.constructionsToRemove = { board.id }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false), function(_result, success)
			if state.toldRebuilds < 8 then
				state.toldRebuilds = state.toldRebuilds + 1
				log(string.format("board %d %s %s (screen %d)", board.id, success and "joined" or "could NOT be joined to",
					tostring(state.stationName[job.station] or job.station), job.slot + 1))
			end
		end)
	end)
	if not ok and state.toldRebuilds < 8 then
		state.toldRebuilds = state.toldRebuilds + 1
		log("board " .. tostring(board.id) .. ": the build command could not be made: " .. tostring(problem))
	end
end

-- ---- one screen's vehicles --------------------------------------------------------------------------------

-- The game counts stops from 0 where it names one by number (a vehicle's next stop, a line stop of a
-- station, a terminal); its lists are counted from 1 as lists are. Departure times are milliseconds of game
-- time, section times seconds.
local function vehiclesOf(station, kind, now, only)
	local core = state.core
	local out = {}
	local AT_TERMINAL = api.type.enum.TransportVehicleState.AT_TERMINAL
	local EN_ROUTE = api.type.enum.TransportVehicleState.EN_ROUTE
	for _, lineStop in ipairs(api.engine.system.lineSystem.getLineStops(station)) do
		local lineEntity, stopIndex = lineStop[1], lineStop[2]
		local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE)
		local n = #line.stops
		local target = stopIndex + 1
		if n >= 2 and target >= 1 and target <= n then
			local names = {}
			for i = 1, n do names[i] = nameOf(line.stops[i].stationGroup) end
			local here = names[target]
			local place = kind == core.ARRIVALS and core.origin(names, target, here) or core.destination(names, target, here)
			local platform = tostring((tonumber(line.stops[target].terminal) or 0) + 1)
			if only ~= nil and not only[tonumber(platform)] then n = 0 end   -- not a platform this board serves
			local lineName = nameOf(lineEntity)
			local calling = kind ~= core.ARRIVALS and core.callingAt(names, target) or nil
			local ids = api.engine.system.transportVehicleSystem.getLineVehicles(lineEntity)
			local vehicles, sections = {}, {}
			for v = 1, math.min(#ids, VEHICLES_PER_LINE) do
				local tv = api.engine.getComponent(ids[v], api.type.ComponentType.TRANSPORT_VEHICLE)
				if tv.state == AT_TERMINAL or tv.state == EN_ROUTE then
					local list = {}
					for i = 1, n do
						local seconds = tonumber(tv.sectionTimes[i]) or 0
						if seconds > 100000 then seconds = seconds / 1000 end   -- should a build count them in milliseconds
						list[i] = seconds
					end
					sections[#sections + 1] = list
					local stop = (tonumber(tv.stopIndex) or 0) + 1
					local before = stop == 1 and n or stop - 1
					local left = tonumber(tv.lineStopDepartures[before])
					vehicles[#vehicles + 1] = { stop = stop, atStop = tv.state == AT_TERMINAL,
						since = (left ~= nil and left > 0) and (now - left) / 1000 or nil }
				end
			end
			local averages = core.averages(n, sections)
			for _, vehicle in ipairs(vehicles) do
				local eta = core.eta(n, averages, vehicle, target)
				if eta ~= nil then
					-- a departures board shows when it leaves: a vehicle still on its way stands a while first
					if kind ~= core.ARRIVALS and eta > 0 then eta = eta + core.DWELL end
					out[#out + 1] = { eta = eta, place = place, line = lineName, platform = platform, calling = calling }
				end
			end
		end
	end
	return out
end

-- The trains of a station for the animation in a board window (see boards_core "Trains on the plan").
local ANIM_EVERY = 60   -- frames between two readings while a window watches the station
local function animOf(group, now)
	local core = state.core
	local plan = state.plans ~= nil and state.plans[group] or nil
	if plan == nil then return nil end
	local AT_TERMINAL = api.type.enum.TransportVehicleState.AT_TERMINAL
	local EN_ROUTE = api.type.enum.TransportVehicleState.EN_ROUTE
	state.modelLen = state.modelLen or {}
	local items = {}
	-- which side of the station another station lies, along the plan's x
	local function sideOf(otherGroup)
		local pos = state.stationPos ~= nil and state.stationPos[otherGroup] or nil
		if pos == nil then return nil end
		local a = core.planPoint(plan.frame, pos.x, pos.y)
		return a >= 0 and 1 or -1
	end
	for _, lineStop in ipairs(api.engine.system.lineSystem.getLineStops(group)) do
		pcall(function()
			local lineEntity, stopIndex = lineStop[1], lineStop[2]
			local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE)
			local n = #line.stops
			local target = stopIndex + 1
			if n < 2 or target < 1 or target > n then return end
			local platform = (tonumber(line.stops[target].terminal) or 0) + 1
			local before = target == 1 and n or target - 1
			local after = target == n and 1 or target + 1
			local fromSide = sideOf(line.stops[before].stationGroup) or -1
			local toSide = sideOf(line.stops[after].stationGroup) or 1
			if not state.toldSides then
				state.toldSides = true
				log(string.format("trains on the plan: line %s comes from %s (side %d) and goes on to %s (side %d)", tostring(nameOf(lineEntity)),
					tostring(nameOf(line.stops[before].stationGroup)), fromSide, tostring(nameOf(line.stops[after].stationGroup)), toSide))
			end
			local ids = api.engine.system.transportVehicleSystem.getLineVehicles(lineEntity)
			local vehicles, sections = {}, {}
			for v = 1, math.min(#ids, VEHICLES_PER_LINE) do
				local tv = api.engine.getComponent(ids[v], api.type.ComponentType.TRANSPORT_VEHICLE)
				local list = {}
				for i = 1, n do
					local seconds = tonumber(tv.sectionTimes[i]) or 0
					if seconds > 100000 then seconds = seconds / 1000 end
					list[i] = seconds
				end
				sections[#sections + 1] = list
				local stop = (tonumber(tv.stopIndex) or 0) + 1
				local previous = stop == 1 and n or stop - 1
				local left = tonumber(tv.lineStopDepartures[previous])
				vehicles[#vehicles + 1] = { id = ids[v], tv = tv, stop = stop, atStop = tv.state == AT_TERMINAL, moving = tv.state == EN_ROUTE,
					since = (left ~= nil and left > 0) and (now - left) / 1000 or nil, previous = previous }
			end
			local averages = core.averages(n, sections)
			for _, vehicle in ipairs(vehicles) do
				local item
				if vehicle.atStop and vehicle.stop == target then
					item = { phase = "stand", dir = fromSide }
				elseif vehicle.moving and vehicle.stop == target then
					local eta = core.eta(n, averages, vehicle, target)
					if eta ~= nil and eta <= core.ANIM_APPROACH then item = { phase = "in", t = eta, dir = fromSide } end
				elseif vehicle.moving and vehicle.previous == target and vehicle.since ~= nil and vehicle.since <= core.ANIM_LEAVE then
					item = { phase = "out", t = vehicle.since, dir = -toSide }
				end
				if item ~= nil then
					item.id = vehicle.id
					item.platform = platform
					item.cars = {}
					for _, part in ipairs(vehicle.tv.transportVehicleConfig.vehicles) do
						pcall(function()
							local id = part.part.modelId
							local model = api.res.modelRep.get(id)
							local length = state.modelLen[id]
							if length == nil then
								length = model.boundingInfo.bbMax.x - model.boundingInfo.bbMin.x
								state.modelLen[id] = length
							end
							local desc = model.metadata.description
							item.cars[#item.cars + 1] = { file = desc.icon20 or desc.iconSmall or "", length = length, reversed = part.part.reversed == true }
						end)
					end
					items[#items + 1] = item
				end
			end
		end)
	end
	return items
end

local function screenStep(b, clock, now)
	if type(b.boardRows) ~= "function" then return end
	if state.frame < state.screenAt then return end
	state.screenAt = state.frame + SCREEN_EVERY
	local core = state.core
	local slot
	for step = 0, core.SLOTS - 1 do
		local s = (state.nextSlot + step) % core.SLOTS
		if state.content[s] ~= nil then
			slot = s
			break
		end
	end
	if slot == nil then return end
	state.nextSlot = (slot + 1) % core.SLOTS
	local content = state.content[slot]
	local name = state.stationName[content.station] or nameOf(content.station)
	local only, list = core.platformSet(content.platforms)
	if only ~= nil and content.mode == "cycle" and #list > 1 then
		-- one platform at a time, each for core.CYCLE seconds
		local pick = list[(math.floor(clock / core.CYCLE) % #list) + 1]
		only = { [pick] = true }
	end
	local ok, vehicles = pcall(vehiclesOf, content.station, content.kind, now, only)
	if not ok then
		if state.toldScreens < 3 then
			state.toldScreens = state.toldScreens + 1
			log("screen " .. (slot + 1) .. " (" .. tostring(name) .. "): could not be worked out: " .. tostring(vehicles))
		end
		vehicles = {}
	end
	local layout, _colour, rgb = core.splitLayout(content.layout)
	if type(b.boardColour) == "function" then pcall(b.boardColour, tostring(slot), rgb) end
	local rows = core.layoutRows(layout, content.kind, clock, { name = name }, vehicles)
	local joined = table.concat(rows, "\n")
	if state.sent[slot] ~= joined then
		state.sent[slot] = joined
		b.boardRows(tostring(slot), rows[1], rows[2], rows[3], rows[4], rows[5])
		if state.toldScreens < 6 then
			state.toldScreens = state.toldScreens + 1
			log(string.format("screen %d: %s of %s, %d vehicle(s) known; first row \"%s\"", slot + 1, content.kind, tostring(name), #vehicles,
				(rows[2]:gsub("\t", " | "))))
		end
	end
end

-- ---- Boards as the player builds them -------------------------------------------------------------------------
-- The game puts a board into an asset group, which no script can find again. So, as in the older game's
-- displays mod, boards are noted when they are built: the game's build tool announces its proposal
-- ("builder.proposalCreate", with what it is about to add) and then that it was built ("builder.proposalApply").
-- The list is kept in this script's saved state, so it comes back with the save.
--   placed = { { x, y, z, kind, platforms, mode }, ... }

local EVENT_ID = "tf3api_departure_boards"

local function placedToText(list)
	local lines = {}
	for _, b in ipairs(list) do
		lines[#lines + 1] = string.format("%.2f %.2f %.2f %s %s %s %s", b.x, b.y, b.z, b.kind, b.platforms ~= "" and b.platforms or "-", b.mode or "merged", b.layout or "-")
	end
	return table.concat(lines, "\n")
end

local function placedFromText(text)
	local list = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local x, y, z, kind, platforms, mode, layout = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) ?(%S*)$")
		if tonumber(x) ~= nil then
			list[#list + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), kind = kind,
				platforms = platforms ~= "-" and platforms or "", mode = mode, layout = (layout ~= "" and layout ~= "-") and layout or nil }
		end
	end
	return list
end

-- hands the list to the simulation side, which keeps it in the save
function savePlaced()
	pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", EVENT_ID, "setBoards", { text = placedToText(state.placed) }))
	end)
end

local pendingBoards = nil   -- boards in the proposal the build tool shows now

-- Whether a built board still stands at its place: true, false, or nil when that cannot be told (the game's
-- lookup gives nothing at all). A board the game put into an asset group is found through the group's
-- model instances; one that stayed a construction through the construction itself.
local VERIFY_EVERY = 1800   -- frames between two checks besides the ones after a build
local function boardThere(p)
	local models, answered = boardModels(), false
	for _, kind in ipairs({ api.type.ComponentType.ASSET_GROUP, api.type.ComponentType.CONSTRUCTION }) do
		local ok, near = pcall(function()
			return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), 2.5, kind)
		end)
		if ok and type(near) == "table" then
			answered = true
			for _, entity in ipairs(near) do
				local found = false
				pcall(function()
					if kind == api.type.ComponentType.CONSTRUCTION then
						local file = tostring(api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION).fileName)
						if file:find(MOD_ID, 1, true) and file:find("board_", 1, true) then found = true end
					end
					local list = api.engine.getComponent(entity, api.type.ComponentType.MODEL_INSTANCE_LIST)
					for _, instance in ipairs(list ~= nil and list.fatInstances or {}) do
						if models[instance.modelId] ~= nil then
							local x, y = placeOf(instance.transf)
							if x ~= nil and (x - p.x) ^ 2 + (y - p.y) ^ 2 < 1.5 * 1.5 then found = true end
						end
					end
				end)
				if found then return true end
			end
		end
	end
	if answered then return false end
	return nil
end

-- takes board `id` (1000 + its place in the list) off the list
function forgetBoard(id, why)
	local index = id - 1000
	if state.placed == nil or state.placed[index] == nil then return end
	table.remove(state.placed, index)
	state.choices = {}   -- the ids after it have moved up; choices are in the list itself
	log(string.format("board %d taken off the list (%s); %d known", id, why, #state.placed))
	savePlaced()
	state.surveyAt = state.frame
end

-- Boards no longer standing are taken off. One that was never found by the lookup is left alone (the
-- lookup may not see it at all), so a board is only taken off once it has been seen and then is gone.
local function verifyPlaced()
	if state.placed == nil or #state.placed == 0 then return end
	for i = #state.placed, 1, -1 do
		local p = state.placed[i]
		local there = boardThere(p)
		if there == true then
			p.seen = true
		elseif there == false and p.seen then
			forgetBoard(1000 + i, "no longer there - bulldozed")
		end
	end
	if not state.toldVerify then
		state.toldVerify = true
		local seen = 0
		for _, p in ipairs(state.placed) do if p.seen then seen = seen + 1 end end
		log(string.format("built boards checked: %d of %d found where they were built", seen, #state.placed))
	end
end

local function boardsInProposal(proposal)
	local found = {}
	for _, entry in ipairs(proposal.toAdd or {}) do
		local file = tostring(entry.fileName)
		if file:find(MOD_ID, 1, true) ~= nil and file:find("board_", 1, true) ~= nil then
			local x, y, z = frameOf(entry.transf)
			if x ~= nil then
				found[#found + 1] = { x = x, y = y, z = z or 0, kind = file:find("arrivals", 1, true) and "arrivals" or "departures",
					platforms = "", mode = "merged" }
			end
		end
	end
	return found
end

local function guiHandleEvent(_params, _state, _guiState, _src, id, name, param)
	local ok, problem = pcall(function()
		if name == "builder.proposalCreate" then
			pendingBoards = nil
			if type(param) == "table" and param[1] ~= nil then
				local found = boardsInProposal(param[1])
				if #found > 0 then pendingBoards = found end
			end
		elseif name == "builder.proposalApply" and pendingBoards == nil then
			state.verifyAt = state.frame + 30; state.plans = nil   -- something was built or removed: look again once it has happened
		elseif name == "builder.proposalApply" and pendingBoards ~= nil then
			state.placed = state.placed or {}
			for _, board in ipairs(pendingBoards) do state.placed[#state.placed + 1] = board end
			log(string.format("%d board(s) built; %d known", #pendingBoards, #state.placed))
			pendingBoards = nil
			savePlaced()
			state.surveyAt = state.frame   -- take them in now
			state.verifyAt = state.frame + 30; state.plans = nil
		end
	end)
	if not ok and not state.toldEvent then
		state.toldEvent = true
		log("a build event could not be read: " .. tostring(problem))
	end
	return nil
end

-- Simulation side: only the saved list. Nothing is kept in variables here.
local function update(_params, s, _dt)
	if s ~= nil and not s:hasEventSubscriptions() then
		s:subscribeToEvent("setBoards")
		s:subscribeToEvent("builder.proposalCreate")
		s:subscribeToEvent("builder.proposalApply")
	end
end

local function handleEvent(_params, s, _src, id, name, param)
	if id ~= EVENT_ID or name ~= "setBoards" or s == nil then return end
	if type(param) == "table" and type(param.text) == "string" then s:set({ version = 1, text = param.text }) end
end

local function guiUpdate(_params, s, _guiState)
	if state.placed == nil then
		state.placed = {}
		local ok, saved = pcall(function() return s:get() end)
		if ok and type(saved) == "table" and type(saved.text) == "string" then state.placed = placedFromText(saved.text) end
		log(string.format("%d board(s) known from the save", #state.placed))
	end
	local b = bridge()
	if not b or state.failures > 20 then return end
	state.frame = state.frame + 1
	local ok, problem = pcall(function()
		local now = gameTimeNow()
		local seconds = clockOf(now)
		if seconds ~= state.lastSecond then
			state.lastSecond = seconds
			-- as text: the bridge takes no numbers from the game's Lua
			b.boardClock(seconds ~= nil and tostring(seconds) or "")
			if not state.told and seconds ~= nil then
				state.told = true
				log(string.format("clock: %d s (%02d:%02d)", seconds, math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60))
			end
		end
		if state.core ~= nil and now ~= nil then
			takeChoices()
			if state.frame >= (state.verifyAt or 120) then
				state.verifyAt = state.frame + VERIFY_EVERY
				verifyPlaced()
			end
			surveyStep()
			rebuildStep()
			screenStep(b, seconds or 0, now)
			-- the trains for the window that watches a station, about once a second
			if state.watching ~= nil and state.frame >= (state.animAt or 0) and type(b.post) == "function" then
				state.animAt = state.frame + ANIM_EVERY
				local okAnim, items = pcall(animOf, state.watching, now)
				if okAnim and items ~= nil then
					pcall(b.post, MOD_ID .. ".ui", table.concat({ "anim", tostring(state.watching), string.format("%d", now), state.core.animText(items) }, "	"))
				elseif not okAnim and not state.toldAnim then
					state.toldAnim = true
					log("the trains for the window could not be worked out: " .. tostring(items))
				end
			end
		end
	end)
	if not ok then
		state.failures = state.failures + 1
		if state.failures == 1 then log("update failed: " .. tostring(problem)) end
	end
end

function data()
	return {
		guiUpdate = guiUpdate,
		guiHandleEvent = guiHandleEvent,
		update = update,
		handleEvent = handleEvent,
		clockOf = clockOf,   -- for tests
		placedToText = placedToText, placedFromText = placedFromText,
	}
end
