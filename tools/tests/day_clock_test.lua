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

-- 1. the clock: running time modulo the day's length
local DAY = M.DAY_MS
assert(M.clockSeconds(0, DAY) == 0)
assert(M.clockSeconds(DAY / 2, DAY) == 43200)
assert(M.clockSeconds(DAY - 1, DAY) == 86399)
assert(M.clockSeconds(DAY, DAY) == 0, "a new day starts at a multiple of the day's length")
assert(M.clockSeconds(7 * DAY + DAY / 4, DAY) == 21600)
assert(M.clockSeconds(1000, 0) == nil, "no clock while the calendar stands still")
assert(M.clockSeconds(nil, DAY) == nil)
-- it only goes forward within a day
local last = -1
for t = 0, DAY - 1, 997 do
	local s = M.clockSeconds(t, DAY)
	assert(s >= last and s <= 86399)
	last = s
end
assert(M.apart(10, 86390) == 20 and M.apart(86390, 10) == 20 and M.apart(100, 500) == 400)

-- 2. first run on a save: the day is made long and the sky is taken over, once
local actions, saved, changed = M.plan({ gameTime = 50000, millisPerDay = 4000, skySeconds = 43200, skyMode = "Dynamic" }, nil)
assert(actions.calendar == DAY and actions.mode == "Constant" and actions.sky == nil and changed)
assert(saved.version == 1 and saved.before == 4000 and saved.calendarSet and saved.modeSet and saved.modeBefore == "Dynamic")

-- 3. the command has not taken effect yet: not sent again straight away, sent again after a while
actions, saved, changed = M.plan({ gameTime = 50100, millisPerDay = 4000, skySeconds = 43200, skyMode = "Dynamic" }, saved)
assert(actions.calendar == nil and actions.mode == nil and actions.sky == nil and not changed)
actions = M.plan({ gameTime = 56000, millisPerDay = 4000, skySeconds = 43200, skyMode = "Constant" }, { version = 1, calendarSet = true, modeSet = true, setAt = 50000, before = 4000 })
assert(actions.calendar == DAY)

-- 4. running: the sky is moved when it is off the clock, and left alone when it is on it
local t = 3 * DAY + DAY / 4   -- 06:00
actions, saved, changed = M.plan({ gameTime = t, millisPerDay = DAY, skySeconds = 43200, skyMode = "Constant" }, saved)
assert(actions.calendar == nil and actions.mode == nil and actions.sky == 21600 and not changed)
actions = M.plan({ gameTime = t, millisPerDay = DAY, skySeconds = 21600 + M.SKY_STEP - 1, skyMode = "Constant" }, saved)
assert(actions.sky == nil)
-- across midnight
actions = M.plan({ gameTime = 4 * DAY + 100, millisPerDay = DAY, skySeconds = 86395, skyMode = "Constant" }, saved)
assert(actions.sky == nil, "five seconds before midnight is close enough to just after it")

-- 5. the player's own choices are respected: another sky cycle, a stopped calendar
actions = M.plan({ gameTime = t, millisPerDay = DAY, skySeconds = 43200, skyMode = "Local" }, saved)
assert(actions.sky == nil and actions.mode == nil)
actions = M.plan({ gameTime = t, millisPerDay = 0, skySeconds = 43200, skyMode = "Constant" }, saved)
assert(actions.calendar == nil and actions.sky == nil)

-- 5b. "Sun and moon" switched off: the sky is handed back once, the long day stays
do
	local a, s, c = M.plan({ gameTime = t, millisPerDay = DAY, skySeconds = 43200, skyMode = "Constant", skyOn = false },
		{ version = 1, calendarSet = true, modeSet = true, modeBefore = "Dynamic", setAt = 0 })
	assert(a.mode == "Dynamic" and a.sky == nil and a.calendar == nil and c and not s.modeSet)
	a, s, c = M.plan({ gameTime = t + 100, millisPerDay = DAY, skySeconds = 43200, skyMode = "Dynamic", skyOn = false }, s)
	assert(a.mode == nil and a.sky == nil and not c, "nothing more is touched while it is off")
	-- a player who chose a cycle of their own meanwhile keeps it
	a = M.plan({ gameTime = t, millisPerDay = DAY, skySeconds = 43200, skyMode = "Local", skyOn = false },
		{ version = 1, calendarSet = true, modeSet = true, modeBefore = "Dynamic", setAt = 0 })
	assert(a.mode == nil)
	-- off from the start: the sky is never taken, the day is still made long
	a, s = M.plan({ gameTime = 50000, millisPerDay = 4000, skySeconds = 43200, skyMode = "Dynamic", skyOn = false }, nil)
	assert(a.calendar == DAY and a.mode == nil and not s.modeSet)
	-- switched on again: taken over again
	a, s = M.plan({ gameTime = t, millisPerDay = DAY, skySeconds = 43200, skyMode = "Dynamic", skyOn = true }, s)
	assert(a.mode == "Constant" and s.modeSet and s.modeBefore == "Dynamic")
end
-- the mod's own description of itself
do
	local f = assert(io.open("mod/tf3api_day_clock/mod.json", "rb")); local text = f:read("*a"); f:close()
	assert(text:find('"modId": "celmi_timetables"', 1, true), "the Timetables mod is declared incompatible")
	assert(text:find('"key": "sky"', 1, true) and text:find('"defaultIndex": 0', 1, true))
end

-- 6. the departure boards read the same clock when the day is long
do
	local chunk = assert(loadfile("mod/tf3api_departure_boards/content/tf3api_departure_boards/boards.script.lua"))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	local B = env.data()
	assert(type(B.clockOf) == "function")
	assert(B.clockOf(3 * DAY + DAY / 2, DAY) == 43200, "long day: the time within the day")
	assert(B.clockOf(3723000, 4000) == 3723, "short day: the running time as a clock")
	assert(B.clockOf(90061000, 4000) == 3661, "the running time wraps at 24 hours")
	assert(B.clockOf(3723000, 0) == 3723)
	assert(B.clockOf(nil, DAY) == nil)
end

print("day clock test: ALL OK")
