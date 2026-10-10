-- TF3OpenAPI - HUD fix (script-only).
--
-- The town name icons on the map refresh every half second. For each icon the game calls
-- town_util.externalGetTownState(town), which asks the engine for the COMPLETE state of the towns game script
-- (every town on the map, converted into a Lua table) and then picks one town out of it. With N towns on screen
-- that is N full conversions per refresh, on the UI worker threads the frame waits for.
-- Measured on build 40408 with the in-game profiler: about 15% of each UI worker thread's CPU time.
--
-- This mod makes that lookup fetch the towns state at most once per CACHE_SECONDS per Lua state and reuse it.
-- The result is the same data, at most CACHE_SECONDS old (it feeds the growth arrow on the town label and two
-- other UI read-outs). Only the UI's Lua states are touched: the simulation scripts keep the original function,
-- so nothing in the game state or in saves changes.
--
-- Log: lines "[tf3api_hud_fix]" in crash_dump/stdout.txt.

local MOD_ID = "tf3api_hud_fix"

-- How long one fetched towns state is reused (seconds).
local CACHE_SECONDS = 1.0

local function log(msg)
	local text = "[" .. MOD_ID .. "] " .. msg
	if not pcall(function() debugPrint(text) end) then
		print(text)
	end
end

-- Seconds on a steadily increasing clock, or nil. api.util.getApplicationTime() only works on the GUI thread
-- and the icons are refreshed on worker threads, so os.clock() comes first.
local function now()
	local ok, t = pcall(os.clock)
	if ok and type(t) == "number" then return t end
	ok, t = pcall(api.util.getApplicationTime)
	if ok and type(t) == "number" then return t end
	return nil
end

local function wrapTownState(town_util)
	if town_util.tf3apiHudFixInstalled then return true end
	if type(town_util.externalGetTownState) ~= "function" or type(town_util.externalGetTownsState) ~= "function"
		or type(town_util.getTownState) ~= "function" then
		return false
	end
	local original = town_util.externalGetTownState
	local cached, cachedAt = nil, 0
	town_util.externalGetTownState = function(townEntity)
		local t = now()
		if t == nil then return original(townEntity) end
		if cached == nil or t < cachedAt or t - cachedAt > CACHE_SECONDS then
			local ok, state = pcall(town_util.externalGetTownsState)
			if not ok or type(state) ~= "table" then
				cached = nil
				return original(townEntity)
			end
			cached, cachedAt = state, t
		end
		local ok, townState = pcall(town_util.getTownState, cached, townEntity)
		if not ok then
			cached = nil
			return original(townEntity)
		end
		return townState
	end
	town_util.tf3apiHudFixInstalled = true
	return true
end

-- Called by the game while it sets up a UI Lua state (react-replacement-config). No recipe is replaced; the
-- hook is only used as the supported moment to run code inside that state.
local function doReplace(_replacementApi)
	local ok, town_util = pcall(ug_require, "::/game_mechanics/towns/town_util.tl")
	if not ok or type(town_util) ~= "table" then
		log("town_util not found - HUD fix not applied: " .. tostring(town_util))
		return
	end
	if wrapTownState(town_util) then
		log(string.format("town HUD icons: towns state is now fetched at most once per %.1f s", CACHE_SECONDS))
	else
		log("town_util has changed shape in this game build - HUD fix not applied")
	end
end

local M = {
	doReplace = doReplace,
	-- for the offline test only; the game does not call it
	wrapTownState = wrapTownState,
}

function data()
	return M
end

return M
