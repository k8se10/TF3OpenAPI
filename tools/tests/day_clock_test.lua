-- Run from the repository root:  lua tools/tests/day_clock_test.lua
-- The day clock's rules, without the game.
local root = "mod/tf3api_day_clock/content/day_clock/"
local function load(path)
	local chunk, problem = loadfile(root .. path)
	assert(chunk, "not Lua: " .. tostring(problem))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	assert(type(env.data) == "function", path .. ": no data()")
	return env.data()
end

local gs = load("day_clock.gs.lua")
assert(gs.updateScript.fileName == "tf3api_day_clock::/day_clock/day_clock.script@update")
local M = load("day_clock.script.lua")
assert(type(M.update) == "function")

local HOUR, DAY = 3600 * 1000, 24 * 3600 * 1000

-- 1. the modes
assert(#M.MODES == 3)
assert(M.modeOf(nil).id == "realistic" and M.modeOf(1).dayMs == DAY, "Realistic: a calendar day is 24 hours of play")
assert(M.modeOf(2).id == "balanced" and M.modeOf(2).dayMs == HOUR, "Balanced: a calendar day is one hour of play")
assert(M.modeOf(3).id == "transport_fever" and M.modeOf(3).dayMs == nil, "Transport Fever: the game's own pace")
assert(M.modeOf(9).id == "realistic")
assert(DAY < 2 ^ 31, "the engine keeps the day's length in 32 bits")

-- 2. the clock: real time at normal speed, in every mode
assert(M.clockSeconds(0) == 0)
assert(M.clockSeconds(999) == 0 and M.clockSeconds(1000) == 1)
assert(M.clockSeconds(DAY / 2) == 43200)
assert(M.clockSeconds(DAY - 1) == 86399 and M.clockSeconds(DAY) == 0)
assert(M.clockSeconds(7 * DAY + 3723 * 1000) == 3723)
assert(M.clockSeconds(nil) == nil and M.clockSeconds(-5) == nil)
-- the date changes where the engine starts a day: at multiples of the day's length. Realistic: at 00:00:00;
-- Balanced: on every full hour.
for k = 1, 30 do
	assert(M.clockSeconds(k * DAY) == 0)
	assert(M.clockSeconds(k * HOUR) % 3600 == 0)
end
assert(M.apart(10, 86390) == 20 and M.apart(86390, 10) == 20 and M.apart(100, 500) == 400)

local function now(t)
	local n = { gameTime = 50000, millisPerDay = 4000, skySeconds = 43200, skyMode = "Dynamic", skyOn = true, dayMs = DAY, stockDayMs = 4000 }
	for k, v in pairs(t or {}) do n[k] = v end
	if n.dayMs == false then n.dayMs = nil end   -- false stands for "the game's own day"
	return n
end

-- 3. first run on a save (Realistic): the day is made long and the sky is taken over, once
local actions, saved, changed = M.plan(now(), nil)
assert(actions.calendar == DAY and actions.mode == "Constant" and actions.sky == nil and changed)
assert(saved.version == 1 and saved.before == 4000 and saved.calendarSet and saved.modeSet and saved.modeBefore == "Dynamic")

-- 4. the command has not taken effect yet: not sent again straight away, sent again after a while
actions, saved, changed = M.plan(now({ gameTime = 50100 }), saved)
assert(actions.calendar == nil and actions.mode == nil and actions.sky == nil and not changed)
actions = M.plan(now({ gameTime = 56000, skyMode = "Constant" }), { version = 1, calendarSet = true, modeSet = true, setAt = 50000, before = 4000 })
assert(actions.calendar == DAY)

-- 5. running: the sky is moved when it is off the clock, and left alone when it is on it
local t = 3 * DAY + 6 * HOUR   -- 06:00
actions, saved, changed = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Constant" }), saved)
assert(actions.calendar == nil and actions.mode == nil and actions.sky == 21600 and not changed)
actions = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Constant", skySeconds = 21600 + M.SKY_STEP - 1 }), saved)
assert(actions.sky == nil)
actions = M.plan(now({ gameTime = 4 * DAY + 100, millisPerDay = DAY, skyMode = "Constant", skySeconds = 86395 }), saved)
assert(actions.sky == nil, "five seconds before midnight is close enough to just after it")

-- 6. the player's own choices are respected: another sky cycle, a stopped calendar
actions = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Local" }), saved)
assert(actions.sky == nil and actions.mode == nil)
actions = M.plan(now({ gameTime = t, millisPerDay = 0, skyMode = "Constant", skySeconds = 21600 }), saved)
assert(actions.calendar == nil)

-- 7. Balanced: the same clock and sky, a calendar day of one hour
do
	local a, s = M.plan(now({ dayMs = HOUR }), nil)
	assert(a.calendar == HOUR and s.before == 4000)
	a = M.plan(now({ gameTime = t, millisPerDay = HOUR, dayMs = HOUR, skyMode = "Constant" }), s)
	assert(a.calendar == nil and a.sky == 21600, "the sky follows the real-time clock, not the calendar day")
	-- changing from Realistic to Balanced: set again, and what the game had before us is still remembered
	a, s = M.plan(now({ gameTime = t, millisPerDay = DAY, dayMs = HOUR, skyMode = "Constant", skySeconds = 21600 }),
		{ version = 1, calendarSet = true, modeSet = true, before = 4000, setAt = 0 })
	assert(a.calendar == HOUR and s.before == 4000)
end

-- 8. Transport Fever: the calendar is never touched; if another mode had changed it, it is put back once
do
	local a, s, c = M.plan(now({ dayMs = false }), nil)
	assert(a.calendar == nil and a.mode == "Constant" and not s.calendarSet, "only the sky is taken")
	a, s, c = M.plan(now({ gameTime = t, millisPerDay = DAY, dayMs = false, skyMode = "Constant", skySeconds = 21600 }),
		{ version = 1, calendarSet = true, modeSet = true, before = 2000, setAt = 0 })
	assert(a.calendar == 2000 and c and not s.calendarSet and s.before == nil, "back to what the save had")
	a = M.plan(now({ gameTime = t, millisPerDay = DAY, dayMs = false, skyMode = "Constant", skySeconds = 21600 }),
		{ version = 1, calendarSet = true, modeSet = true, before = 0, setAt = 0 })
	assert(a.calendar == 4000, "nothing usable remembered: the game's own day")
	a, s, c = M.plan(now({ gameTime = t + 10, millisPerDay = 2000, dayMs = false, skyMode = "Constant", skySeconds = 21600 }), s)
	assert(a.calendar == nil and not c, "and then left alone, whatever the player sets")
end

-- 9. "Sun and moon" switched off: the sky is handed back once, the calendar's mode stays
do
	local a, s, c = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Constant", skyOn = false }),
		{ version = 1, calendarSet = true, modeSet = true, modeBefore = "Dynamic", setAt = 0 })
	assert(a.mode == "Dynamic" and a.sky == nil and a.calendar == nil and c and not s.modeSet)
	a, s, c = M.plan(now({ gameTime = t + 100, millisPerDay = DAY, skyOn = false }), s)
	assert(a.mode == nil and a.sky == nil and not c, "nothing more is touched while it is off")
	a = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Local", skyOn = false }),
		{ version = 1, calendarSet = true, modeSet = true, modeBefore = "Dynamic", setAt = 0 })
	assert(a.mode == nil, "a cycle the player chose meanwhile is kept")
	a, s = M.plan(now({ skyOn = false }), nil)
	assert(a.calendar == DAY and a.mode == nil and not s.modeSet, "off from the start: the sky is never taken")
	a, s = M.plan(now({ gameTime = t, millisPerDay = DAY, skyOn = true }), s)
	assert(a.mode == "Constant" and s.modeSet and s.modeBefore == "Dynamic", "switched on again: taken over again")
end

-- 10. the mod's own description of itself
do
	local f = assert(io.open("mod/tf3api_day_clock/mod.json", "rb")); local text = f:read("*a"); f:close()
	assert(text:find('"modId": "celmi_timetables"', 1, true), "the Timetables mod is declared incompatible")
	assert(text:find('"key": "sky"', 1, true) and text:find('"key": "mode"', 1, true))
	-- the options are listed in the order the script counts them
	local a = text:find('"Realistic', 1, true); local b = text:find('"Balanced', 1, true); local c = text:find('"Transport Fever', 1, true)
	assert(a and b and c and a < b and b < c)
end

-- 11. the departure boards show the same clock
do
	local chunk = assert(loadfile("mod/tf3api_departure_boards/content/tf3api_departure_boards/boards.script.lua"))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	local B = env.data()
	assert(type(B.clockOf) == "function")
	for _, ms in ipairs({ 0, 999, 3723000, 90061000, 3 * DAY + DAY / 2, 11 * DAY - 1 }) do
		assert(B.clockOf(ms) == M.clockSeconds(ms), "boards and day clock agree at " .. ms)
	end
	assert(B.clockOf(nil) == nil)
end

print("day clock test: ALL OK")
