-- Run from the repository root:  lua tools/tests/left_hand_traffic_test.lua
local core = dofile("mod/tf3api_left_hand_traffic/content/left_hand_traffic/core.lua")

local function lane(forward, ...) return { forward = forward, transportModes = { ... }, width = 3 } end

-- 1. a two-way street: every vehicle lane turns, pavements stay, nothing moves
do
	local street = { roadType = "STREET", busAndTramRight = true, laneConfigs = {
		lane(false, "PERSON", "CARGO"), lane(false, "BUS"), lane(false, "CAR", "BUS", "TRUCK"),
		lane(true, "CAR", "BUS", "TRUCK"), lane(true, "BUS"), lane(true, "PERSON", "CARGO"),
	} }
	local what, n = core.street(street)
	assert(what == "two-way" and n == 4)
	local l = street.laneConfigs
	assert(l[1].forward == false and l[6].forward == true, "pavements are not touched")
	assert(l[2].forward == true and l[3].forward == true and l[4].forward == false and l[5].forward == false)
	assert(l[2].transportModes[1] == "BUS" and #l[3].transportModes == 3, "what a lane is for stays with the lane")
	assert(street.busAndTramRight == false)
	-- twice is as before: the rule is its own undoing
	core.street(street)
	assert(l[2].forward == false and l[4].forward == true)
end

-- 2. a one-way street keeps its direction; the bus lane changes kerb
do
	local street = { roadType = "STREET", laneConfigs = {
		lane(true, "PERSON"), lane(true, "CAR", "TRUCK"), lane(true, "CAR", "TRUCK"), lane(true, "BUS"), lane(true, "PERSON"),
	} }
	local what, n = core.street(street)
	assert(what == "one-way" and n == 3)
	local l = street.laneConfigs
	assert(l[2].forward and l[3].forward and l[4].forward)
	assert(l[2].transportModes[1] == "BUS" and l[4].transportModes[1] == "CAR")
end

-- 3. what is not a street for road vehicles is left alone
do
	local track = { roadType = "TRACK", laneConfigs = { lane(true, "TRAIN") } }
	assert(core.street(track) == "none" and track.busAndTramRight == nil)
	local path = { roadType = "STREET", laneConfigs = { lane(true, "PERSON"), lane(false, "PERSON") } }
	assert(core.street(path) == "none" and path.laneConfigs[1].forward == true)
	assert(core.street(nil) == "none" and core.street({}) == "none")
end

-- 4. text on a mirrored vehicle: same place mirrored, reading the right way
do
	local function point(m, u, v, w)   -- where a point of the label's own frame is in the model
		return { m[1] * u + m[5] * v + m[9] * w + m[13], m[2] * u + m[6] * v + m[10] * w + m[14], m[3] * u + m[7] * v + m[11] * w + m[15] }
	end
	local function near(a, b) return math.abs(a[1] - b[1]) < 1e-9 and math.abs(a[2] - b[2]) < 1e-9 and math.abs(a[3] - b[3]) < 1e-9 end
	-- a blind on the right side of a bus: seen from that side the text runs towards the front (+x), up is
	-- +z, it faces -y; scaled 0.01, 150 units long, 20 high
	local label = { 0.01, 0, 0, 0, 0, 0, 0.01, 0, 0, -0.01, 0, 0, 2.0, -1.25, 2.5, 1 }
	local width, height = 150, 20
	local mirrored = core.mirrorLabel(label, width, false)
	-- the text's left end is now where the mirror image of its right end was, and so on
	local function image(p) return { p[1], -p[2], p[3] } end
	assert(near(point(mirrored, 0, 0, 0), image(point(label, width, 0, 0))))
	assert(near(point(mirrored, width, 0, 0), image(point(label, 0, 0, 0))))
	assert(near(point(mirrored, 0, height, 0), image(point(label, width, height, 0))), "up stays up")
	assert(near(point(mirrored, width / 2, height / 2, 0), image(point(label, width / 2, height / 2, 0))), "the middle of the text is the middle of the mirrored blind")
	-- it faces out of the mirrored side (+y now), and its frame is right-handed again: the writing is not backwards
	local x = { mirrored[1], mirrored[2], mirrored[3] }
	local y = { mirrored[5], mirrored[6], mirrored[7] }
	local z = { mirrored[9], mirrored[10], mirrored[11] }
	assert(z[2] > 0)
	local cross = { x[2] * y[3] - x[3] * y[2], x[3] * y[1] - x[1] * y[3], x[1] * y[2] - x[2] * y[1] }
	assert(cross[1] * z[1] + cross[2] * z[2] + cross[3] * z[3] > 0, "the frame keeps its handedness")
	-- on a part that is itself mirrored, the part's mirror and the label's own turn give the same result
	local onPart = core.mirrorLabel(label, width, true)
	local through = core.mul(core.MIRROR, onPart)
	for i = 1, 16 do assert(math.abs(through[i] - mirrored[i]) < 1e-9) end
	-- the root: a mirror, and twice is as before
	local root = core.mirrorRoot({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.5, 0.25, 0, 1 })
	assert(root[6] == -1 and root[14] == -0.25 and root[13] == 0.5)
	local back = core.mirrorRoot(root)
	assert(back[6] == 1 and back[14] == 0.25)
end

-- 5. a whole vehicle: roots mirrored once, sided events exchanged, labels turned, the driver's side read
do
	local ID = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
	local door = { name = "d1", transf = ID, animations = { open_doors_right = { id = "o" }, close_doors_right = { id = "c" }, forever = { id = "f" } } }
	local lamp = { name = "bl", transf = ID, animations = { blink_lights_left_on = { id = "on" }, blink_lights_left_off = { id = "off" } } }
	local body = { name = "body", transf = ID, children = { door, lamp } }
	local shared = { name = "root", transf = ID, children = { body } }
	local model = {
		lods = { { node = shared }, { node = shared }, { node = { name = "far", transf = ID } } },
		metadata = {
			seatProvider = { seats = { { crew = true, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 4, 0.7, 1, 1 } }, { transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -0.7, 1, 1 } } } },
			labelList = { labels = {
				{ childId = "body", size = { 150, 20 }, transf = { 0.01, 0, 0, 0, 0, 0, 0.01, 0, 0, -0.01, 0, 0, 2, -1.25, 2.5, 1 } },
				{ childId = "", size = { 100, 20 }, transf = { 0.01, 0, 0, 0, 0, 0, 0.01, 0, 0, -0.01, 0, 0, 2, -1.25, 2.5, 1 } },
			} },
		},
	}
	assert(core.driverSide(model) == "left")
	assert(core.driverSide({ metadata = { seatProvider = { seats = { { transf = ID } } } } }) == nil, "no crew seat: nothing to go by")
	local done = core.mirrorVehicle(model)
	assert(done.roots == 2 and done.labels == 2, "a root shared by two levels of detail is mirrored once")
	assert(shared.transf[6] == -1)
	assert(door.animations.open_doors_left.id == "o" and door.animations.open_doors_right == nil and door.animations.close_doors_left.id == "c")
	assert(door.animations.forever.id == "f", "what has no side is left alone")
	assert(lamp.animations.blink_lights_right_on.id == "on" and lamp.animations.blink_lights_left_on == nil)
	local onPart, free = model.metadata.labelList.labels[1].transf, model.metadata.labelList.labels[2].transf
	assert(math.abs(onPart[13] - 3.5) < 1e-9 and onPart[14] == -1.25 and onPart[1] == -0.01, "on a part: turned in its own frame only")
	assert(math.abs(free[13] - 3.0) < 1e-9 and free[14] == 1.25, "in the model's space: mirrored too")
