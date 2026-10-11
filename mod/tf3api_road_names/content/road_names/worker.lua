-- TF3OpenAPI - road names: the worker's entry point.
--
-- Loaded last into the worker's Lua state, after worker_pre.lua, core.lua, names.lua, viewer_page.lua and the
-- naming script itself (road_names.script.lua, which the worker stores in the global road_names).
-- tf3_job(input) is what tf3api.workerRun(input) calls: the naming script does the work, with the roads it is
-- given as text instead of read from the game.
function tf3_job(input)
	return road_names.workerJob(input)
end

return {}
