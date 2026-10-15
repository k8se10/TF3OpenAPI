-- TF3OpenAPI left-hand traffic: vehicles, free of the game so that they can be tested outside it.
--
-- A road vehicle built for traffic on the right has its passenger doors on the right (the kerb side) and, when it
-- has no doors, its driver on the left. For traffic on the left the same vehicle is mirrored: left and right swap.
-- A vehicle is mirrored when its passenger entrances are all on the right, or (no entrances) its driver is on the
-- left; one that already has its doors on the left, or whose driver is already on the right, or is centred, is left as
-- it is. Only road vehicles and trams are considered. Anything the rules do not understand - a number that is not a
-- number, a structure of another form - leaves the vehicle exactly as it was: a fault here must never cost the game a
-- vehicle.
--
-- What a mirror has to move (the vehicle looks along +x, left is +y; the reflection S negates y):
--   * the root of every level of detail: S * transf - every part below it follows, and the sided events of its parts
--     (open / close doors left, right; blinkers) swap sides;
--   * what hangs on the root's frame but has an orientation of its own - seats and draft animals (with their
--     overrides): turned back by S in their own frame, so that they sit on the mirrored side the right way round;
--   * what lies in the model's own space outside the part tree: bounds, the passenger entrances' paths, colliders and
--     lights and emitters that name no part: negated in y (a matrix: S * M * S);
--   * text: placed again by core.mirrorLabel so that it covers the mirrored place and still reads the right way.

local vehicle = {}

