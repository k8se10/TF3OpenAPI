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

print("left-hand traffic test: ALL OK")