end

-- 6. the lanes inside a building
do
	local function node(x, y, tx, ty) return { { x, y, 0 }, { tx, ty, 0 }, 3 } end
	local bus = { transportModes = { "BUS" }, nodes = { node(0, 0, 10, 0), node(10, 0, 10, 0), node(10, 0, 0, 5), node(10, 5, 0, 5) } }
	local walk = { transportModes = { "PERSON" }, nodes = { node(0, 2, 10, 0), node(10, 2, 10, 0) } }
	local shared = { transportModes = { "TRUCK", "PERSON" }, nodes = { node(0, 4, 1, 0), node(1, 4, 1, 0) } }
	local odd = { transportModes = { "TRUCK" }, nodes = { node(0, 6, 1, 0) } }
	local result = { subconstructions = { {
		laneLists = { walk, bus, shared, odd },
		station = { terminals = {
			{ vehicleNode = { 1, 1 }, personNodes = { { 0, 1 } } },    -- on the bus lane: its first piece's end
			{ vehicleNode = { 1, 2 } },
			{ vehicleNode = { -1, 4 } },                                -- on a street piece, not a lane list
			{ vehicleNode = { 0, 0 } },
		} },
	} } }
	local lists, stops = core.construction(result)
	assert(lists == 1 and stops == 2, "only the lane for road vehicles alone is turned")
	-- the first piece now runs from (10,0) to (0,0), pointing back
	assert(bus.nodes[1][1][1] == 10 and bus.nodes[2][1][1] == 0 and bus.nodes[1][2][1] == -10 and bus.forwardOnly == true)
	assert(bus.nodes[3][1][2] == 5 and bus.nodes[4][1][2] == 0 and bus.nodes[3][2][2] == -5, "each piece is turned in its own place")
	local t = result.subconstructions[1].station.terminals
	assert(t[1].vehicleNode[2] == 0 and t[2].vehicleNode[2] == 3, "a stop stays at its place: the node there has the neighbouring number now")
	assert(t[1].personNodes[1][2] == 1 and t[3].vehicleNode[2] == 4 and t[4].vehicleNode[2] == 0, "people and street pieces are not touched")
	assert(walk.nodes[1][1][1] == 0 and walk.forwardOnly == nil and shared.nodes[1][1][1] == 0 and odd.nodes[1][1][1] == 0)
	-- where the stop was is where it is: same position before and after
	assert(bus.nodes[t[1].vehicleNode[2] + 1][1][1] == 10)
	local a, b = core.construction({})
	assert(a == 0 and b == 0)
	-- a depot, as the game's own road depot is laid out: a lane in (ends at the shed) and a lane out
	local laneIn = { transportModes = { "BUS", "TRUCK" }, nodes = { node(0, -2, 5, 0), node(5, -2, 5, 0), node(5, -2, 5, 0), node(10, -2, 5, 0), node(10, -2, 5, 0), node(15, -2, 5, 0) } }
	local laneOut = { transportModes = { "BUS", "TRUCK" }, nodes = { node(15, 2, -5, 0), node(10, 2, -5, 0), node(10, 2, -5, 0), node(5, 2, -5, 0), node(5, 2, -5, 0), node(0, 2, -5, 0) } }
	local depot = { subconstructions = { { laneLists = { laneOut, laneIn }, depot = { inNodes = { { 1, 5 } }, outNodes = { { 0, 0 } } } } } }
	local l2, s2 = core.construction(depot)
	assert(l2 == 2 and s2 == 2)
	local d = depot.subconstructions[1].depot
	-- vehicles now leave from the shed end of what was the way in, and arrive at the shed end of what was the way out
	assert(d.outNodes[1][1] == 1 and d.outNodes[1][2] == 4 and laneIn.nodes[5][1][1] == 15 and laneIn.nodes[5][1][2] == -2)
	assert(d.inNodes[1][1] == 0 and d.inNodes[1][2] == 1 and laneOut.nodes[2][1][1] == 15 and laneOut.nodes[2][1][2] == 2)
	-- a turned lane is driven from its last piece to its first: the way out starts a piece, the way in ends one
	assert(d.outNodes[1][2] % 2 == 0 and d.inNodes[1][2] % 2 == 1)
