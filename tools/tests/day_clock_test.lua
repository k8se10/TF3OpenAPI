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

-- 3. first run on a save (Realistic): the day is made long; the sky's cycle is the player's (never set)
local actions, saved, changed = M.plan(now(), nil)
assert(actions.calendar == DAY and actions.mode == nil and actions.sky == nil and changed)
assert(saved.version == 1 and saved.before == 4000 and saved.calendarSet and not saved.modeSet)

-- 4. the command has not taken effect yet: not sent again straight away, sent again after a while
actions, saved, changed = M.plan(now({ gameTime = 50100 }), saved)
assert(actions.calendar == nil and actions.mode == nil and actions.sky == nil and not changed)
actions = M.plan(now({ gameTime = 56000, skyMode = "Constant" }), { version = 1, calendarSet = true, setAt = 50000, before = 4000 })
assert(actions.calendar == DAY)

-- 5. running, with the game's continuous cycle chosen: the sky is kept on the clock
local t = 3 * DAY + 6 * HOUR   -- 06:00
local F = M.FOLLOW_MODE
actions, saved, changed = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = F }), saved)
assert(actions.calendar == nil and actions.mode == nil and actions.sky == 21600 and not changed)
actions = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = F, skySeconds = 21600 + M.SKY_STEP - 1 }), saved)
assert(actions.sky == nil)
actions = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = F, skySeconds = 21600 + 61 }), saved)
assert(actions.sky == 21600, "the game's own continuous cycle moved it on: back on the clock")
actions = M.plan(now({ gameTime = 4 * DAY + 500, millisPerDay = DAY, skyMode = F, skySeconds = 86400 - 1 }), saved)
assert(actions.sky == nil, "a second before midnight is close enough to just after it")
-- Custom (the game's own slider): the sky is the player's
actions = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Constant", skySeconds = 50000 }), saved)
assert(actions.sky == nil and actions.mode == nil, "Custom is the game's own slider: never moved")

-- 6. the player's own choices are respected: another sky cycle, a stopped calendar
actions = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Local" }), saved)
assert(actions.sky == nil and actions.mode == nil)
actions = M.plan(now({ gameTime = t, millisPerDay = 0, skyMode = "Constant", skySeconds = 21600 }), saved)
assert(actions.calendar == nil)

-- 7. Balanced: the same clock and sky, a calendar day of one hour
do
	local a, s = M.plan(now({ dayMs = HOUR }), nil)
	assert(a.calendar == HOUR and s.before == 4000)
	a = M.plan(now({ gameTime = t, millisPerDay = HOUR, dayMs = HOUR, skyMode = F }), s)
	assert(a.calendar == nil and a.sky == 21600, "the sky follows the real-time clock, not the calendar day")
	-- changing from Realistic to Balanced: set again, and what the game had before us is still remembered
	a, s = M.plan(now({ gameTime = t, millisPerDay = DAY, dayMs = HOUR, skyMode = F, skySeconds = 21600 }),
		{ version = 1, calendarSet = true, before = 4000, setAt = 0 })
	assert(a.calendar == HOUR and s.before == 4000)
end

-- 8. Transport Fever: the calendar is never touched; if another mode had changed it, it is put back once
do
	local a, s, c = M.plan(now({ dayMs = false }), nil)
	assert(a.calendar == nil and a.mode == nil and not s.calendarSet, "nothing is taken")
	a, s, c = M.plan(now({ gameTime = t, millisPerDay = DAY, dayMs = false, skyMode = F, skySeconds = 21600 }),
		{ version = 1, calendarSet = true, before = 2000, setAt = 0 })
	assert(a.calendar == 2000 and c and not s.calendarSet and s.before == nil, "back to what the save had")
	a = M.plan(now({ gameTime = t, millisPerDay = DAY, dayMs = false, skyMode = F, skySeconds = 21600 }),
		{ version = 1, calendarSet = true, before = 0, setAt = 0 })
	assert(a.calendar == 4000, "nothing usable remembered: the game's own day")
	a, s, c = M.plan(now({ gameTime = t + 10, millisPerDay = 2000, dayMs = false, skyMode = F, skySeconds = 21600 }), s)
	assert(a.calendar == nil and not c, "and then left alone, whatever the player sets")
end

-- 9. "Sun and moon" switched off: the continuous cycle is the game's own pace again
do
	local a = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = F, skySeconds = 50000, skyOn = false }),
		{ version = 1, calendarSet = true, setAt = 0 })
	assert(a.sky == nil and a.mode == nil, "the sky is left alone")
end

-- 9b. a save from the earlier version, which had switched the cycle to Custom itself: put on the continuous
--     cycle once (the one that follows the clock now); a cycle the player chose meanwhile is kept
do
	local old = function() return { version = 1, calendarSet = true, modeSet = true, modeBefore = "Dynamic", setAt = 0 } end
	local a, s, c = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Constant" }), old())
	assert(a.mode == F and c and not s.modeSet and s.modeBefore == nil, "Custom set by us: on the continuous cycle")
	a, s, c = M.plan(now({ gameTime = t + 100, millisPerDay = DAY, skyMode = "Constant", skySeconds = 50000 }), s)
	assert(a.mode == nil and a.sky == nil and not c, "and then Custom is the player's own choice")
	a = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Local" }), old())
	assert(a.mode == nil, "a cycle the player chose meanwhile is kept")
	a = M.plan(now({ gameTime = t, millisPerDay = DAY, skyMode = "Constant", skyOn = false }), old())
	assert(a.mode == "Dynamic", "with the sky setting off: back to what it was")
