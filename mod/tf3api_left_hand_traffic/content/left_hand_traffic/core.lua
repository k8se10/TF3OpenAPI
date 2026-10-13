-- TF3OpenAPI left-hand traffic: the rules, free of the game so that they can be tested outside it.
--
-- The game has no setting for the side of the road. Which side traffic keeps to follows from data alone:
-- every lane of a street says whether it runs with the street or against it, and the lanes are listed from
-- one kerb to the other. Turning the direction of every vehicle lane of a two-way street moves traffic to
-- the other side without moving a single lane.

local core = {}

-- what drives on a street
local ROAD_MODES = { CAR = true, BUS = true, TRUCK = true, TRAM = true, ELECTRIC_TRAM = true }

-- Is this lane one that road vehicles use? (transportModes is a list of names.)
function core.isRoadLane(lane)
	if type(lane) ~= "table" or type(lane.transportModes) ~= "table" then return false end
	for _, mode in pairs(lane.transportModes) do
		if ROAD_MODES[mode] then return true end
	end
	return false
end

-- A street template, changed in place. Returns what was done and how many lanes it touched:
--   "two-way"  every vehicle lane now runs the other way: traffic keeps left
--   "one-way"  the direction stays (a one-way street is not turned round); what each lane is for is laid
--              out from the other kerb, so that a kerb-side bus or tram lane is at the left kerb
--   "none"     not a street, or no lane for road vehicles
function core.street(template)
	if type(template) ~= "table" or template.roadType ~= "STREET" or type(template.laneConfigs) ~= "table" then return "none", 0 end
	local lanes, forward, backward = {}, false, false
	for _, lane in ipairs(template.laneConfigs) do
		if core.isRoadLane(lane) and type(lane.forward) == "boolean" then
			lanes[#lanes + 1] = lane
			if lane.forward then forward = true else backward = true end
		end
	end
	if #lanes == 0 then return "none", 0 end
	template.busAndTramRight = false
	if forward and backward then
		for _, lane in ipairs(lanes) do lane.forward = not lane.forward end
		return "two-way", #lanes
	end
	local modes = {}
	for i, lane in ipairs(lanes) do modes[i] = lane.transportModes end
	for i, lane in ipairs(lanes) do lane.transportModes = modes[#lanes - i + 1] end
	return "one-way", #lanes
end

-- ---------------------------------------------------------------------------------------------------
-- Mirroring a vehicle. A placement is the game's 16 numbers: three axes and a position, four numbers each.

-- a * b: the placement that does b first, then a
function core.mul(a, b)
	local out = {}
	for col = 0, 3 do
		for row = 1, 4 do
			local sum = 0
			for k = 0, 3 do sum = sum + a[k * 4 + row] * b[col * 4 + k + 1] end
			out[col * 4 + row] = sum
		end
	end
	return out
end

-- left and right swapped: the mirror in the plane through the vehicle's length and height
core.MIRROR = { 1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

-- A vehicle's root part, mirrored. Everything below it follows.
function core.mirrorRoot(transf)
	return core.mul(core.MIRROR, transf or { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 })
end

-- Text on a mirrored vehicle. A label is placed by one corner: its first axis runs along the text, its
-- second up, its third out of the surface, and the text is `width` long along the first (in the label's own
-- units; the axis carries the scale). A mirror alone would turn the writing backwards. So the label is
-- turned round inside its own frame: it starts at what was the far end of its line and runs back. The
-- text then covers exactly the mirrored place of where it was, and reads the right way.
--   follows = true   the label hangs on a part that is itself mirrored (it follows the root): only the
--                    turn inside its own frame is needed
--   follows = false  the label is placed in the model's own space: the mirror is applied as well
function core.mirrorLabel(transf, width, follows)
	local flip = { -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, width, 0, 0, 1 }   -- u -> width - u
	local out = core.mul(transf, flip)
	if not follows then out = core.mul(core.MIRROR, out) end
	return out
end

-- Which side of a vehicle its driver sits on, from the seats marked for the crew: "left", "right",
-- "centre", "both", or nil when it has no crew seat. Left is the side of growing y (the vehicle looks along x).
function core.driverSide(model)
	local seats = type(model) == "table" and type(model.metadata) == "table" and type(model.metadata.seatProvider) == "table"
		and model.metadata.seatProvider.seats
	if type(seats) ~= "table" then return nil end
	local left, right, centre = 0, 0, 0
	for _, seat in ipairs(seats) do
		if type(seat) == "table" and seat.crew == true and type(seat.transf) == "table" and #seat.transf == 16 then
			local y = seat.transf[14]
			if y > 0.15 then left = left + 1 elseif y < -0.15 then right = right + 1 else centre = centre + 1 end
		end
	end
	if left + right + centre == 0 then return nil end
	if left > 0 and right > 0 then return "both" end
	if left > 0 then return "left" end
	if right > 0 then return "right" end
	return "centre"
end

-- events that belong to one side of a vehicle; a mirrored part answers to the other side's
local SIDED = {
	{ "open_doors_left", "open_doors_right" }, { "close_doors_left", "close_doors_right" },
	{ "blink_lights_left_on", "blink_lights_right_on" }, { "blink_lights_left_off", "blink_lights_right_off" },
}

-- The parts of a mirrored vehicle: what moved for the left now moves for the right. `node` is a part with
-- its `children`; each table is changed once even when two levels of detail share it.
function core.swapSides(node, seen)
	seen = seen or {}
	if type(node) ~= "table" or seen[node] then return 0 end
	seen[node] = true
	local changed = 0
	if type(node.animations) == "table" then
		for _, pair in ipairs(SIDED) do
			local a, b = node.animations[pair[1]], node.animations[pair[2]]
			if a ~= nil or b ~= nil then
				node.animations[pair[1]], node.animations[pair[2]] = b, a
				changed = changed + 1
			end
		end
	end
	for _, child in ipairs(type(node.children) == "table" and node.children or {}) do
		changed = changed + core.swapSides(child, seen)
	end
	return changed
end

-- A whole vehicle model mirrored, in place: every level of detail's root, the sided events of its parts,
-- and its text labels. A label that names a part follows that part and is only turned round in its own
-- frame; one that names none is placed in the model's space and is mirrored as well.
-- Returns what was done: { roots, events, labels }.
function core.mirrorVehicle(model)
	local done = { roots = 0, events = 0, labels = 0 }
	if type(model) ~= "table" or type(model.lods) ~= "table" then return done end
	local roots, seen = {}, {}
	for _, lod in ipairs(model.lods) do
		local node = type(lod) == "table" and lod.node
		if type(node) == "table" and not roots[node] then
			roots[node] = true
			node.transf = core.mirrorRoot(node.transf)
			done.roots = done.roots + 1
			done.events = done.events + core.swapSides(node, seen)
		end
	end
	local labels = type(model.metadata) == "table" and type(model.metadata.labelList) == "table" and model.metadata.labelList.labels
	for _, label in ipairs(type(labels) == "table" and labels or {}) do
		if type(label) == "table" and type(label.transf) == "table" and #label.transf == 16 and type(label.size) == "table" then
			local follows = type(label.childId) == "string" and label.childId ~= ""
			label.transf = core.mirrorLabel(label.transf, tonumber(label.size[1]) or 0, follows)
			done.labels = done.labels + 1
		end
	end
	return done
end

-- ---------------------------------------------------------------------------------------------------
-- The lanes inside a building (a station, a depot, an industry's yard). A finished construction is a list of
-- sub-constructions, each with lane lists: { transportModes, nodes, forwardOnly, ... }. The nodes of a lane
-- list come in pairs, each pair one piece of lane from its first node to its second; a node is a position, a
-- direction and a width. (The form is the game's own: scripts/construction/construction_util_serialized.)

-- One lane list turned round, in place: each piece runs from what was its end to what was its start, with
-- its directions turned. The pieces keep their places in the list, so a node numbered n is afterwards the
-- node numbered n + 1 (n even) or n - 1 (n odd).
function core.reverseLaneList(list)
	local nodes = list.nodes
	for i = 1, #nodes - 1, 2 do
		local a, b = nodes[i], nodes[i + 1]
		for _, node in ipairs({ a, b }) do
			local tangent = node[2]
			node[2] = { -tangent[1], -tangent[2], -tangent[3] }
		end
		nodes[i], nodes[i + 1] = b, a
	end
	list.forwardOnly = true   -- a lane that may be driven both ways would undo the turn
end

-- Can this lane list be turned? Only a lane for road vehicles alone, made of whole pieces.
function core.isRoadLaneList(list)
	if type(list) ~= "table" or type(list.nodes) ~= "table" or #list.nodes == 0 or #list.nodes % 2 ~= 0 then return false end
	if not core.isRoadLane(list) then return false end
	for _, mode in pairs(list.transportModes) do
		if not ROAD_MODES[mode] then return false end   -- shared with people, trains, ships: left alone
	end
	for _, node in ipairs(list.nodes) do
		if type(node) ~= "table" or type(node[1]) ~= "table" or type(node[2]) ~= "table" then return false end
	end
	return true
end

-- A finished construction, changed in place: every road lane list turned, and every stop that names a
-- node of a turned list (a pair: lane list counted from 0, node counted from 0) re-pointed at the node
-- that is now at the same place. A depot's way in and way out change places: vehicles came in at the end
-- of one lane and left from the start of another; with both lanes turned they leave from where they came
-- in and come in where they left. Returns how many lane lists and how many stops (and depot ways) were
-- changed.
function core.construction(result)
	local lists, stops = 0, 0
	if type(result) ~= "table" or type(result.subconstructions) ~= "table" then return lists, stops end
	for _, sub in ipairs(result.subconstructions) do
		if type(sub) == "table" and type(sub.laneLists) == "table" then
			local turned = {}
			for index, list in ipairs(sub.laneLists) do
				if core.isRoadLaneList(list) then
					core.reverseLaneList(list)
					turned[index - 1] = true
					lists = lists + 1
				end
			end
			local function moved(at)   -- a { lane list, node } pair on a turned list: the node now at that place
				if type(at) == "table" and turned[at[1]] and type(at[2]) == "number" then
					return { at[1], at[2] % 2 == 0 and at[2] + 1 or at[2] - 1 }
				end
				return nil
			end
			local depot = sub.depot
			if type(depot) == "table" and type(depot.inNodes) == "table" and type(depot.outNodes) == "table" then
				local all, newIn, newOut = true, {}, {}
				for i, at in ipairs(depot.outNodes) do newIn[i] = moved(at) all = all and newIn[i] ~= nil end
				for i, at in ipairs(depot.inNodes) do newOut[i] = moved(at) all = all and newOut[i] ~= nil end
				if all and #newIn > 0 and #newOut > 0 then   -- only when every way is on a turned lane
					depot.inNodes, depot.outNodes = newIn, newOut
					stops = stops + #newIn + #newOut
				end
			end
			local terminals = type(sub.station) == "table" and sub.station.terminals
			for _, terminal in ipairs(type(terminals) == "table" and terminals or {}) do
				local at = type(terminal) == "table" and terminal.vehicleNode
				if type(at) == "table" and turned[at[1]] and type(at[2]) == "number" then
					at[2] = at[2] % 2 == 0 and at[2] + 1 or at[2] - 1
					stops = stops + 1
				end
			end
		end
	end
	return lists, stops
end

-- Streets a construction lays itself (a roundabout, the ramps of an interchange, a depot's entrance) are
-- "edge lists": { type = "STREET", params = { type = <street type> }, edges = pairs of { position,
-- direction }, snapNodes, freeNodes, ... }, nodes numbered from 0. A two-way street needs nothing: its type
-- already drives on the left. A ONE-WAY street laid by a construction runs the way the construction drew
-- it, and a junction drawn for traffic on the right is, with every one-way piece turned round, the same
-- junction for traffic on the left (every way through it is driven backwards). So each piece of a one-way
-- edge list is turned, and whatever names its nodes follows.
-- `isOneWay(streetTypeName)` says whether a street type is one-way. Returns how many edge lists were turned.
local NODE_LISTS = { "snapNodes", "freeNodes", "trafficLightYes", "trafficLightNo" }

function core.edgeLists(lists, isOneWay)
	local turnedLists = 0
	for _, list in ipairs(type(lists) == "table" and lists or {}) do
		local kind = type(list) == "table" and type(list.params) == "table" and list.params.type
		if type(list) == "table" and list.type == "STREET" and type(list.edges) == "table" and #list.edges % 2 == 0
			and type(kind) == "string" and isOneWay(kind) then
			local edges = list.edges
			for i = 1, #edges - 1, 2 do
				local a, b = edges[i], edges[i + 1]
				for _, node in ipairs({ a, b }) do
					local tangent = node[2]
					node[2] = { -tangent[1], -tangent[2], -tangent[3] }
				end
				edges[i], edges[i + 1] = b, a
			end
			local function other(n) return n % 2 == 0 and n + 1 or n - 1 end
			for _, key in ipairs(NODE_LISTS) do
				if type(list[key]) == "table" then
					for index, n in ipairs(list[key]) do list[key][index] = other(n) end
				end
			end
			if type(list.tag2nodes) == "table" then
				for _, nodes in pairs(list.tag2nodes) do
					for index, n in ipairs(type(nodes) == "table" and nodes or {}) do nodes[index] = other(n) end
				end
			end
			turnedLists = turnedLists + 1
		end
	end
	return turnedLists
end

return core
