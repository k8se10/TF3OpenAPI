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

print("left-hand traffic test: ALL OK")
