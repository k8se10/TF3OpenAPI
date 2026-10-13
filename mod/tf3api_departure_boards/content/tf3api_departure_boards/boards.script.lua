-- TF3OpenAPI - departure boards: what the boards show.
--
-- The lit dots of a board are written into its texture by the TF3OpenAPI native layer; this script only says
-- what to write (tf3api.boardText, tf3api.boardClock). Without the native layer nothing here does anything
-- and a board shows the picture it ships with.
--
-- A board has a screen number (chosen when it is placed). Boards with the same number show the same thing:
-- the next departures of the station nearest to the first board placed with that number, or a welcome when
-- nothing is due. A number whose board stands at no station shows the "not connected" lines, which the
-- native layer knows by itself. The clock runs on every screen.
--
-- Everything read from the game here is read a little at a time: the boards are looked for a few hundred
-- constructions per frame, and one screen's departures are worked out at a time.

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
local SURVEY_PAUSE = 600          -- frames between two searches
local SCREEN_EVERY = 20           -- frames between working out two screens
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
	boards = {},         -- found boards: { id, slot, x, y }
	assigned = {},       -- [slot] = station { id, name, x, y }
	stationsAt = nil,
	-- the screens
	nextSlot = 0,
	screenAt = 0,
	sent = {},           -- [slot] = the three lines last sent, joined
	toldScreens = 0,
}

local function bridge()
	if state.bridge == nil then
		local ok, t = pcall(function() return tf3api end)
		if ok and type(t) == "table" and type(t.boardClock) == "function" then
			state.bridge = t
			state.core = loadModule("boards_core.lua")
			log("the native layer is there: the boards' clock runs" .. (type(t.boardText) == "function" and "" or " (an older layer: no departures)")
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
-- counts in the same time, can be shown on it. It is the same clock as the TF3OpenAPI day clock mod's, in
-- each of that mod's modes.
-- (Not the time of day of the sky: in the game's usual setting the sky does not run through a day. The
-- game's own script moves it between "noon", "morning" and "evening" by chance, forwards or backwards -
-- a clock following it ran backwards on the first board tried.)
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

local function nameOf(entity)
	local ok, name = pcall(function() return api.engine.getComponent(entity, api.type.ComponentType.NAME).name end)
	if ok and type(name) == "string" then return name end
	return ""
end

-- ---- looking for the boards (a little per frame) ---------------------------------------------------------

local function stations()
	-- every station group with the place of its first station's construction
	local out = {}
	local ok, problem = pcall(function()
		local toConstruction = api.engine.system.streetConnectorSystem.getStation2ConstructionMap()
		for _, group in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.STATION_GROUP)) do
			local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
			local x, y
			for _, station in ipairs(comp.stations) do
				local construction = toConstruction[station]
				if construction ~= nil then
					x, y = placeOf(api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION).transf)
					if x ~= nil then break end
				end
			end
			if x ~= nil then out[#out + 1] = { id = group, name = nameOf(group), x = x, y = y } end
		end
	end)
	if not ok and state.stationsAt == nil then log("stations could not be listed: " .. tostring(problem)) end
	state.stationsAt = state.frame
	return out
end