local EPS = 0.1   -- metres: smaller offsets count as centred
local S = { 1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local MARKER = "__lht_vehicle"

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

local function vector(v, what)
	assert(type(v) == "table", what .. ": missing vector")
	for i = 1, 3 do assert(finite(v[i]), what .. ": bad vector component " .. i) end
end

local function matrix(m, what)
	assert(type(m) == "table", what .. ": missing matrix")
	for i = 1, 16 do assert(finite(m[i]), what .. ": bad matrix component " .. i) end
end

-- a deep copy that keeps shared tables shared (two levels of detail may share a part)
local function copy(value, memo)
	if type(value) ~= "table" then return value end
	memo = memo or {}
	if memo[value] then return memo[value] end
	local out = {}
	memo[value] = out
	for key, child in next, value do out[copy(key, memo)] = copy(child, memo) end
	return out
end
vehicle.copy = copy

local function mul(a, b)
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

local function reflected(m) return mul(mul(S, m), S) end   -- the same placement, seen in the mirror

-- Which kind of vehicle this is: "road", "tram", or nil for anything else (trains, aircraft, ships, no vehicle).
function vehicle.kind(m)
	if type(m) ~= "table" then return nil end
	if m.airVehicle ~= nil or m.waterVehicle ~= nil or m.railVehicle ~= nil then return nil end
	local tv = type(m.transportVehicle) == "table" and m.transportVehicle or nil
	local carrier = tv and tv.carrier
	if carrier == "TRAM" then return "tram" end
	if carrier == "ROAD" then return "road" end
	if carrier ~= nil then return nil end
	if m.roadVehicle ~= nil or m.car ~= nil then return "road" end
	return nil
end

-- "left", "right", "mixed" (both, or a centred door beside another), "centre" or "none" for the passenger entrances
function vehicle.entranceSide(m)
	local entrances = type(m) == "table" and type(m.transportVehicle) == "table" and m.transportVehicle.entrances
	if type(entrances) ~= "table" or #entrances == 0 then return "none" end
	local left, right, centre = false, false, false
	for _, entry in ipairs(entrances) do
		local first = type(entry) == "table" and type(entry.path) == "table" and entry.path[1]
		assert(type(first) == "table" and finite(first[2]), "an entrance has no path")
		if first[2] > EPS then left = true elseif first[2] < -EPS then right = true else centre = true end
	end
	if (left and right) or (centre and (left or right)) then return "mixed" end
	if left then return "left" end
	if right then return "right" end
	return "centre"
end

-- Should this model be mirrored for traffic on the left? Returns true or false and the reason.
function vehicle.wanted(core, model)
	if type(model) ~= "table" or type(model.metadata) ~= "table" then return false, "no metadata" end
	local kind = vehicle.kind(model.metadata)
	if not kind then return false, "not a road vehicle or tram" end
	local entrance = vehicle.entranceSide(model.metadata)
	if entrance == "right" then return true, "passenger entrances on the right only" end
	if entrance == "left" then return false, "passenger entrances already on the left" end
	if entrance == "none" and core.driverSide(model) == "left" then return true, "driver on the left, no passenger entrances" end
	return false, "no side to correct"
end

local function flipPoint(point, done)
	if done[point] then return end
	done[point] = true
	vector(point, "point")
	point[2] = -point[2]
end

local function flipBounds(b)
	if type(b) ~= "table" then return end
	vector(b.bbMin, "bbMin")
	vector(b.bbMax, "bbMax")
	local lo, hi = copy(b.bbMin), copy(b.bbMax)   -- two roles that may share one vector: replaced, not flipped
	lo[2], hi[2] = -hi[2], -lo[2]
	b.bbMin, b.bbMax = lo, hi
end

local function reflectCollider(c, done)
	if type(c) ~= "table" or done[c] or c.type == "NONE" or c.type == 0 then return end
	done[c] = true
	if c.transf ~= nil then
		matrix(c.transf, "collider")
		c.transf = reflected(c.transf)
	end
	local points = c.type == "POINT_CLOUD" or c.type == 3
	if points then
		local params = c.params or c.pointCloud
		for _, point in ipairs(type(params) == "table" and params.points or {}) do flipPoint(point, done) end
	end
end

local function compensate(item, done)
	if type(item) ~= "table" or done[item] or item.transf == nil then return end
	done[item] = true
	matrix(item.transf, "seat")
	item.transf = mul(item.transf, S)
end

-- The mirror itself, on a copy. `model` is a finished table; returns what was done or raises.
local function mirrorCopy(core, model)
	local m = model.metadata
	assert(type(model.lods) == "table" and #model.lods > 0, "no levels of detail")
	local done = {}
	flipBounds(model.boundingInfo)
	if m.extent ~= model.boundingInfo then flipBounds(m.extent) end
	-- the part tree: every distinct root once, and the sided events of all parts
	local roots, seen, events = {}, {}, 0
	for _, lod in ipairs(model.lods) do
		local node = type(lod) == "table" and lod.node
		assert(type(node) == "table", "a level of detail has no root")
		if not roots[node] then
			roots[node] = true
			matrix(node.transf or { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }, "root")
			node.transf = core.mirrorRoot(node.transf)
			events = events + core.swapSides(node, seen)
		end
	end
	-- seats and draft animals follow the root: only their own frame is turned back
	for _, seat in ipairs(type(m.seatProvider) == "table" and m.seatProvider.seats or {}) do
		compensate(seat, done)
		for _, override in ipairs(type(seat) == "table" and seat.transfOverride or {}) do compensate(override, done) end
	end
	for _, animal in ipairs(type(m.draftAnimalProvider) == "table" and m.draftAnimalProvider.draftAnimals or {}) do
		compensate(animal, done)
		for _, override in ipairs(type(animal) == "table" and animal.transfOverride or {}) do compensate(override, done) end
	end
	-- lights, emitters and colliders that name no part are in the model's space; the rest follow their part
	for _, light in ipairs(type(m.lightSourceList) == "table" and m.lightSourceList.lights or {}) do
		if type(light) == "table" and (light.meshId == nil or light.meshId == "") and (light.childId == nil or light.childId == "")
			and not done[light] and light.transf ~= nil then
			done[light] = true
			matrix(light.transf, "light")
			light.transf = reflected(light.transf)
		end
	end
	for _, emitter in ipairs(type(m.particleSystem) == "table" and m.particleSystem.emitters or {}) do
		if type(emitter) == "table" and (emitter.child == nil or emitter.child == "") then
			if emitter.position ~= nil then flipPoint(emitter.position, done) end
			local velocity = emitter.velocity
			if type(velocity) == "table" then
				if velocity.value ~= nil then flipPoint(velocity.value, done) end
				for _, key in ipairs(type(velocity.curve) == "table" and velocity.curve or {}) do
					if type(key) == "table" and key.value ~= nil then flipPoint(key.value, done) end
				end
			end
		end
	end
	reflectCollider(model.collider, done)
	for _, item in ipairs(type(m.colliderList) == "table" and m.colliderList.colliders or {}) do
		if type(item) == "table" and (item.childId == nil or item.childId == "") then reflectCollider(item.collider, done) end
	end
	-- the passenger entrances' paths are in the model's space too
	for _, entry in ipairs(type(m.transportVehicle) == "table" and m.transportVehicle.entrances or {}) do
		for _, point in ipairs(type(entry) == "table" and entry.path or {}) do flipPoint(point, done) end
	end
	-- text
	local labels = type(m.labelList) == "table" and m.labelList.labels
	local text = 0
	for _, label in ipairs(type(labels) == "table" and labels or {}) do
		if type(label) == "table" and type(label.transf) == "table" and #label.transf == 16 and type(label.size) == "table" then
			matrix(label.transf, "label")
			local follows = type(label.childId) == "string" and label.childId ~= ""
			label.transf = core.mirrorLabel(label.transf, tonumber(label.size[1]) or 0, follows)
			text = text + 1
		end
	end
	return { roots = 0, events = events, labels = text }
end

-- A vehicle model for traffic on the left. Returns the model to use (the given one, untouched, or a mirrored copy)
-- and a short note of what was decided and why. `core` is the module with mirrorRoot / swapSides / mirrorLabel.
function vehicle.adapt(core, name, model)
	local ok, wanted, why = pcall(vehicle.wanted, core, model)
	if not ok then return model, "kept: " .. tostring(wanted):match("^[^\n]*") end
	if not wanted then return model, "kept: " .. tostring(why) end
	-- one that was mirrored already (this resource seen twice) carries a mark
	local params = type(model.metadata.transformatorConfig) == "table" and model.metadata.transformatorConfig.params
	if type(params) == "table" and type(params[MARKER]) == "table" then return model, "kept: already mirrored" end
	local okMirror, result = pcall(function()
		local mirrored = copy(model)
		local done = mirrorCopy(core, mirrored)
		local tc = type(mirrored.metadata.transformatorConfig) == "table" and mirrored.metadata.transformatorConfig or {}
		mirrored.metadata.transformatorConfig = tc
		tc.params = type(tc.params) == "table" and tc.params or {}
		tc.params[MARKER] = { protocol = 1, resource = tostring(name), mirrored = true }
		return mirrored, done
	end)
	if not okMirror then return model, "kept: unsafe (" .. tostring(result):match("^[^\n]*") .. ")" end
	return result, "mirrored: " .. why
end

vehicle.MARKER = MARKER
return vehicle
