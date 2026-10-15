-- TF3OpenAPI save guard: the game script.
--
-- THE SIDE OF THE ROAD BELONGS TO THE SAVE. A save's roads were built for one side; the street types the mods on provide
-- were written for one side (the game's own for the right, a left-hand traffic mod's for the left). When they differ,
-- what gets built next would not connect to what is there. So, once a game has started, this script
--   1. reads the side the street types were written for ("authored": the majority of the two-way ones);
--   2. decides the side the game keeps to ("desired"): the one remembered with the game, else the one its roads were
--      built for, else (a new game) the one chosen by enabling the TF3OpenAPI left-hand traffic mod, else the authored one;
--   3. rewrites the street types written for the other side (the game's own official setAsTable, verified by reading
--      them back) and tells the native layer both sides, which turns the lanes of buildings the same way
--      (native/src/driving_side.cpp).
-- Nothing in a save is rewritten: roads and buildings already built keep their lanes. If the guard cannot make the
-- game consistent (no native layer, or a street type that will not change) it changes NOTHING and says so in the log.
--
-- This runs on the simulation side with a Lua state of its own on every call: nothing is kept in variables; the native
-- layer remembers what it has been told for the length of the game (it forgets when a game starts loading), and the
-- decided side is kept in the game's own script state.

local MOD = "tf3api_save_guard"
local sides = require(MOD .. "::/save_guard/sides.lua")

local function log(text)
	pcall(function() tf3api.log("[" .. MOD .. "] " .. text) end)
end

