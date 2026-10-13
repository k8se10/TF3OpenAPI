-- TF3OpenAPI - day clock: a game day that runs from 00:00 to 23:59, minute by minute.
--
-- As the game ships, a calendar day lasts a few seconds and the sky has nothing to do with it. With this mod
-- enabled for a save, a calendar day lasts DAY_MINUTES real minutes at normal speed, the time of day is where
-- the game stands within that day, the sun and moon follow it, and the date changes at midnight.
--
-- It uses only what the game itself offers:
--   * the calendar speed (the game's own "Calendar Speed" control sets the same value; by the game's own
--     description it "affects only the speed of the calendar, and not the simulation speed");
--   * the time of day of the sky (the game's own cycle modes set it the same way).
-- The engine starts a new day whenever its running time passes a multiple of the day's length, so the time
-- of day is simply: running time modulo day length.
--
-- What follows from a long day: years pass that much more slowly, so vehicles and buildings that appear by
-- year appear that much later in play time.
--
-- Removing the mod leaves the save as it is: the calendar speed and the sky's mode are the game's own
-- settings and can be set back with the game's own controls (calendar speed 1x, cycle "Dynamic").

local MOD = "[tf3api_day_clock] "

-- real minutes, at normal game speed, for one game day (24: one game minute every second)
local DAY_MINUTES = 24
local DAY_MS = DAY_MINUTES * 60 * 1000
-- a day at least this long is taken as "a day with a clock" (also by the departure boards)
local LONG_DAY_MS = 10 * 60 * 1000
-- the sky is moved when it is this many seconds of the day away from the clock
local SKY_STEP = 20
-- the calendar speed is not set again within this much running time (milliseconds)
local SET_AGAIN_MS = 5000

local function log(text)
	local ok = pcall(function() tf3api.log(MOD .. text) end)
	if not ok then pcall(print, MOD .. text) end
end

-- The time of day in seconds (0 .. 86399) for the game's running time and the length of its day, both in
-- milliseconds; nil when the calendar stands still.
local function clockSeconds(gameTime, millisPerDay)
	if type(gameTime) ~= "number" or type(millisPerDay) ~= "number" or millisPerDay <= 0 or gameTime < 0 then return nil end
	local seconds = math.floor((gameTime % millisPerDay) * 86400 / millisPerDay)
	if seconds > 86399 then seconds = 86399 end
	return seconds
end

-- how far two times of day are apart, the short way round midnight
local function apart(a, b)
	local d = math.abs(a - b) % 86400
	if d > 43200 then d = 86400 - d end
	return d
end

-- What to do now. `now` = { gameTime, millisPerDay, skySeconds, skyMode }, `saved` = what this mod keeps
-- with the game (may be nil). Returns the actions { calendar = milliseconds, mode = text, sky = seconds }
-- (each may be absent), what to keep, and whether that changed.
local function plan(now, saved)
	local actions, changed = {}, false
	if type(saved) ~= "table" or saved.version ~= 1 then
		saved = { version = 1 }
		changed = true
	end
	local millisPerDay = now.millisPerDay

	-- the length of the day. A calendar the player has stopped (0) is left stopped.
	if millisPerDay ~= DAY_MS and not (millisPerDay == 0 and saved.calendarSet) then
		if saved.setAt == nil or now.gameTime < saved.setAt or now.gameTime - saved.setAt >= SET_AGAIN_MS then
			actions.calendar = DAY_MS
			if saved.before == nil then saved.before = millisPerDay end
			saved.calendarSet = true
			saved.setAt = now.gameTime
			changed = true
		end
	end

	-- the sky: taken over once ("Constant" = the game moves nothing itself); after that it follows the
	-- clock for as long as the player leaves that mode on.
	if not saved.modeSet then
		if now.skyMode ~= "Constant" then actions.mode = "Constant" end
		saved.modeSet = true
		changed = true
	elseif now.skyMode == "Constant" and millisPerDay >= LONG_DAY_MS then
		local seconds = clockSeconds(now.gameTime, millisPerDay)
		if seconds ~= nil and (type(now.skySeconds) ~= "number" or apart(seconds, now.skySeconds) >= SKY_STEP) then
			actions.sky = seconds
		end
	end
	return actions, saved, changed
end

-- the mode of the game's own sky cycle, as its own interface reads it
local function skyMode()
	local ok, mode = pcall(function()
		local entity = api.engine.system.gameScriptSystem.getEntityForGameScript("::/game_mechanics/game_time/game_time.gs")
		return api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT).state.timeOfDayMode
	end)
	if ok then return mode end
	return nil
end

-- Simulation side: runs in the game's simulation threads with its own Lua state, so nothing is kept in
-- variables here, only in the state the game gives us.
local function update(_params, state, _dt)
	local ok, problem = pcall(function()
		local world = api.engine.util.getWorld()
		local gameTime = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME)
		local gameSpeed = api.engine.getComponent(world, api.type.ComponentType.GAME_SPEED)
		local mode = skyMode()
		if mode == nil then return end   -- the game's own time script is not there yet
		local actions, saved, changed = plan({
			gameTime = gameTime.gameTime,
			millisPerDay = gameSpeed.millisPerDay,
			skySeconds = gameTime.timeOfDaySec,
			skyMode = mode,
		}, state:get())
		if actions.calendar ~= nil then
			log(string.format("a game day now lasts %d minutes at normal speed (the calendar was at %s ms a day)", DAY_MINUTES, tostring(gameSpeed.millisPerDay)))
			api.cmd.sendCommand(api.cmd.makeGameSetCalendarSpeedCmd(actions.calendar))
		end
		if actions.mode ~= nil then
			log("the sky follows the clock from now on (its cycle was \"" .. tostring(mode) .. "\")")
			api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", "GameTime", "SetMode", { mode = actions.mode }))
		end
		if actions.sky ~= nil then
			api.cmd.sendCommand(api.cmd.makeGameSetTimeOfDayCmd(actions.sky))
		end
		if changed then state:set(saved) end
	end)
	if not ok then pcall(print, MOD .. "update failed: " .. tostring(problem)) end
end

local M = {
	update = update,
	-- for tests
	clockSeconds = clockSeconds, plan = plan, apart = apart,
	DAY_MS = DAY_MS, LONG_DAY_MS = LONG_DAY_MS, SKY_STEP = SKY_STEP,
}
function data() return M end
return M