local function surveyStep()
	local survey = state.survey
	if survey == nil then
		if state.frame < state.surveyAt then return end
		local ok, entities = pcall(function() return api.engine.getEntitiesWithComponent(api.type.ComponentType.CONSTRUCTION) end)
		if not ok or type(entities) ~= "table" then
			state.surveyAt = state.frame + SURVEY_PAUSE
			return
		end
		state.survey = { entities = entities, cursor = 1, boards = {} }
		return
	end
	local last = math.min(#survey.entities, survey.cursor + SURVEY_PER_FRAME - 1)
	for i = survey.cursor, last do
		local entity = survey.entities[i]
		pcall(function()
			local comp = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
			local file = tostring(comp.fileName)
			if file:find(MOD_ID, 1, true) ~= nil and file:find("board_", 1, true) ~= nil then
				local x, y = placeOf(comp.transf)
				local screen = 1
				pcall(function() screen = tonumber(comp.params.screen) or 1 end)
				if x ~= nil then survey.boards[#survey.boards + 1] = { id = entity, slot = math.floor(screen) - 1, x = x, y = y } end
			end
		end)
	end
	survey.cursor = last + 1
	if survey.cursor > #survey.entities then
		local before = #state.boards
		state.boards = survey.boards
		state.assigned = state.core.assign(state.boards, #state.boards > 0 and stations() or {})
		if #state.boards ~= before then
			local wired = 0
			for _ in pairs(state.assigned) do wired = wired + 1 end
			log(string.format("%d board(s) among %d constructions; %d screen number(s) at a station", #state.boards, #survey.entities, wired))
		end
		state.survey = nil
		state.surveyAt = state.frame + SURVEY_PAUSE
	end
end

-- ---- one screen's departures ------------------------------------------------------------------------------

-- The game counts stops from 0 where it names one by number; its lists are counted from 1 as lists are.
local function departuresOf(station, now)
	local departures, served = {}, false
	local AT_TERMINAL = api.type.enum.TransportVehicleState.AT_TERMINAL
	local EN_ROUTE = api.type.enum.TransportVehicleState.EN_ROUTE
	for _, lineStop in ipairs(api.engine.system.lineSystem.getLineStops(station.id)) do
		local lineEntity, stopIndex = lineStop[1], lineStop[2]
		local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE)
		local n = #line.stops
		local target = stopIndex + 1
		if n >= 2 and target >= 1 and target <= n then
			served = true
			local names = {}
			for i = 1, n do names[i] = nameOf(line.stops[i].stationGroup) end
			local destination = state.core.destination(names, target, station.name)
			local platform = tostring((tonumber(line.stops[target].terminal) or 0) + 1)
			local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineEntity)
			for v = 1, math.min(#vehicles, VEHICLES_PER_LINE) do
				local tv = api.engine.getComponent(vehicles[v], api.type.ComponentType.TRANSPORT_VEHICLE)
				if tv.state == AT_TERMINAL or tv.state == EN_ROUTE then
					local sections = {}
					for i = 1, n do
						local seconds = tonumber(tv.sectionTimes[i]) or 0
						if seconds > 100000 then seconds = seconds / 1000 end   -- should a build count them in milliseconds
						sections[i] = seconds
					end
					local stop = (tonumber(tv.stopIndex) or 0) + 1
					local before = stop == 1 and n or stop - 1
					local left = tonumber(tv.lineStopDepartures[before])
					local eta = state.core.eta(n, sections, {
						stop = stop, atStop = tv.state == AT_TERMINAL,
						since = (left ~= nil and left > 0) and (now - left) / 1000 or nil,
					}, target)
					if eta ~= nil then departures[#departures + 1] = { eta = eta, destination = destination, platform = platform } end
				end
			end
		end
	end
	return departures, served
end

local function screenStep(b, clock, now)
	if type(b.boardText) ~= "function" or state.core == nil then return end
	if state.frame < state.screenAt then return end
	state.screenAt = state.frame + SCREEN_EVERY
	-- the next screen number that has a station
	local slot
	for step = 0, state.core.SLOTS - 1 do
		local s = (state.nextSlot + step) % state.core.SLOTS
		if state.assigned[s] ~= nil then
			slot = s
			break
		end
	end
	if slot == nil then return end
	state.nextSlot = (slot + 1) % state.core.SLOTS
	local station = state.assigned[slot]
	local ok, departures, served = pcall(departuresOf, station, now)
	if not ok then
		if state.toldScreens < 3 then
			state.toldScreens = state.toldScreens + 1
			log("screen " .. (slot + 1) .. " (" .. tostring(station.name) .. "): departures could not be worked out: " .. tostring(departures))
		end
		return
	end
	local lines = state.core.lines(clock, station, departures, served)
	if lines == nil then return end
	local joined = table.concat(lines, "\n")
	if state.sent[slot] ~= joined then
		state.sent[slot] = joined
		b.boardText(tostring(slot), lines[1], lines[2], lines[3])
		if state.toldScreens < 6 then
			state.toldScreens = state.toldScreens + 1
			log(string.format("screen %d shows %s: %d departure(s) known; first line \"%s\"", slot + 1, tostring(station.name), #departures,
				(lines[1] ~= "" and lines[1] or lines[2]):gsub("\t", " | ")))
		end
	end
end

local function guiUpdate()
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
			surveyStep()
			screenStep(b, seconds or 0, now)
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
		clockOf = clockOf,   -- for tests
	}
end