local function count(list)
	local ok, n = pcall(function() return #list end)
	return ok and tonumber(n) or 0
end

-- what the native layer knows: whether it is there, and the two sides it was told ("" when not yet)
local function native()
	local ok, available, desired, authored = pcall(function() return tf3api.drivingSide() end)
	if not ok then return false, "", "" end
	return available == true, tostring(desired or ""), tostring(authored or "")
end

-- the side the street types were written for
local function authoredSide()
	local rep = api.res.streetTemplateRep
	local found, n = {}, 0
	for id in pairs(rep.getAll(true)) do
		local ok, template = pcall(rep.getAsTable, id)
		if ok and type(template) == "table" then
			n = n + 1
			found[n] = sides.templateSide(template)
		end
	end
	return sides.majoritySide(found, n)
end

-- the side the roads already in the game were built for: the majority of its two-way street segments (a sample)
local function builtSide()
	local TM = api.type.enum.TransportMode
	local function isRoad(lane)
		local okModes, modes = pcall(function() return lane.transportModes end)
		if okModes and modes ~= nil then
			local okRoad, road = pcall(function() return modes[TM.CAR] or modes[TM.BUS] or modes[TM.TRUCK] end)
			if okRoad and road ~= nil then return road == true end
		end
		return (tonumber(lane.speed) or 0) > 0 and (tonumber(lane.width) or 0) >= 2.5
	end
	local okAll, edges = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.BASE_EDGE)
	if not okAll or edges == nil then return nil end
	local found, n, looked = {}, 0, 0
	local total = count(edges)
	local step = math.max(1, math.floor(total / 600))   -- about 600 segments are enough to tell
	for i = 1, total, step do
		local okStreet, street = pcall(api.engine.getComponent, edges[i], api.type.ComponentType.BASE_EDGE_STREET)
		if okStreet and street ~= nil then
			local okEdge, edge = pcall(api.engine.getComponent, edges[i], api.type.ComponentType.BASE_EDGE)
			local lanes = okEdge and edge ~= nil and edge.laneConfigs
			if lanes then
				looked = looked + 1
				local plain = {}
				for k = 1, count(lanes) do
					local okLane, lane = pcall(function() return lanes[k] end)
					if okLane and lane ~= nil then plain[#plain + 1] = { forward = lane.forward, road = isRoad(lane) } end
				end
				n = n + 1
				found[n] = sides.laneSide(plain, function(lane) return lane.road end)
			end
		end
	end
	local side, r, l = sides.majoritySide(found, n)
	return side, r, l, looked
end

-- the side chosen by enabling the TF3OpenAPI left-hand traffic mod (it has a setting, so its entry is there)
local function chosenSide()
	local ok, found = pcall(function() return api.engine.config.getModParams()["tf3api_left_hand_traffic"] ~= nil end)
	return ok and found == true and "L" or nil
end

-- Rewrites the street types written for the other side. Returns how many were changed and how many would not change.
local function turnTemplates(desired)
	local rep = api.res.streetTemplateRep
	local changed, failed = 0, 0
	for id, name in pairs(rep.getAll(true)) do
		local okGet, template = pcall(rep.getAsTable, id)
		local now = okGet and type(template) == "table" and sides.templateSide(template)
		if now and now ~= desired then
			sides.setSide(template, desired)
			local okSet, done = pcall(rep.setAsTable, id, template)
			local okBack, back = pcall(rep.getAsTable, id)
			if okSet and done == true and okBack and sides.templateSide(back) == desired then
				changed = changed + 1
			else
				failed = failed + 1
				if failed <= 3 then log("the street type " .. tostring(name) .. " would not change (set " .. tostring(done) .. ")") end
			end
		end
	end
	return changed, failed
end

local function update(_params, state, _dt)
	local ok, err = pcall(function()
		local available, toldDesired, toldAuthored = native()
		if not available then return end                         -- no native layer: nothing to guard with
		if toldDesired ~= "" and toldAuthored ~= "" then return end   -- this game is done

		-- nothing to go by yet (no two-way street type): try again in ten seconds of play, not on every step
		local saved = state:get()
		local gameTime = 0
		pcall(function() gameTime = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime or 0 end)
		if type(saved) == "table" and type(saved.nextTry) == "number" and gameTime < saved.nextTry then return end
		local authored = authoredSide()
		if authored == nil then
			local keep = type(saved) == "table" and saved or { version = 1 }
			keep.nextTry = gameTime + 10000
			state:set(keep)
			return
		end

		local savedSide = type(saved) == "table" and saved.side or nil
		local desired, why = savedSide, "remembered with the game"
		if desired ~= "R" and desired ~= "L" then
			local built, r, l, looked = builtSide()
			if built ~= nil then
				desired, why = built, string.format("its roads (%d right, %d left of %d looked at)", r, l, looked)
				-- the audit: roads built for both sides (a left-hand mod switched on or off while the game was played) do not
				-- connect where they meet; nothing is changed, but it is said
				local minority = math.min(r, l)
				if minority > 0 and minority >= (r + l) * 0.02 then
					log(string.format("WARNING: this game has roads built for both sides (%d right, %d left of %d two-way segments looked at); "
						.. "they will not connect properly where they meet. Nothing was changed.", r, l, r + l))
				end
			elseif chosenSide() ~= nil then
				desired, why = chosenSide(), "the left-hand traffic mod, enabled for this game"
			else
				desired, why = authored, "the street types of the mods on (a new game)"
			end
		end

		if desired ~= authored then
			-- the street types of the mods on are written for the other side: make them follow the game
			local changed, failed = turnTemplates(desired)
			if failed > 0 then
				-- some would not change: leave the native layer alone too, a half-turned game would be worse
				log(string.format("this game keeps to the %s (%s) but %d street type(s) would not turn; nothing was changed in the buildings", desired, why, failed))
				tf3api.drivingSide(desired, desired)
				return
			end
			log(string.format("this game keeps to the %s (%s); the street types were written for the %s: %d turned, buildings follow", desired, why, authored, changed))
		else
			log(string.format("this game keeps to the %s (%s); the street types and buildings are written for it", desired, why))
		end
		tf3api.drivingSide(desired, authored)
		if savedSide ~= desired or (type(saved) == "table" and saved.nextTry ~= nil) then state:set({ version = 1, side = desired }) end
	end)
	if not ok then log("failed: " .. tostring(err)) end
end

local M = { update = update }
function data() return M end
return M
