-- TF3OpenAPI - day clock: a clock that runs in real time, and three ways for the calendar to go with it.
--
-- The clock is the same in every mode: at normal game speed a second of play is a second on the clock
-- (the game's running time read as a clock, 00:00:00 to 23:59:59). It stands still while the game is paused
-- and runs faster with the game's speed. The modes differ in how long a calendar day lasts:
--
--   Realistic        a calendar day is the clock's day: 24 hours of play at normal speed; the date changes
--                    at midnight.
--   Balanced         a calendar day is one hour of the clock; the date changes on every full hour.
--   Transport Fever  the calendar keeps the game's own pace (a few seconds a day), so the game's balance of
--                    years, vehicles and costs is as shipped; only the clock is added.
--
-- The sky's cycle is chosen in the game's own menu (its time-of-day dropdown), never by this mod. While the
-- continuous cycle is chosen there ("Automatic" in the game's script), the sun and moon follow the clock: day
-- and night come at the clock's hours instead of the game's own fast day. Custom (the game's own time slider),
-- Dynamic and Local are left to the game. The mod's "Sun and moon" setting can keep the sky out of it
-- altogether.
--
-- It uses only what the game itself offers:
--   * the calendar speed (the game's own "Calendar Speed" control sets the same value; by the game's own
--     description it "affects only the speed of the calendar, and not the simulation speed");
--   * the time of day of the sky (the game's own cycle modes set it the same way).
-- The engine starts a new day whenever its running time passes a multiple of the day's length, which is
-- why the date changes exactly at midnight (Realistic) or on the hour (Balanced).
--
-- What follows from a long day: years pass that much more slowly, so vehicles and buildings that appear by
-- year appear that much later in play time.
--
-- Works alongside the "Timetables" mod (celmi_timetables): seen in the game with both enabled, the two show
-- exactly the same time.
--
-- Removing the mod leaves the save as it is: the calendar speed and the sky's mode are the game's own
-- settings and can be set back with the game's own controls (calendar speed 1x, any cycle). The clock is the
-- game's running time, so a date the player changes moves nothing on it.

local MOD = "[tf3api_day_clock] "
local MOD_ID = "tf3api_day_clock"

-- the modes, in the order of the mod's setting; dayMs = length of a calendar day in milliseconds of running
-- time (nil: the game's own)
local MODES = {
	{ id = "realistic", name = "Realistic", dayMs = 24 * 60 * 60 * 1000 },
	{ id = "balanced", name = "Balanced", dayMs = 60 * 60 * 1000 },
	{ id = "transport_fever", name = "Transport Fever", dayMs = nil },
}
-- the game's own day, where nothing better is known (the engine's own stand-in figure)
local STOCK_DAY_MS = 4000
-- the sky is moved when it is this many seconds of the day away from the clock (the game's continuous cycle
-- moves it on by about 61 seconds of the day each second; this keeps it on the clock)
local SKY_STEP = 2
-- the game's continuous cycle, the one that follows the clock
local FOLLOW_MODE = "Automatic"
-- the calendar speed is not set again within this much running time (milliseconds)
local SET_AGAIN_MS = 5000

local function log(text)
	local ok = pcall(function() tf3api.log(MOD .. text) end)
	if not ok then pcall(print, MOD .. text) end
end

-- The time of day in seconds (0 .. 86399) for the game's running time in milliseconds.
local function clockSeconds(gameTime)
	if type(gameTime) ~= "number" or gameTime < 0 then return nil end
	return math.floor(gameTime / 1000) % 86400
end

-- how far two times of day are apart, the short way round midnight
local function apart(a, b)
	local d = math.abs(a - b) % 86400
	if d > 43200 then d = 86400 - d end
	return d
end

-- What to do now.
-- `now` = { gameTime, millisPerDay, skySeconds, skyMode, skyOn, dayMs (the mode's day; nil = the game's own),
--           stockDayMs (the game's own day length) }
-- `saved` = what this mod keeps with the game (may be nil).
-- Returns the actions { calendar = milliseconds, mode = text, sky = seconds } (each may be absent), what to
-- keep, and whether that changed.
local function plan(now, saved)
	local actions, changed = {}, false
	if type(saved) ~= "table" or saved.version ~= 1 then
		saved = { version = 1 }
		changed = true
	end
	local millisPerDay = now.millisPerDay
	local settled = saved.setAt ~= nil and now.gameTime >= saved.setAt and now.gameTime - saved.setAt < SET_AGAIN_MS

	if now.dayMs ~= nil then
		-- a mode with a day of its own. A calendar the player has stopped (0) is left stopped.
		if millisPerDay ~= now.dayMs and not (millisPerDay == 0 and saved.calendarSet) and not settled then
			actions.calendar = now.dayMs
			if saved.before == nil then saved.before = millisPerDay end
			saved.calendarSet = true
			saved.setAt = now.gameTime
			changed = true
		end
	elseif saved.calendarSet then
		-- the game's own pace is wanted and we had changed it: put back what it was, once
		local back = saved.before
		if type(back) ~= "number" or back <= 0 then back = now.stockDayMs or STOCK_DAY_MS end
		if millisPerDay ~= back and millisPerDay ~= 0 then actions.calendar = back end
		saved.calendarSet = nil
		saved.before = nil
		saved.setAt = nil
		changed = true
	end

	if saved.modeSet then
		-- a save where an earlier version of this mod had switched the cycle to Custom ("Constant") to drive the
		-- sky itself: once, it goes on the continuous cycle, which is the one that follows the clock now (or back
		-- to what it was, with the sky setting off). A cycle the player chose meanwhile is kept.
		if now.skyMode == "Constant" then
			if now.skyOn ~= false then
				actions.mode = FOLLOW_MODE
			elseif type(saved.modeBefore) == "string" and saved.modeBefore ~= "Constant" then
				actions.mode = saved.modeBefore
			end
		end
		saved.modeSet = nil
		saved.modeBefore = nil
		changed = true
	elseif now.skyOn ~= false and now.skyMode == FOLLOW_MODE then
		-- the continuous cycle is chosen in the game's menu: it follows the clock
		local seconds = clockSeconds(now.gameTime)
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

-- One of the mod's settings as the number of the chosen option, counted from 1; nil when not set.
-- (The game hands a chosen option over counted from 1.)
local function setting(key)
	local ok, value = pcall(function() return api.engine.config.getModParams()[MOD_ID][key] end)
	value = ok and tonumber(value) or nil
	if value ~= nil and value >= 1 then return math.floor(value) end
	return nil
end

-- the mode for the number of the chosen option (the first one when not set)
local function modeOf(choice)
	return MODES[choice or 1] or MODES[1]
end

-- Simulation side: runs in the game's simulation threads with its own Lua state, so nothing is kept in
-- variables here, only in the state the game gives us.
local function update(_params, state, _dt)
	local ok, problem = pcall(function()
		local world = api.engine.util.getWorld()
		local gameTime = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME)
		local gameSpeed = api.engine.getComponent(world, api.type.ComponentType.GAME_SPEED)
		local sky = skyMode()
		if sky == nil then return end   -- the game's own time script is not there yet
		local mode = modeOf(setting("mode"))
		local okStock, stock = pcall(function() return api.util.getDefaultDayDuration() end)
		local actions, saved, changed = plan({
			gameTime = gameTime.gameTime,
			millisPerDay = gameSpeed.millisPerDay,
			skySeconds = gameTime.timeOfDaySec,
			skyMode = sky,
			skyOn = setting("sky") ~= 2,
			dayMs = mode.dayMs,
			stockDayMs = okStock and tonumber(stock) or nil,
		}, state:get())
		if actions.calendar ~= nil then
			log(string.format("%s: a calendar day now lasts %d s of play at normal speed (it was at %s ms a day)",
				mode.name, math.floor(actions.calendar / 1000), tostring(gameSpeed.millisPerDay)))
			api.cmd.sendCommand(api.cmd.makeGameSetCalendarSpeedCmd(actions.calendar))
		end
		if actions.mode ~= nil then
			log("the sky's cycle, set to Custom by an earlier version of this mod, is put on \"" .. tostring(actions.mode)
				.. "\" (choose it in the game's menu: the continuous cycle follows the clock, Custom is the game's own slider)")
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
	clockSeconds = clockSeconds, plan = plan, apart = apart, modeOf = modeOf,
	MODES = MODES, SKY_STEP = SKY_STEP, STOCK_DAY_MS = STOCK_DAY_MS, FOLLOW_MODE = FOLLOW_MODE,
}
function data() return M end
return M
