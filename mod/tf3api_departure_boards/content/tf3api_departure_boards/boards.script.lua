-- TF3OpenAPI - departure boards: what the boards show.
--
-- The lit dots of a board are written into its texture by the TF3OpenAPI native layer; this script only says
-- what to write (tf3api.boardLines, tf3api.boardClock). Without the native layer nothing here does anything
-- and a board shows the picture it ships with.
--
-- So far: the boards are not yet wired to stations, so the three lines are the "not connected" message, and
-- the clock runs, as on every state of a board.

local MOD = "[tf3api_departure_boards] "

local function log(text)
	pcall(function() if tf3api ~= nil and tf3api.log ~= nil then tf3api.log(MOD .. text) end end)
end

-- the three lines of a board that has no departure information (exactly these words)
local NOT_CONNECTED = { "TF3OpenAPI", "Departure information unavailable", "github.com/k8se10/TF3OpenAPI" }

local state = {
	bridge = nil,        -- false once it is known to be missing
	lastSecond = nil,    -- the clock value last sent
	linesSent = false,
	told = false,
	failures = 0,
}

local function bridge()
	if state.bridge == nil then
		local ok, t = pcall(function() return tf3api end)
		if ok and type(t) == "table" and type(t.boardClock) == "function" and type(t.boardLines) == "function" then
			state.bridge = t
			log("the native layer is there: the boards' clock runs")
		else
			state.bridge = false   -- an older native layer, or none: the boards keep their shipped picture
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

local function clockSeconds()
	local ok, seconds = pcall(function()
		local gameTime = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		return clockOf(gameTime.gameTime)
	end)
	if ok then return seconds end
	return nil
end

local function guiUpdate()
	local b = bridge()
	if not b or state.failures > 20 then return end
	local ok, problem = pcall(function()
		if not state.linesSent then
			b.boardLines(NOT_CONNECTED[1], NOT_CONNECTED[2], NOT_CONNECTED[3])
			state.linesSent = true
		end
		local seconds = clockSeconds()
		if seconds ~= state.lastSecond then
			state.lastSecond = seconds
			-- as text: the bridge takes no numbers from the game's Lua
			b.boardClock(seconds ~= nil and tostring(seconds) or "")
			if not state.told and seconds ~= nil then
				state.told = true
				log(string.format("clock: %d s (%02d:%02d)", seconds, math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60))
			end
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
