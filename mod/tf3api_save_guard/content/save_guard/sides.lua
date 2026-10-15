-- TF3OpenAPI save guard: which side of the road traffic keeps to, free of the game so that it can be tested outside it.
--
-- The game has no setting for the side of the road. It follows from data alone: every lane of a street says whether it
-- runs with the street or against it, and the lanes are listed from one kerb to the other. A save's roads carry the
-- side they were built for; the street types the mods on provide carry the side those mods wrote them for. The guard
-- (guard.script.lua) keeps the two the same, so that switching a left-hand traffic mod on or off never mixes sides.

local sides = {}
local core = sides   -- the functions below are written as methods of "core"

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

-- ---------------------------------------------------------------------------------------------------
-- Which side of the road traffic keeps to, read from lanes. The lanes of a street are listed from one kerb to the
-- other, left to right in the direction the street is drawn, and a lane's `forward` says whether it runs with that
-- direction. On a two-way street the lanes that run with the street are on its right when traffic keeps right and
-- on its left when it keeps left. A one-way street (or one with no road lane) has no side.
-- `isRoad(lane)` says whether a lane is one for road vehicles. Returns "R", "L" or nil.
function core.laneSide(lanes, isRoad)
	if type(lanes) ~= "table" then return nil end
	local sumWith, withCount, sumAgainst, againstCount = 0, 0, 0, 0
	for index, lane in ipairs(lanes) do
		if type(lane) == "table" and isRoad(lane) and type(lane.forward) == "boolean" then
			if lane.forward then sumWith, withCount = sumWith + index, withCount + 1
			else sumAgainst, againstCount = sumAgainst + index, againstCount + 1 end
		end
	end
	if withCount == 0 or againstCount == 0 then return nil end
	return (sumWith / withCount) > (sumAgainst / againstCount) and "R" or "L"
end

-- Has this street type any lane for road vehicles?
function core.hasRoadLanes(template)
	if type(template) ~= "table" or type(template.laneConfigs) ~= "table" then return false end
	for _, lane in ipairs(template.laneConfigs) do
		if core.isRoadLane(lane) then return true end
	end
	return false
end

-- The side a street type (a template table) was written for, or nil for a one-way type or a path.
function core.templateSide(template)
	if type(template) ~= "table" or template.roadType ~= "STREET" then return nil end
	return core.laneSide(template.laneConfigs, core.isRoadLane)
end

-- A street type changed, in place, to keep to `side` ("R" or "L"): only a two-way type that is written for the other
-- side is changed (its vehicle lanes turn, what each lane is for stays with the lane). One-way types are left as
-- they are. Returns true when the type was changed.
function core.setSide(template, side)
	local now = core.templateSide(template)
	if now == nil or now == side or (side ~= "R" and side ~= "L") then return false end
	for _, lane in ipairs(template.laneConfigs) do
		if core.isRoadLane(lane) and type(lane.forward) == "boolean" then lane.forward = not lane.forward end
	end
	template.busAndTramRight = (side == "R")
	return true
end

-- The side most of a list of sides are on. `sides` is a list of "R" / "L" / nil entries (nil is skipped).
-- Returns "R", "L", or nil when there are none or they are equally many.
function core.majoritySide(sides, count)
	local r, l = 0, 0
	for index = 1, count or #sides do
		local side = sides[index]
		if side == "R" then r = r + 1 elseif side == "L" then l = l + 1 end
	end
	if r == l then return nil, r, l end
	return r > l and "R" or "L", r, l
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

return sides
