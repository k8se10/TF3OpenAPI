-- TF3OpenAPI - road names: what the naming script needs around it when it runs in the worker's Lua state.
--
-- The worker state (see lua_worker.h in the native source) has Lua's base, string, table and math libraries
-- and the tf3api table, and nothing of the game. This file is loaded first and supplies the few names the
-- naming script expects from the game's script environment; worker.lua, loaded last, is the entry point.

-- the script loads its modules with ug_require("<mod>::/road_names/<file>"): here they are globals already,
-- put there by the worker under the file's name (core.lua -> core)
function ug_require(path)
	local file = tostring(path):match("([%w_]+)%.[%w_%.]*lua$") or tostring(path)
	local module = _G[file]
	if type(module) ~= "table" then error("module not loaded in the worker: " .. tostring(path)) end
	return module
end

-- log lines are collected and handed back with the job's result
WORKER_LOG = {}
function debugPrint(text) WORKER_LOG[#WORKER_LOG + 1] = tostring(text) end
print = debugPrint

-- no clock is needed for the work itself (there is nothing to share a frame with), only so that timing code runs
os = os or { clock = function() return 0 end }

return {}
