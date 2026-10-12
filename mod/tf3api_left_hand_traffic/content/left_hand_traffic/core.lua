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

return core