end

-- 10. the mod's own description of itself
do
	local f = assert(io.open("mod/tf3api_day_clock/mod.json", "rb")); local text = f:read("*a"); f:close()
	assert(not text:find('celmi_timetables', 1, true), "the Timetables mod works alongside: not declared incompatible")
	assert(text:find('"key": "sky"', 1, true) and text:find('"key": "mode"', 1, true))
	-- the options are listed in the order the script counts them
	local a = text:find('"Realistic', 1, true); local b = text:find('"Balanced', 1, true); local c = text:find('"Transport Fever', 1, true)
	assert(a and b and c and a < b and b < c)
end

-- 12. vehicle wear and age follow the calendar: lifespans are scaled by what the day was stretched by
do
	local W = assert(loadfile(root .. "wear.lua"))()
	assert(W.factor(DAY) == 21600 and W.factor(HOUR) == 900 and W.factor(nil) == 1 and W.factor(4000) == 1)
	assert(W.factor(DAY, 2000) == 43200)
	local function model(lifespan) return { metadata = { maintenance = { lifespan = lifespan, runningCosts = -1 } } } end
	local m = model(36525)
	assert(W.scaleModel(m, 900) and m.metadata.maintenance.lifespan == 36525 * 900 and m.metadata.maintenance.runningCosts == -1)
	-- every vehicle keeps its proportion to the others
	local a, b = model(21915), model(43830)
	W.scaleModel(a, 21600); W.scaleModel(b, 21600)
	assert(b.metadata.maintenance.lifespan == 2 * a.metadata.maintenance.lifespan)
	-- the largest lifespan the game ships still fits 32 bits in Realistic; anything beyond is held there
	assert(b.metadata.maintenance.lifespan == 43830 * 21600 and b.metadata.maintenance.lifespan < 2 ^ 31)
	m = model(200000); W.scaleModel(m, 21600)
	assert(m.metadata.maintenance.lifespan == W.MAX_LIFESPAN and W.MAX_LIFESPAN < 2 ^ 31)
	-- left alone: no lifespan, "no end", no maintenance, not a vehicle, factor 1
	m = model(-1); assert(not W.scaleModel(m, 900) and m.metadata.maintenance.lifespan == -1)
	m = model(0); assert(not W.scaleModel(m, 900) and m.metadata.maintenance.lifespan == 0)
	assert(not W.scaleModel({ metadata = {} }, 900) and not W.scaleModel({}, 900) and not W.scaleModel(nil, 900))
	m = model(36525); assert(not W.scaleModel(m, 1) and m.metadata.maintenance.lifespan == 36525)

	-- the mod's script: which settings add the modifier, and with which factor
	local function run(params)
		local added, env = {}, nil
		env = setmetatable({
			require = function(name) assert(name == "tf3api_day_clock::/day_clock/wear.lua"); return W end,
			addModifier = function(kind, fn) added[#added + 1] = { kind = kind, fn = fn } end,
			debugPrint = function() end,
		}, { __index = _G })
		local chunk = assert(loadfile("mod/tf3api_day_clock/content/mod.script.lua"))
		setfenv(chunk, env)
		chunk()
		env.data().runFn({}, {}, params)
		return added
	end
	local function lifespanAfter(added)
		local m2 = model(36525)
		assert(added[1].fn("x.mdl", m2) == m2, "the modifier hands the model back")
		return m2.metadata.maintenance.lifespan
	end
	local added = run({ tf3api_day_clock = { mode = 1, sky = 1, wear = 1 } })
	assert(#added == 1 and added[1].kind == "loadModel" and lifespanAfter(added) == 36525 * 21600, "Realistic")
	added = run({ tf3api_day_clock = { mode = 2 } })
	assert(#added == 1 and lifespanAfter(added) == 36525 * 900, "Balanced")
	assert(#run({ tf3api_day_clock = { mode = 3 } }) == 0, "Transport Fever: nothing is scaled")
	assert(#run({ tf3api_day_clock = { mode = 1, wear = 2 } }) == 0, "switched off: nothing is scaled")
	added = run(nil)
	assert(#added == 1 and lifespanAfter(added) == 36525 * 21600, "no settings handed over: the defaults")
	-- a model that is not a table does not stop the game
	assert(added[1].fn("y.mdl", 5) == 5)
	-- the two scripts name the same days
	for i = 1, 3 do
		local factorOfMode = M.MODES[i].dayMs and M.MODES[i].dayMs / 4000 or 1
		local got = run({ tf3api_day_clock = { mode = i } })
		assert((#got == 0 and factorOfMode == 1) or lifespanAfter(got) == 36525 * factorOfMode)
	end
	local f = assert(io.open("mod/tf3api_day_clock/mod.json", "rb")); local text = f:read("*a"); f:close()
	assert(text:find('"key": "wear"', 1, true) and text:find('tf3api_day_clock::/mod.script@runFn', 1, true))
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
