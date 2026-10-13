-- TF3OpenAPI - departure boards: what the boards show.
--
-- The lit dots of a board are written into its texture by the TF3OpenAPI native layer; this script says what
-- to write (tf3api.boardRows, tf3api.boardClock). Without the native layer nothing here does anything and a
-- board shows the picture it ships with.
--
-- How a board works, as in the older game's displays mod (re_notes/boards/reference_tf2_displays.md):
--   * place it near a station and it joins that station by itself - no number, no setting;
--   * once joined it is that station's board for good;
--   * a departures board lists the vehicles leaving the station, an arrivals board those approaching it:
--     place, line, platform, time ("Due" when it is about to), the station's name, a clock;
--   * "Sorry no service" when nothing is known; the "not connected" lines while it has joined no station.
--
-- Joining rebuilds the board once (a build command, like placing it): the station and the screen it uses
-- are kept in the board's own settings, so nothing of this script is stored in the save.
--
-- Everything read from the game is read a little at a time: boards are looked for a few hundred
-- constructions per frame, and one screen is worked out at a time.

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
local SURVEY_PAUSE = 240          -- frames between two searches
local SCREEN_EVERY = 20           -- frames between working out two screens
local REBUILD_EVERY = 30          -- frames between two boards being rebuilt
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
	boards = {},         -- found boards
	content = {},        -- [slot] = { station = group, kind = }
	stationName = {},    -- [group] = name
	rebuilds = {},       -- boards waiting to be rebuilt: { board =, station =, slot = }
	rebuildAt = 0,
	asked = {},          -- [board id] = frame at which its rebuild was sent (not asked again until the next search has seen it)
	toldNoStation = {},  -- [board id] = true once said
	-- the screens
	nextSlot = 0,
	screenAt = 0,
	sent = {},           -- [slot] = the rows last sent, joined
	toldScreens = 0,
	toldRebuilds = 0,
	choices = {},        -- [board id] = { platforms = "1,3", mode = } chosen in the board's window
}

local function bridge()
	if state.bridge == nil then
		local ok, t = pcall(function() return tf3api end)
		if ok and type(t) == "table" and type(t.boardClock) == "function" then
			state.bridge = t
			state.core = loadModule("boards_core.lua")
			log("the native layer is there: the boards' clock runs" .. (type(t.boardRows) == "function" and "" or " (an older layer: no departures)")
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
-- counts in the same time, can be shown on it. It is the same clock as the TF3OpenAPI day clock mod's.
-- (Not the time of day of the sky: in the game's usual setting the sky does not run through a day.)
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

-- a construction's place in full: where it stands, its height, and the direction of its second axis on the
-- ground (for a station built along its first axis, the direction across the platforms)
local function frameOf(transf)
	local ok, x, y, z, ux, uy = pcall(function()
		local c, a = transf:cols(3), transf:cols(1)
		return c.x, c.y, c.z, a.x, a.y
	end)
	if ok and type(x) == "number" and type(z) == "number" and type(ux) == "number" then return x, y, z, ux, uy end
	ok, x, y, z, ux, uy = pcall(function() return transf[13], transf[14], transf[15], transf[5], transf[6] end)
	if ok and type(x) == "number" and type(z) == "number" and type(ux) == "number" then return x, y, z, ux, uy end
	return nil
end

local function nameOf(entity)
	local ok, name = pcall(function() return api.engine.getComponent(entity, api.type.ComponentType.NAME).name end)
	if ok and type(name) == "string" then return name end
	return ""
end

-- ---- stations ---------------------------------------------------------------------------------------------

-- every station group with its place and, where the game says it, its outline on the ground
local function stations()
	local out = {}
	local ok, problem = pcall(function()
		local toConstruction = api.engine.system.streetConnectorSystem.getStation2ConstructionMap()
		for _, group in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.STATION_GROUP)) do
			local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
			local entry
			for _, station in ipairs(comp.stations) do
				local construction = toConstruction[station]
				if construction ~= nil then
					local x, y = placeOf(api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION).transf)
					if x ~= nil then
						if entry == nil then
							entry = { id = group, name = nameOf(group), x = x, y = y }
							local _, _, z, ux, uy = frameOf(api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION).transf)
							entry.z, entry.upX, entry.upY = z, ux, uy
						end
						pcall(function()
							local box = api.engine.getComponent(construction, api.type.ComponentType.BOUNDING_VOLUME).bbox
							local x0, y0, x1, y1 = box.min.x, box.min.y, box.max.x, box.max.y
							if type(x0) == "number" and type(x1) == "number" and x1 >= x0 and y1 >= y0 then
								entry.x0 = math.min(entry.x0 or x0, x0)
								entry.y0 = math.min(entry.y0 or y0, y0)
								entry.x1 = math.max(entry.x1 or x1, x1)
								entry.y1 = math.max(entry.y1 or y1, y1)
							end
						end)
					end
				end
			end
			if entry ~= nil then out[#out + 1] = entry end
		end
	end)
	if not ok and not state.toldStations then
		state.toldStations = true
		log("stations could not be listed: " .. tostring(problem))
	end
	return out