end

-- 8. vehicles: who is mirrored, and everything that has to move with a mirror
do
	local vehicle = dofile("mod/tf3api_left_hand_traffic/content/left_hand_traffic/vehicle.lua")
	local I = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
	local function bus(doorSide, driverSide)
		local door = { name = "door", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, doorSide * 1.2, 0.5, 1 },
			animations = { open_doors_right = { id = "r" }, close_doors_right = { id = "rc" } } }
		local root = { name = "root", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }, children = { door },
			animations = { blink_lights_left_on = { id = "bl" } } }
		local model = {
			version = 2,
			boundingInfo = { bbMin = { -5, -1.3, 0 }, bbMax = { 5, 1.5, 3 } },
			lods = { { node = root, static = false }, { node = root, static = false } },   -- two levels share one root
			collider = { type = "BOX", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0.4, 0.5, 1 }, params = { halfExtents = { 4, 1, 1 } } },
			metadata = {
				roadVehicle = {},
				transportVehicle = { carrier = "ROAD", entrances = doorSide ~= 0 and { { path = { { 3, doorSide * 1.4, 0 }, { 3, doorSide * 0.4, 0 } } } } or nil },
				seatProvider = { seats = { { crew = true, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 4, driverSide * 0.5, 1.2, 1 } },
					{ crew = false, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, -0.5, 1.0, 1 } } } },
				extent = { bbMin = { -5, -1.3, 0 }, bbMax = { 5, 1.5, 3 } },
				lightSourceList = { lights = { { transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 0.8, 0.6, 1 } },
					{ meshId = "lamp", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 9, 9, 9, 1 } } } },
				particleSystem = { emitters = { { position = { -5, 0.3, 0.5 }, velocity = { value = { 0, 0.5, 1 } } },
					{ child = "root", position = { 7, 7, 7 } } } },
				labelList = { labels = { { childId = "", size = { 100, 10 }, transf = { 0.01, 0, 0, 0, 0, 0.01, 0, 0, 0, 0, 0.01, 0, 1, -1.2, 2, 1 } } } },
			},
		}
		return model
	end
	local function near(a, b) return math.abs(a - b) < 1e-9 end

	-- doors on the right: mirrored
	local original = bus(-1, 1)
	local mirrored, note = vehicle.adapt(core, "::/vehicle/bus/test.mdl", original)
	assert(mirrored ~= original and note:find("^mirrored"), note)
	assert(original.lods[1].node.transf[6] == 1 and original.boundingInfo.bbMin[2] == -1.3, "the original is not touched")
	local root = mirrored.lods[1].node
	assert(root == mirrored.lods[2].node, "a part shared by two levels stays shared, and is mirrored once")
	assert(root.transf[6] == -1 and root.transf[1] == 1, "the root is reflected")
	assert(root.animations.blink_lights_right_on and not root.animations.blink_lights_left_on, "blinkers swap sides")
	assert(root.children[1].animations.open_doors_left and not root.children[1].animations.open_doors_right, "doors swap sides")
	assert(near(mirrored.boundingInfo.bbMin[2], -1.5) and near(mirrored.boundingInfo.bbMax[2], 1.3), "bounds mirrored")
	assert(near(mirrored.metadata.extent.bbMin[2], -1.5) and near(mirrored.metadata.extent.bbMax[2], 1.3))
	local entrance = mirrored.metadata.transportVehicle.entrances[1].path
	assert(near(entrance[1][2], 1.4) and near(entrance[2][2], 0.4) and original.metadata.transportVehicle.entrances[1].path[1][2] == -1.4)
	local seat = mirrored.metadata.seatProvider.seats[1].transf
	assert(near(seat[14], 0.5) and near(seat[6], -1), "a seat follows the root and is turned back in its own frame")
	assert(near(mirrored.collider.transf[14], -0.4), "a collider in the model's space is reflected")
	local lights = mirrored.metadata.lightSourceList.lights
	assert(near(lights[1].transf[14], -0.8) and lights[2].transf[14] == 9, "a light with no part is reflected, one on a part is not")
	local emitters = mirrored.metadata.particleSystem.emitters
	assert(near(emitters[1].position[2], -0.3) and near(emitters[1].velocity.value[2], -0.5) and emitters[2].position[2] == 7)
	assert(mirrored.metadata.transformatorConfig.params[vehicle.MARKER].mirrored == true, "marked")
	-- one already marked is not mirrored again
	local again, note2 = vehicle.adapt(core, "::/vehicle/bus/test.mdl", mirrored)
	assert(again == mirrored and note2:find("^kept"), note2)

	-- doors already on the left; a driver on the right with no doors; a centred door; a train; a bus with nothing to go by
	local _, k1 = vehicle.adapt(core, "a", bus(1, -1)); assert(k1:find("^kept"), k1)
	local truck = bus(0, -1)
	local _, k2 = vehicle.adapt(core, "b", truck); assert(k2:find("^kept"), k2)
	local leftDriver = bus(0, 1)
	local m3, k3 = vehicle.adapt(core, "c", leftDriver); assert(m3 ~= leftDriver and k3:find("driver on the left"), k3)
	local train = bus(-1, 1); train.metadata.railVehicle = {}; train.metadata.roadVehicle = nil
	local _, k4 = vehicle.adapt(core, "d", train); assert(k4:find("not a road vehicle"), k4)
	local tram = bus(-1, 1); tram.metadata.transportVehicle.carrier = "TRAM"
	local m5 = vehicle.adapt(core, "e", tram); assert(m5 ~= tram, "a tram is a road vehicle for this")
	local ship = bus(-1, 1); ship.metadata.waterVehicle = {}
	local _, k6 = vehicle.adapt(core, "f", ship); assert(k6:find("not a road vehicle"), k6)
	-- anything odd leaves the model as it was
	local odd = bus(-1, 1); odd.lods[1].node.transf[3] = 0 / 0
	local same, k7 = vehicle.adapt(core, "g", odd); assert(same == odd and k7:find("^kept: unsafe"), k7)
	local noLods = bus(-1, 1); noLods.lods = nil
	local same2, k8 = vehicle.adapt(core, "h", noLods); assert(same2 == noLods and k8:find("^kept"), k8)
	assert(vehicle.adapt(core, "i", nil) == nil and select(2, vehicle.adapt(core, "i", "text")):find("^kept"))
	-- a bus with a door on each side is not decided by its doors; its driver says
	local mixed = bus(-1, 1); mixed.metadata.transportVehicle.entrances[2] = { path = { { 3, 1.4, 0 } } }
	local _, k9 = vehicle.adapt(core, "j", mixed); assert(k9:find("kept"), k9)
	assert(vehicle.entranceSide(bus(-1, 1).metadata) == "right" and vehicle.entranceSide(bus(1, 1).metadata) == "left")
	assert(vehicle.entranceSide({}) == "none" and vehicle.entranceSide(bus(0, 1).metadata) == "none")
end

print("left-hand traffic test: ALL OK")
