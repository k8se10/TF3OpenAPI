-- Run from the repository root:  lua tools/tests/save_guard_test.lua
local core = dofile("mod/tf3api_save_guard/content/save_guard/sides.lua")

local function lane(forward, ...) return { forward = forward, transportModes = { ... }, width = 3 } end

-- the side a street type was written for, and changing it
do
	local function two(rightHand)
		-- kerb to kerb: pavement, then lanes; with right-hand traffic the lanes that run with the street are the later ones
		return { roadType = "STREET", laneConfigs = {
			lane(true, "PERSON"), lane(not rightHand, "CAR", "BUS"), lane(not rightHand, "CAR", "BUS"),
			lane(rightHand, "CAR", "BUS"), lane(rightHand, "CAR", "BUS"), lane(true, "PERSON"),
		} }
	end
	local rht, lht = two(true), two(false)
	assert(core.templateSide(rht) == "R" and core.templateSide(lht) == "L")
	assert(core.templateSide({ roadType = "STREET", laneConfigs = { lane(true, "CAR"), lane(true, "CAR") } }) == nil, "one-way: no side")
	assert(core.templateSide({ roadType = "TRACK", laneConfigs = { lane(true, "TRAIN"), lane(false, "TRAIN") } }) == nil)
	assert(core.templateSide({ roadType = "STREET", laneConfigs = { lane(true, "PERSON"), lane(false, "PERSON") } }) == nil, "a path")
	-- setSide: only a type written for the other side changes; twice is as once
	assert(core.setSide(rht, "L") == true and core.templateSide(rht) == "L" and rht.busAndTramRight == false)
	assert(core.setSide(rht, "L") == false)
	assert(core.setSide(rht, "R") == true and core.templateSide(rht) == "R" and rht.busAndTramRight == true)
	assert(core.setSide(lht, "L") == false and core.templateSide(lht) == "L", "already on that side")
	local oneWay = { roadType = "STREET", laneConfigs = { lane(true, "CAR"), lane(true, "BUS") } }
	assert(core.setSide(oneWay, "L") == false and oneWay.laneConfigs[1].forward == true, "one-way types are left alone")
	assert(core.setSide(rht, "X") == false, "no such side")
	-- the majority of a list of sides
	assert(core.majoritySide({ "R", "R", "L" }) == "R" and core.majoritySide({ "L", false, "L", "R" }) == "L")
	assert(core.majoritySide({ "R", "L" }) == nil and core.majoritySide({}) == nil)
	local side, r, l = core.majoritySide({ "R", "R", "L", "L", "L" })
	assert(side == "L" and r == 2 and l == 3)
end


-- streets a construction lays: one-way pieces are turned, two-way ones and tracks are not
do
	local function piece(x0, x1) return { { x0, 0, 0 }, { x1 - x0, 0, 0 } }, { { x1, 0, 0 }, { x1 - x0, 0, 0 } } end
	local a0, a1 = piece(0, 10)
	local b0, b1 = piece(10, 20)
	local ring = { type = "STREET", params = { type = "one_way.street_template" }, edges = { a0, a1, b0, b1 },
		snapNodes = { 0, 3 }, freeNodes = { 1 }, tag2nodes = { arm = { 2, 3 } } }
	local c0, c1 = piece(0, 10)
	local both = { type = "STREET", params = { type = "two_way.street_template" }, edges = { c0, c1 }, snapNodes = { 0 } }
	local d0, d1 = piece(0, 10)
	local track = { type = "TRACK", params = { type = "one_way.street_template" }, edges = { d0, d1 }, snapNodes = { 0 } }
	local n = core.edgeLists({ ring, both, track }, function(name) return name == "one_way.street_template" end)
	assert(n == 1)
	assert(ring.edges[1][1][1] == 10 and ring.edges[2][1][1] == 0 and ring.edges[1][2][1] == -10, "a piece runs back along itself")
	assert(ring.edges[3][1][1] == 20 and ring.edges[4][1][1] == 10)
	assert(ring.snapNodes[1] == 1 and ring.snapNodes[2] == 2 and ring.freeNodes[1] == 0, "what named a node names the node now at that place")
	assert(ring.tag2nodes.arm[1] == 3 and ring.tag2nodes.arm[2] == 2)
	assert(ring.edges[ring.snapNodes[1] + 1][1][1] == 0 and ring.edges[ring.snapNodes[2] + 1][1][1] == 20, "the snapping ends are where they were")
	assert(both.edges[1][1][1] == 0 and both.snapNodes[1] == 0 and track.edges[1][1][1] == 0)
end

print("save guard test: ALL OK")