end

-- The platforms of a station group: the terminal numbers of its stations, from 1 (several stations in a group
-- are numbered on: their terminals follow each other).
local function platformsOf(group)
	local out = {}
	pcall(function()
		local comp = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
		local n = 0
		for _, station in ipairs(comp.stations) do
			local s = api.engine.getComponent(station, api.type.ComponentType.STATION)
			for _ = 1, #s.terminals do
				n = n + 1
				out[#out + 1] = n
			end
		end
	end)
	return out
end

-- Choices made in a board's window: "set\tid\tplatforms\tmode". Kept for the session at once, and written into
-- the board itself by rebuilding it, so that they stay with the save.
local function takeChoices()
	local b = state.bridge
	if type(b) ~= "table" or type(b.take) ~= "function" then return end
	for _ = 1, 16 do
		local ok, message = pcall(b.take, MOD_ID)
		if not ok or type(message) ~= "string" then return end
		local id, platforms, mode = message:match("^set\t(%d+)\t([^\t]*)\t([^\t]*)$")
		id = tonumber(id)
		if id ~= nil then
			state.choices[id] = { platforms = platforms, mode = mode == "cycle" and "cycle" or "merged" }
			log(string.format("board %d: platforms %s, %s", id, platforms ~= "" and platforms or "all", mode))
			for _, board in ipairs(state.boards) do
				if board.id == id and board.asset then
					board.platforms = platforms ~= "" and platforms or nil
					board.mode = state.choices[id].mode
					local p = board.placedIndex ~= nil and state.placed ~= nil and state.placed[board.placedIndex] or nil
					if p ~= nil then
						p.platforms, p.mode = platforms, board.mode
						savePlaced()
					end
				elseif board.id == id and board.station ~= nil then
					board.platforms = platforms ~= "" and platforms or nil
					board.mode = state.choices[id].mode
					state.rebuilds[#state.rebuilds + 1] = { board = board, station = board.station, slot = board.slot or 0, keep = true }
				end
			end
			state.surveyAt = state.frame   -- work the screens out again now
		end
	end
end

-- ---- looking for the boards (a little per frame), joining them, giving them screens ------------------------

local function readBoard(entity)
	local comp = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
	local file = tostring(comp.fileName)
	-- (diagnostic: what the game calls a few constructions, and any that look like ours)
	state.seenFiles = state.seenFiles or {}
	if #state.seenFiles < 4 or (file:lower():find("board", 1, true) and #state.seenFiles < 12) then
		state.seenFiles[#state.seenFiles + 1] = string.format("%d=%s(%s)", entity, file, type(comp.fileName))
	end
	if file:find(MOD_ID, 1, true) == nil or file:find("board_", 1, true) == nil then return nil end
	local x, y = placeOf(comp.transf)
	if x == nil then error("a board's place could not be read from its placement") end
	local _, _, z = frameOf(comp.transf)
	local board = { id = entity, file = file, x = x, y = y, z = z or 0, transf = comp.transf,
		kind = file:find("arrivals", 1, true) ~= nil and state.core.ARRIVALS or state.core.DEPARTURES }
	pcall(function()
		local station = tonumber(comp.params.station)
		if station ~= nil and station > 0 then board.station = station end
		local screen = tonumber(comp.params.screen)
		if screen ~= nil and screen >= 1 and board.station ~= nil then board.slot = math.floor(screen) - 1 end
		if type(comp.params.platforms) == "string" then board.platforms = comp.params.platforms end
		if comp.params.mode == "cycle" then board.mode = "cycle" end
	end)
	-- a choice made in the board's window this session counts before what the board was built with
	local chosen = state.choices[entity]
	if chosen ~= nil then board.platforms, board.mode = chosen.platforms, chosen.mode end
	if board.platforms == "" then board.platforms = nil end
	return board
end

local function surveyDone(boards, total)
	local core = state.core
	local list = #boards > 0 and stations() or {}
	state.stationName = {}
	for _, station in ipairs(list) do state.stationName[station.id] = station.name end
	state.rebuilds = {}
	-- a board that has joined no station yet joins the nearest one in reach
	for _, board in ipairs(boards) do
		if board.station == nil then
			local near = core.nearby(board.x, board.y, list)
			if #near > 0 then
				board.station = near[1].station.id
				board.joining = true
				if #near > 1 and not state.toldNoStation[board.id] then
					log(string.format("board %d: %d stations in reach; joining the nearest, %s", board.id, #near, near[1].station.name))
				end
			elseif not state.toldNoStation[board.id] then
				state.toldNoStation[board.id] = true
				log(string.format("board %d: cannot find a nearby station to join (within %d m of one)", board.id, core.JOIN_REACH))
			end
		end
	end
	local change, content, full = core.allocate(boards)
	state.content = content
	-- The game does not let assets be clicked: the native layer is told where the boards are, and the
	-- board window (gui/tf3api_boards) is told what to show about each.
	-- (Boards are plain constructions now and the game itself opens their window; our own click spots are
	-- only for boards the game cannot pick, which there are none of: the list is kept empty.)
	-- The game cannot select a board it has put into an asset group: those get our own click (the native
	-- layer) and our own window.
	if type(state.bridge) == "table" and type(state.bridge.boardSpots) == "function" then
		local lines = {}
		for _, board in ipairs(boards) do if board.asset then lines[#lines + 1] = string.format("%d %.2f %.2f %.2f 1.8", board.id, board.x, board.y, (board.z or 0) + 1.7) end end
		pcall(state.bridge.boardSpots, table.concat(lines, "\n"))
	end
	if type(state.bridge) == "table" and type(state.bridge.post) == "function" then
		for _, board in ipairs(boards) do
			local platforms = board.station ~= nil and platformsOf(board.station) or {}
			pcall(state.bridge.post, MOD_ID .. ".ui", table.concat({ "board", tostring(board.id),
				board.station ~= nil and tostring(state.stationName[board.station] or "") or "", tostring(board.kind),
				table.concat(platforms, ","), tostring(board.platforms or ""), tostring(board.mode or "merged"),
				tostring(board.group or "") },"\t"))
		end
	end
	-- The live picture in a board's own window (the game shows one for every construction) looks straight
	-- down at the board's station: the plan the platform chooser will be laid over. Needs the native layer.
	if type(state.bridge) == "table" and type(state.bridge.planView) == "function" then
		local byId, shown = {}, 0
		for _, station in ipairs(list) do byId[station.id] = station end
		for _, board in ipairs(boards) do
			local station = board.station ~= nil and byId[board.station] or nil
			if station ~= nil and station.z ~= nil and shown < 8 then
				local cx, cy, dx, dy = station.x, station.y, nil, nil
				if station.x0 ~= nil then
					cx, cy = (station.x0 + station.x1) / 2, (station.y0 + station.y1) / 2
					dx, dy = station.x1 - station.x0, station.y1 - station.y0
				end
				-- the camera's height follows the station's size: its length and its width (number of platforms)
				local height, along, across = core.planHeight(dx, dy, station.upX or 0, station.upY or 1)
				local ok = state.bridge.planView(tostring(board.group or -1), string.format("%.2f %.2f %.2f %.2f %.4f %.4f",
					cx, cy, station.z, height, station.upX or 0, station.upY or 1))
				shown = shown + 1
				if not state.toldPlan then
					state.toldPlan = true
					log(string.format("plan view of %s for board %d: %s (station %.0f m along, %.0f m across; camera %.0f m up)", tostring(station.name),
						board.id, ok and "set" or "not taken by the native layer", along, across, height))
				end
			end
		end
	end
	for _, board in ipairs(boards) do
		local slot = change[board.id]
		if slot ~= nil and state.asked[board.id] == nil then
			state.rebuilds[#state.rebuilds + 1] = { board = board, station = board.station, slot = slot }
		end
	end
	state.asked = {}
	if #full > 0 and not state.toldFull then
		state.toldFull = true
		log(string.format("%d board(s) have no screen: all %d different screens are in use", #full, core.SLOTS))
	end
	if #boards ~= #state.boards or #state.rebuilds > 0 then
		local screens = 0
		for _ in pairs(content) do screens = screens + 1 end
		log(string.format("%d board(s) among %d constructions; %d screen(s) in use; %d board(s) to be joined", #boards, total, screens, #state.rebuilds))
	end
	state.boards = boards
end

-- The models of our boards (every screen's), as the game numbers them: a board the game has put into an asset
-- group is no construction, and is known only by its model.
local function boardModels()
	if state.models ~= nil then return state.models end
	local models = {}
	pcall(function()
		local names = { MOD_ID .. "::/" .. MOD_ID .. "/board_modern_pole.mdl" }
		for slot = 0, 31 do names[#names + 1] = string.format("%s::/%s/board_modern_pole_%02d.mdl", MOD_ID, MOD_ID, slot) end
		for i, name in ipairs(names) do
			local id = api.res.modelRep.find(name)
			if type(id) == "number" and id >= 0 then models[id] = math.max(i - 2, 0) end   -- the screen the model shows
		end
	end)
	state.models = models
	return models
end

-- The boards in an asset group: one per instance of a board model. Their id is the group's entity number
-- times 64 plus the instance's place (a group can hold several boards built together).
local function readAssetBoards(entity, out)
	local models = boardModels()
	local list = api.engine.getComponent(entity, api.type.ComponentType.MODEL_INSTANCE_LIST)
	if list == nil then return end
	local count = 0
	for i, instance in ipairs(list.fatInstances) do
		local slot = models[instance.modelId]
		if slot ~= nil then
			local x, y = placeOf(instance.transf)
			local _, _, z = frameOf(instance.transf)
			if x ~= nil then
				count = count + 1
				local id = entity * 64 + (i - 1)
				local board = { id = id, group = entity, asset = true, fixed = true, file = "asset", x = x, y = y, z = z or 0, transf = instance.transf,
					kind = state.core.DEPARTURES, slot = slot }
				local chosen = state.choices[id]
				if chosen ~= nil then board.platforms, board.mode, board.station = chosen.platforms, chosen.mode, chosen.station end
				if board.platforms == "" then board.platforms = nil end
				out[#out + 1] = board
			end
		end
	end
end

local function surveyStep()
	local survey = state.survey
	if survey == nil then
		if state.frame < state.surveyAt or #state.rebuilds > 0 then return end
		local ok, entities = pcall(function() return api.engine.getEntitiesWithComponent(api.type.ComponentType.CONSTRUCTION) end)
		if not ok or type(entities) ~= "table" then
			if not state.toldSurvey then
				state.toldSurvey = true
				log("the game's constructions could not be listed: " .. tostring(entities))
			end
			state.surveyAt = state.frame + SURVEY_PAUSE
			return
		end
		-- asset groups too: the game puts anything it takes for an asset into one
		local okGroups, groups = pcall(function() return api.engine.getEntitiesWithComponent(api.type.ComponentType.ASSET_GROUP) end)
		if not okGroups or type(groups) ~= "table" then groups = {} end
		state.survey = { entities = entities, groups = groups, cursor = 1, groupCursor = 1, boards = {} }
		return
	end
	local last = math.min(#survey.entities, survey.cursor + SURVEY_PER_FRAME - 1)
	for i = survey.cursor, last do
		local ok, board = pcall(readBoard, survey.entities[i])
		if ok and board ~= nil then
			survey.boards[#survey.boards + 1] = board
		elseif not ok then
			survey.failed = (survey.failed or 0) + 1
			survey.why = survey.why or tostring(board)
		end
	end
	survey.cursor = last + 1
	if survey.cursor <= #survey.entities then return end
	if not survey.placedTaken then
		survey.placedTaken = true
		for i, p in ipairs(state.placed or {}) do
			local id = 1000 + i   -- not an entity of the game: our own number
			local board = { id = id, placedIndex = i, asset = true, fixed = true, file = "placed", x = p.x, y = p.y, z = p.z,
				kind = p.kind == "arrivals" and state.core.ARRIVALS or state.core.DEPARTURES, slot = 0,
				platforms = p.platforms ~= "" and p.platforms or nil, mode = p.mode }
			-- the game's entity at that spot, for the live picture in the window
			pcall(function()
				local near = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), 3, api.type.ComponentType.ASSET_GROUP)
				if type(near) == "table" and near[1] ~= nil then board.group = near[1] end
			end)
			survey.boards[#survey.boards + 1] = board
			survey.inGroups = (survey.inGroups or 0) + 1
		end
	end
	if survey.groupCursor <= #survey.groups then
		local lastGroup = math.min(#survey.groups, survey.groupCursor + SURVEY_PER_FRAME - 1)
		for i = survey.groupCursor, lastGroup do
			local before = #survey.boards
			local ok, why = pcall(readAssetBoards, survey.groups[i], survey.boards)
			if not ok then
				survey.failed = (survey.failed or 0) + 1
				survey.why = survey.why or tostring(why)
			end
			survey.inGroups = (survey.inGroups or 0) + (#survey.boards - before)
		end
		survey.groupCursor = lastGroup + 1
		if survey.groupCursor <= #survey.groups then return end
	end
	do
		state.survey = nil
		state.surveyAt = state.frame + SURVEY_PAUSE
		if not state.toldFirstSurvey then
			state.toldFirstSurvey = true
			log(string.format("first search: %d constructions and %d asset groups looked at, %d board(s) found (%d in asset groups), %d could not be read%s",
				#survey.entities, #survey.groups, #survey.boards, survey.inGroups or 0, survey.failed or 0, survey.why ~= nil and (" (" .. survey.why .. ")") or ""))

		end
		state.surveys = (state.surveys or 0) + 1
		if state.surveys <= 3 or #survey.boards ~= (state.lastBoardCount or 0) then
			state.lastBoardCount = #survey.boards
			log(string.format("search %d: %d board(s) (%d in asset groups)", state.surveys, #survey.boards, survey.inGroups or 0))
		end
		if false then log(string.format("search %d: %d board(s); constructions seen: %s", state.surveys, #survey.boards,
			table.concat(state.seenFiles or {}, "; "))) end
		state.seenFiles = {}
		surveyDone(survey.boards, #survey.entities)
	end
end

-- Rebuilds a board with its station and its screen in its settings: the old one out, the new one in, in one
-- build command.
local function rebuildStep()
	if #state.rebuilds == 0 or state.frame < state.rebuildAt then return end
	state.rebuildAt = state.frame + REBUILD_EVERY
	local job = table.remove(state.rebuilds, 1)
	local board = job.board
	state.asked[board.id] = state.frame
	local ok, problem = pcall(function()
		local entity = api.type.SimpleProposal.ConstructionEntity.new()
		entity.fileName = board.file
		entity.params = { station = job.station, screen = job.slot + 1, seed = 0,
			platforms = board.platforms or "", mode = board.mode or "merged" }
		entity.transf = board.transf
		entity.name = "Departure board"
		entity.playerEntity = api.engine.util.getPlayer()
		local proposal = api.type.SimpleProposal.new()
		proposal.constructionsToAdd[1] = entity
		proposal.constructionsToRemove = { board.id }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false), function(_result, success)
			if state.toldRebuilds < 8 then
				state.toldRebuilds = state.toldRebuilds + 1
				log(string.format("board %d %s %s (screen %d)", board.id, success and "joined" or "could NOT be joined to",
					tostring(state.stationName[job.station] or job.station), job.slot + 1))
			end
		end)
	end)
	if not ok and state.toldRebuilds < 8 then
		state.toldRebuilds = state.toldRebuilds + 1
		log("board " .. tostring(board.id) .. ": the build command could not be made: " .. tostring(problem))
	end
end

-- ---- one screen's vehicles --------------------------------------------------------------------------------

-- The game counts stops from 0 where it names one by number (a vehicle's next stop, a line stop of a
-- station, a terminal); its lists are counted from 1 as lists are. Departure times are milliseconds of game
-- time, section times seconds.
local function vehiclesOf(station, kind, now, only)
	local core = state.core
	local out = {}
	local AT_TERMINAL = api.type.enum.TransportVehicleState.AT_TERMINAL
	local EN_ROUTE = api.type.enum.TransportVehicleState.EN_ROUTE
	for _, lineStop in ipairs(api.engine.system.lineSystem.getLineStops(station)) do
		local lineEntity, stopIndex = lineStop[1], lineStop[2]
		local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE)
		local n = #line.stops
		local target = stopIndex + 1
		if n >= 2 and target >= 1 and target <= n then
			local names = {}
			for i = 1, n do names[i] = nameOf(line.stops[i].stationGroup) end
			local here = names[target]
			local place = kind == core.ARRIVALS and core.origin(names, target, here) or core.destination(names, target, here)
			local platform = tostring((tonumber(line.stops[target].terminal) or 0) + 1)
			if only ~= nil and not only[tonumber(platform)] then n = 0 end   -- not a platform this board serves
			local lineName = nameOf(lineEntity)
			local ids = api.engine.system.transportVehicleSystem.getLineVehicles(lineEntity)
			local vehicles, sections = {}, {}
			for v = 1, math.min(#ids, VEHICLES_PER_LINE) do
				local tv = api.engine.getComponent(ids[v], api.type.ComponentType.TRANSPORT_VEHICLE)
				if tv.state == AT_TERMINAL or tv.state == EN_ROUTE then
					local list = {}
					for i = 1, n do
						local seconds = tonumber(tv.sectionTimes[i]) or 0
						if seconds > 100000 then seconds = seconds / 1000 end   -- should a build count them in milliseconds
						list[i] = seconds
					end
					sections[#sections + 1] = list
					local stop = (tonumber(tv.stopIndex) or 0) + 1
					local before = stop == 1 and n or stop - 1
					local left = tonumber(tv.lineStopDepartures[before])
					vehicles[#vehicles + 1] = { stop = stop, atStop = tv.state == AT_TERMINAL,
						since = (left ~= nil and left > 0) and (now - left) / 1000 or nil }
				end
			end
			local averages = core.averages(n, sections)
			for _, vehicle in ipairs(vehicles) do
				local eta = core.eta(n, averages, vehicle, target)
				if eta ~= nil then
					-- a departures board shows when it leaves: a vehicle still on its way stands a while first
					if kind ~= core.ARRIVALS and eta > 0 then eta = eta + core.DWELL end
					out[#out + 1] = { eta = eta, place = place, line = lineName, platform = platform }
				end
			end
		end
	end
	return out
end

local function screenStep(b, clock, now)
	if type(b.boardRows) ~= "function" then return end
	if state.frame < state.screenAt then return end
	state.screenAt = state.frame + SCREEN_EVERY
	local core = state.core
	local slot
	for step = 0, core.SLOTS - 1 do
		local s = (state.nextSlot + step) % core.SLOTS
		if state.content[s] ~= nil then
			slot = s
			break
		end
	end
	if slot == nil then return end
	state.nextSlot = (slot + 1) % core.SLOTS
	local content = state.content[slot]
	local name = state.stationName[content.station] or nameOf(content.station)
	local only, list = core.platformSet(content.platforms)
	if only ~= nil and content.mode == "cycle" and #list > 1 then
		-- one platform at a time, each for core.CYCLE seconds
		local pick = list[(math.floor(clock / core.CYCLE) % #list) + 1]
		only = { [pick] = true }
	end
	local ok, vehicles = pcall(vehiclesOf, content.station, content.kind, now, only)
	if not ok then
		if state.toldScreens < 3 then
			state.toldScreens = state.toldScreens + 1
			log("screen " .. (slot + 1) .. " (" .. tostring(name) .. "): could not be worked out: " .. tostring(vehicles))
		end
		vehicles = {}
	end
	local rows = core.rows(content.kind, clock, { name = name }, vehicles)
	local joined = table.concat(rows, "\n")
	if state.sent[slot] ~= joined then
		state.sent[slot] = joined
		b.boardRows(tostring(slot), rows[1], rows[2], rows[3], rows[4], rows[5])
		if state.toldScreens < 6 then
			state.toldScreens = state.toldScreens + 1
			log(string.format("screen %d: %s of %s, %d vehicle(s) known; first row \"%s\"", slot + 1, content.kind, tostring(name), #vehicles,
				(rows[2]:gsub("\t", " | "))))
		end
	end
end

-- ---- Boards as the player builds them -------------------------------------------------------------------------
-- The game puts a board into an asset group, which no script can find again. So, as in the older game's
-- displays mod, boards are noted when they are built: the game's build tool announces its proposal
-- ("builder.proposalCreate", with what it is about to add) and then that it was built ("builder.proposalApply").
-- The list is kept in this script's saved state, so it comes back with the save.
--   placed = { { x, y, z, kind, platforms, mode }, ... }

local EVENT_ID = "tf3api_departure_boards"

local function placedToText(list)
	local lines = {}
	for _, b in ipairs(list) do
		lines[#lines + 1] = string.format("%.2f %.2f %.2f %s %s %s", b.x, b.y, b.z, b.kind, b.platforms ~= "" and b.platforms or "-", b.mode or "merged")
	end
	return table.concat(lines, "\n")
end

local function placedFromText(text)
	local list = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local x, y, z, kind, platforms, mode = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
		if tonumber(x) ~= nil then
			list[#list + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), kind = kind,
				platforms = platforms ~= "-" and platforms or "", mode = mode }
		end
	end
	return list
end

-- hands the list to the simulation side, which keeps it in the save
local function savePlaced()
	pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", EVENT_ID, "setBoards", { text = placedToText(state.placed) }))
	end)
end

local pendingBoards = nil   -- boards in the proposal the build tool shows now

local function boardsInProposal(proposal)
	local found = {}
	for _, entry in ipairs(proposal.toAdd or {}) do
		local file = tostring(entry.fileName)
		if file:find(MOD_ID, 1, true) ~= nil and file:find("board_", 1, true) ~= nil then
			local x, y, z = frameOf(entry.transf)
			if x ~= nil then
				found[#found + 1] = { x = x, y = y, z = z or 0, kind = file:find("arrivals", 1, true) and "arrivals" or "departures",
					platforms = "", mode = "merged" }
			end
		end
	end
	return found
end

local function guiHandleEvent(_params, _state, _guiState, _src, id, name, param)
	local ok, problem = pcall(function()
		if name == "builder.proposalCreate" then
			pendingBoards = nil
			if type(param) == "table" and param[1] ~= nil then
				local found = boardsInProposal(param[1])
				if #found > 0 then pendingBoards = found end
			end
		elseif name == "builder.proposalApply" and pendingBoards ~= nil then
			state.placed = state.placed or {}
			for _, board in ipairs(pendingBoards) do state.placed[#state.placed + 1] = board end
			log(string.format("%d board(s) built; %d known", #pendingBoards, #state.placed))
			pendingBoards = nil
			savePlaced()
			state.surveyAt = state.frame   -- take them in now
		end
	end)
	if not ok and not state.toldEvent then
		state.toldEvent = true
		log("a build event could not be read: " .. tostring(problem))
	end
	return nil
end

-- Simulation side: only the saved list. Nothing is kept in variables here.
local function update(_params, s, _dt)
	if s ~= nil and not s:hasEventSubscriptions() then
		s:subscribeToEvent("setBoards")
		s:subscribeToEvent("builder.proposalCreate")
		s:subscribeToEvent("builder.proposalApply")
	end
end

local function handleEvent(_params, s, _src, id, name, param)
	if id ~= EVENT_ID or name ~= "setBoards" or s == nil then return end
	if type(param) == "table" and type(param.text) == "string" then s:set({ version = 1, text = param.text }) end
end

local function guiUpdate(_params, s, _guiState)
	if state.placed == nil then
		state.placed = {}
		local ok, saved = pcall(function() return s:get() end)
		if ok and type(saved) == "table" and type(saved.text) == "string" then state.placed = placedFromText(saved.text) end
		log(string.format("%d board(s) known from the save", #state.placed))
	end
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
			takeChoices()
			surveyStep()
			rebuildStep()
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
		guiHandleEvent = guiHandleEvent,
		update = update,
		handleEvent = handleEvent,
		clockOf = clockOf,   -- for tests
		placedToText = placedToText, placedFromText = placedFromText,
	}
end
