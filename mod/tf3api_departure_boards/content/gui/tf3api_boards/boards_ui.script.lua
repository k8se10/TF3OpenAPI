-- TF3OpenAPI - departure boards: the board's window, a station diagram.
--
-- The game does not let assets be selected, so a board cannot be clicked the game's way. The boards script
-- hands the boards' places to the native layer (tf3api.boardSpots); a click on one is reported here
-- (tf3api.takeBoardClick) and the window opens: a plan of the board's station from above - platforms, tracks,
-- buildings, stairs - with every board of the station as a marker at its place, platform tags to choose what
-- the selected board serves, a legend, an overview, and the selected board's settings.
--
-- The plan itself is a picture of this mod (plan_main.tga, plan_overview.tga) that the native layer paints
-- into (tf3api.stationPlan / stationPlanView); the markers and tags are ordinary widgets laid over it at the
-- places the same view gives. Without the native layer the picture says so and the platform buttons remain.
--
-- What the window needs to know comes from the boards script on the channel "tf3api_departure_boards.ui";
-- choices go back on "tf3api_departure_boards".

local MOD_ID = "tf3api_departure_boards"
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"

local CHANNEL = "tf3api_departure_boards"
local UI_CHANNEL = "tf3api_departure_boards.ui"
local IMG = MOD_ID .. "::/gui/tf3api_boards/"

-- The plan as shown (points of the interface) and the width of its picture (points of the texture): the view's
-- scale is metres to a point of the texture, as the native layer takes it.
local PLAN_W, PLAN_H, TEX_W = 960, 600, 1040
local MARKER, TAG_W, TAG_H = 28, 104, 26
-- the sizes a car's picture can have (points; the styles file has a class for each)
local CAR_STEP, CAR_MAX, CAR_HEIGHTS = 4, 240, { 6, 8, 10, 12, 16, 20 }

local function bridge()
	local ok, t = pcall(function() return tf3api end)
	if ok and type(t) == "table" then return t end
	return nil
end

local logged = 0
local function log(text)
	logged = logged + 1
	local b = bridge()
	if b ~= nil and logged <= 100 then pcall(b.log, "[" .. MOD_ID .. "] ui: " .. tostring(text)) end
end

-- what the boards script told us:
-- boards[id] = { stationName, kind, platforms = { n }, chosen = { [n] = true }, mode, layout, group, fx, fy }
-- plans[group] = { x0, y0, x1, y1, ux, uy, tags = { { n, x, y } }, scene = text }
local boards, plans = {}, {}
local views = {}          -- [group] = { cx, cy, mpp }: where each station's plan looks (kept while the game runs)
local planVersion = 0     -- counts what arrives, so that an open window draws itself again
local hidden = { departures = false, arrivals = false }   -- the filter: kinds of board not shown

local function send(text)
	local b = bridge()
	if b ~= nil and type(b.post) == "function" then pcall(b.post, CHANNEL, text) end
end

local function chosenText(chosen)
	local list = {}
	for n in pairs(chosen) do list[#list + 1] = n end
	table.sort(list)
	return table.concat(list, ",")
end

local BoardWindow
local openKey = nil
local openBoard

local function windowKey(id) return "tf3api_board_" .. tostring(id) end

-- ---- the view ---------------------------------------------------------------------------------------------

local function fitView(plan)
	local mpp = math.max((plan.x1 - plan.x0 + 30) / TEX_W, (plan.y1 - plan.y0 + 30) / (TEX_W * PLAN_H / PLAN_W), 0.02)
	return { cx = (plan.x0 + plan.x1) / 2, cy = (plan.y0 + plan.y1) / 2, mpp = mpp }
end

-- where a place of the plan (metres) is on the shown picture (points from its top left corner)
local function place(view, x, y)
	local k = (PLAN_W / TEX_W) / view.mpp
	return (x - view.cx) * k + PLAN_W / 2, PLAN_H / 2 - (y - view.cy) * k
end

-- a widget of w x h points with its middle at (px, py) on an area of areaW x areaH; nil when it would not fit
local function laid(px, py, w, h, areaW, areaH, item, key)
	local left, top = px - w / 2, py - h / 2
	if left < 0 or top < 0 or left + w > areaW or top + h > areaH then return nil end
	return builtin.FloatingLayoutChild {
		h = 2 * left / (areaW - w) - 1,
		v = 2 * top / (areaH - h) - 1,
		localKey = key,
		item = item,
	}
end

-- tells the native layer what to draw: the station, its boards, what the selected board serves, and the view
local lastScene, lastView = nil, nil
local toldMarker = false

-- ---- the trains on the plan -------------------------------------------------------------------------------
-- Every train of a line calling at the station, car by car, as the game draws a train in its own windows: the
-- car's side picture (its model's icon20), flipped when the car is turned round. Here each picture lies where
-- the car is, along the track it is on, and is flipped by the way the car faces on the plan (the pictures show
-- a car with its front to the left). Read again twice a second while a window is open.
local TRAINS_EVERY = 30   -- frames
local trains = {}         -- [group] = { at = frame, cars = { { file, x, y, angle, length, front } } }
local modelLength = {}    -- [modelId] = length along its x axis (metres), or false
local frameCount = 0
local openGroup = nil
local toldTrains = false

local function readTrains(group, plan)
	local cars = {}
	local okRead, why = pcall(function()
		local seenLine = {}
		local margin = 150
		for _i, lineStop in ipairs(api.engine.system.lineSystem.getLineStops(group)) do
			local lineEntity = lineStop[1]
			if not seenLine[lineEntity] then
				seenLine[lineEntity] = true
				for _j, vehicle in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(lineEntity)) do
					pcall(function()
						local tv = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
						local list = api.engine.getComponent(vehicle, api.type.ComponentType.MODEL_INSTANCE_LIST)
						if tv == nil or list == nil then return end
						-- the car's picture: by its model, from the train's own list of cars
						local picture = {}
						for _k, part in ipairs(tv.transportVehicleConfig.vehicles) do
							pcall(function()
								local desc = api.res.modelRep.get(part.part.modelId).metadata.description
								picture[part.part.modelId] = desc.icon20 or desc.iconSmall
							end)
						end
						for _m, instance in ipairs(list.fatInstances) do
							local file = picture[instance.modelId]
							if file ~= nil and file ~= "" then
								local c0, c3 = instance.transf:cols(0), instance.transf:cols(3)
								local dx, dy = c3.x - plan.cx, c3.y - plan.cy
								local a = dx * plan.ux + dy * plan.uy
								local c = -dx * plan.uy + dy * plan.ux
								if a > plan.x0 - margin and a < plan.x1 + margin and c > plan.y0 - margin and c < plan.y1 + margin then
									-- which way the car's front (+x of its model) points on the plan
									local fa = c0.x * plan.ux + c0.y * plan.uy
									local fc = -c0.x * plan.uy + c0.y * plan.ux
									local length = modelLength[instance.modelId]
									if length == nil then
										length = false
										pcall(function()
											local box = api.res.modelRep.get(instance.modelId).boundingInfo
											length = box.bbMax.x - box.bbMin.x
										end)
										modelLength[instance.modelId] = length
									end
									cars[#cars + 1] = { file = file, x = a, y = c, fa = fa, fc = fc, length = length or 20 }
								end
							end
						end
					end)
				end
			end
		end
	end)
	if not okRead and not toldTrains then
		toldTrains = true
		log("the trains at the station could not be read: " .. tostring(why))
	end
	return cars
end
local saidOwn = nil       -- what the native layer was last told about keeping board clicks from the game
-- (trains: see readTrains)
local function draw(plan, group, selected, chosen, view)
	local b = bridge()
	if b == nil or type(b.stationPlan) ~= "function" then return end
	local lines = { plan.scene }
	local ids = {}
	for id, info in pairs(boards) do
		if info.group == group and info.fx ~= nil then ids[#ids + 1] = id end
	end
	table.sort(ids)
	for _i, id in ipairs(ids) do
		local info = boards[id]
		lines[#lines + 1] = string.format("M %.1f %.1f %s %d", info.fx, info.fy, info.kind == "arrivals" and "a" or "d", id == selected and 1 or 0)
	end
	local served = chosenText(chosen)
	if served ~= "" then lines[#lines + 1] = "H " .. (served:gsub(",", " ")) end
	local scene = table.concat(lines, "\n")
	if scene ~= lastScene then
		lastScene = scene
		pcall(b.stationPlan, scene)
	end
	local viewText = string.format("%.2f %.2f %.4f", view.cx, view.cy, view.mpp)
	if viewText ~= lastView then
		lastView = viewText
		pcall(b.stationPlanView, viewText)
	end
end

-- ---- the window's parts -----------------------------------------------------------------------------------

local function picture(file, class)
	return builtin.ImageView { meta = { class = class }, path = IMG .. file, scaling = builtin.type.ImageViewScaling.Stretch }
end

local function legendRow(file, title, text)
	local words = { builtin.TextView { text = title } }
	if text ~= nil then words[2] = builtin.TextView { meta = { class = "tf3api-plan-small" }, text = text } end
	return builtin.BoxLayout {
		meta = { class = "tf3api-plan-legend-row" },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			picture(file, "tf3api-plan-legend-icon"),
			builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = words },
		},
	}
end

local BoardWindowContent = react.RegisterRecipe("Tf3apiBoardWindowContent", function(param)
	local horizontal, vertical = builtin.type.Orientation.Horizontal, builtin.type.Orientation.Vertical
	local info = boards[param.id] or {}
	local chosen = react.useState(info.chosen or {})
	local mode = react.useState(info.mode or "merged")
	-- the layout and the colour travel together as "layout/colour" (see boards_core.splitLayout)
	local layoutPart, colourPart = tostring(info.layout or "national"):match("^([^/]*)/?(.*)$")
	if colourPart == nil or colourPart == "" then colourPart = "amber" end
	local layoutState = react.useState(layoutPart)
	local colourState = react.useState(colourPart)
	local function sendChoices(chosenNow, modeNow, layoutNow, colourNow)
		send(string.format("set\t%d\t%s\t%s\t%s", param.id, chosenText(chosenNow), tostring(modeNow), tostring(layoutNow) .. "/" .. tostring(colourNow)))
	end
	-- drawn again when the view moves, the filter changes, or the boards script sends something new
	local redraw = react.useState(0)
	local seen = react.useState(planVersion)
	react.onStep(function()
		if seen:hasExpired() then return end
		if seen:old() ~= planVersion then seen:set(planVersion) end
	end)
	local function again() redraw:set(redraw:old() + 1) end

	local function row(label, child)
		return builtin.BoxLayout {
			meta = { class = "tf3api-board-row" },
			orientation = horizontal,
			children = { builtin.TextView { meta = { class = "tf3api-board-label" }, text = label }, child },
		}
	end
	local function toggle(n)
		local now = {}
		for k, v in pairs(chosen:old()) do now[k] = v end
		if now[n] then now[n] = nil else now[n] = true end
		chosen:set(now)
		sendChoices(now, mode:old(), layoutState:old(), colourState:old())
	end

	local group = info.group
	local plan = group ~= nil and plans[group] or nil
	local left

	if plan ~= nil and not param.noView then
		local view = views[group]
		if view == nil then
			view = fitView(plan)
			views[group] = view
		end
		draw(plan, group, param.id, chosen:old(), view)
		local function move(dx, dy, zoom)
			local v = views[group]
			local spanX, spanY = v.mpp * TEX_W, v.mpp * TEX_W * PLAN_H / PLAN_W
			views[group] = { cx = v.cx + dx * spanX, cy = v.cy + dy * spanY, mpp = math.max(0.02, math.min(v.mpp * (zoom or 1), 5)) }
			again()
		end

		local children = { builtin.FloatingLayoutChild { h = -1, v = -1, localKey = "picture", item = picture("plan_main.tga", "tf3api-plan-picture") } }
		openGroup = group
		-- the trains, car by car, along the track; a picture's front is its left end, so a car facing right
		-- is flipped, and the picture is turned to lie along the car
		local k = (PLAN_W / TEX_W) / view.mpp
		for i, car in ipairs(trains[group] ~= nil and trains[group].cars or {}) do
			local w = math.floor(car.length * k / CAR_STEP + 0.5) * CAR_STEP
			if w >= CAR_STEP and w <= CAR_MAX then
				local h = CAR_HEIGHTS[1]
				for _j, ch in ipairs(CAR_HEIGHTS) do if ch <= w / 6 then h = ch end end
				local px, py = place(view, car.x, car.y)
				local facesRight = car.fa >= 0
				-- the angle of the car on the screen, counted clockwise (screen y grows downwards)
				local along = math.deg(math.atan2(-car.fc, car.fa))
				if not facesRight then along = along + 180 end
				if along > 180 then along = along - 360 end
				local item = laid(px, py, w, h, PLAN_W, PLAN_H, builtin.ImageView {
					meta = { class = string.format("tf3api-car-%dx%d", w, h) },
					path = car.file,
					scaling = builtin.type.ImageViewScaling.Stretch,
					flippedHorizontally = facesRight,
					rotation = along,
				}, "car" .. i)
				if item ~= nil then children[#children + 1] = item end
			end
		end
		-- the platforms: a tag at the left end of each platform's track; lit when the selected board serves it
		local any = next(chosen:old()) ~= nil
		for _i, tag in ipairs(plan.tags) do
			local px, py = place(view, tag.x, tag.y)
			px = math.max(px - TAG_W / 2 - 6, TAG_W / 2 + 4)
			local on = not any or chosen:old()[tag.n] == true
			local item = laid(px, py, TAG_W, TAG_H, PLAN_W, PLAN_H, builtin.Button {
				meta = { class = (on and "primary" or "secondary") .. ", tf3api-plan-tag", tooltip = _("Click: whether the selected board serves this platform") },
				content = builtin.TextView { text = string.format(_("Platform %d"), tag.n) },
				onClick = function() toggle(tag.n) end,
			}, "tag" .. tag.n)
			if item ~= nil then children[#children + 1] = item end
		end
		-- the boards of this station, each at its place; ones that would lie on top of each other stand side by side
		local ids = {}
		for id, other in pairs(boards) do
			if other.group == group and other.fx ~= nil and not hidden[other.kind == "arrivals" and "arrivals" or "departures"] then ids[#ids + 1] = id end
		end
		table.sort(ids)
		local taken = {}
		for _i, id in ipairs(ids) do
			local other = boards[id]
			local px, py = place(view, other.fx, other.fy)
			for _try = 1, 12 do
				local moved = false
				for _j, t in ipairs(taken) do
					if math.abs(t[1] - px) < MARKER and math.abs(t[2] - py) < MARKER then
						px = t[1] + MARKER + 2
						moved = true
					end
				end
				if not moved then break end
			end
			taken[#taken + 1] = { px, py }
			local file = (other.kind == "arrivals" and "icon_board_a" or "icon_board_d") .. (id == param.id and "_sel" or "") .. ".tga"
			local item = laid(px, py, MARKER, MARKER, PLAN_W, PLAN_H, builtin.Button {
				meta = { class = "tf3api-plan-marker", tooltip = string.format(_("Board %d - %s"), id, other.kind == "arrivals" and _("arrivals") or _("departures")) },
				content = picture(file, "tf3api-plan-marker-icon"),
				onClick = function() if id ~= param.id then openBoard(id) end end,
			}, "board" .. id)
			if item ~= nil then children[#children + 1] = item end
			if id == param.id and not toldMarker then
				toldMarker = true
				log(string.format("board %d on the plan: %.0f, %.0f of %d x %d (%s); view %.1f, %.1f at %.3f m a point; %d tag(s)", id, px, py, PLAN_W, PLAN_H,
					item ~= nil and "laid" or "outside", view.cx, view.cy, view.mpp, #plan.tags))
			end
		end
		-- north, by the direction the station's tracks run in
		local north = math.deg(math.atan2(plan.uy or 0, plan.ux or 1))
		local arrow = laid(PLAN_W - 30, 30, 36, 36, PLAN_W, PLAN_H, builtin.ImageView {
			meta = { class = "tf3api-plan-north", tooltip = _("North") }, path = IMG .. "arrow_north.tga", rotation = north,
			scaling = builtin.type.ImageViewScaling.Stretch,
		}, "north")
		if arrow ~= nil then children[#children + 1] = arrow end
		local function control(text, tip, fn)
			return builtin.Button { meta = { class = "secondary, tf3api-plan-control", tooltip = tip }, content = builtin.TextView { text = text }, onClick = fn }
		end
		left = builtin.BoxLayout {
			orientation = vertical,
			meta = { class = "tf3api-plan-left" },
			children = {
				builtin.BoxLayout { meta = { class = "tf3api-plan-controls" }, orientation = horizontal, children = {
					control("+", _("Closer"), function() move(0, 0, 1 / 1.5) end),
					control("-", _("Further away"), function() move(0, 0, 1.5) end),
					control(_("Fit"), _("The whole station"), function() views[group] = fitView(plan); again() end),
					control("<", _("Left"), function() move(-0.25, 0) end),
					control(">", _("Right"), function() move(0.25, 0) end),
					control("^", _("Up"), function() move(0, 0.25) end),
					control("v", _("Down"), function() move(0, -0.25) end),
					builtin.Button {
						meta = { class = (hidden.departures and "secondary" or "primary") .. ", tf3api-plan-control-wide", tooltip = _("Show or hide the departure boards") },
						content = builtin.TextView { text = _("Departure boards") },
						onClick = function() hidden.departures = not hidden.departures; again() end,
					},
					builtin.Button {
						meta = { class = (hidden.arrivals and "secondary" or "primary") .. ", tf3api-plan-control-wide", tooltip = _("Show or hide the arrivals boards") },
						content = builtin.TextView { text = _("Arrivals boards") },
						onClick = function() hidden.arrivals = not hidden.arrivals; again() end,
					},
				} },
				builtin.Component { meta = { class = "tf3api-plan-area" }, layout = builtin.FloatingLayout { children = children } },
			},
		}
	elseif not param.noView then
		-- no plan yet: ask for it (it comes with the next look round the station) and offer the platforms as buttons
		if group ~= nil then send("plans") end
		local buttons = {}
		for _i, n in ipairs(info.platforms or {}) do
			local on = chosen:old()[n] == true
			buttons[#buttons + 1] = builtin.Button {
				meta = { class = on and "primary" or "secondary" },
				content = builtin.TextView { text = (on and "[x] " or "[ ] ") .. string.format(_("Platform %d"), n) },
				onClick = function() toggle(n) end,
			}
		end
		left = builtin.BoxLayout { orientation = vertical, meta = { class = "tf3api-plan-left" }, children = {
			builtin.TextView { text = group ~= nil and _("Reading the station's plan ...") or _("This board has not joined a station: place it within 100 m of one.") },
			builtin.BoxLayout { meta = { class = "tf3api-board-platforms" }, orientation = horizontal, children = buttons },
		} }
	end

	-- the side: what the picture means, the whole station, and the selected board
	local served = chosenText(chosen:old())
	local side = {
		builtin.TextView { meta = { class = "tf3api-plan-heading" }, text = _("Legend") },
		legendRow("icon_board_d.tga", _("Departure board"), _("Shows the next departures")),
		legendRow("icon_board_a.tga", _("Arrivals board"), _("Shows the next arrivals")),
		legendRow("icon_entrance.tga", _("Platform entrance"), _("Stairs or an underpass")),
		legendRow("swatch_platform.tga", _("Platform area")),
		legendRow("swatch_track.tga", _("Track"), _("Amber: served by the selected board")),
		legendRow("swatch_building.tga", _("Station building")),
		builtin.TextView { meta = { class = "tf3api-plan-heading" }, text = _("Overview") },
		picture("plan_overview.tga", "tf3api-plan-overview"),
		builtin.TextView { meta = { class = "tf3api-plan-heading" }, text = string.format(_("Board %d"), param.id) },
		row(_("Station"), builtin.TextView { text = info.stationName or _("none in reach") }),
		row(_("Shows"), builtin.TextView { text = info.kind == "arrivals" and _("Arrivals") or _("Departures") }),
		row(_("Serves"), builtin.TextView { text = served ~= "" and string.format(_("Platform %s"), (served:gsub(",", ", "))) or _("Every platform") }),
		row(_("Layout"), builtin.ComboBox {
			value = layoutState:old(),
			items = {
				builtin.ComboBoxItem { value = "national", content = builtin.TextView { text = _("National Rail") } },
				builtin.ComboBoxItem { value = "platform", content = builtin.TextView { text = _("Platform, with calling points") } },
				builtin.ComboBoxItem { value = "metro", content = builtin.TextView { text = _("Metro") } },
				builtin.ComboBoxItem { value = "bus", content = builtin.TextView { text = _("Bus stop") } },
				builtin.ComboBoxItem { value = "station", content = builtin.TextView { text = _("Station board with heading") } },
			},
			onValueChange = function(value)
				layoutState:set(value)
				sendChoices(chosen:old(), mode:old(), value, colourState:old())
			end,
		}),
		row(_("Dot colour"), builtin.ComboBox {
			value = colourState:old(),
			items = {
				builtin.ComboBoxItem { value = "amber", content = builtin.TextView { text = _("Amber") } },
				builtin.ComboBoxItem { value = "white", content = builtin.TextView { text = _("White") } },
				builtin.ComboBoxItem { value = "yellow", content = builtin.TextView { text = _("Yellow") } },
				builtin.ComboBoxItem { value = "green", content = builtin.TextView { text = _("Green") } },
				builtin.ComboBoxItem { value = "red", content = builtin.TextView { text = _("Red") } },
				builtin.ComboBoxItem { value = "blue", content = builtin.TextView { text = _("Blue") } },
			},
			onValueChange = function(value)
				colourState:set(value)
				sendChoices(chosen:old(), mode:old(), layoutState:old(), value)
			end,
		}),
		row(_("Several platforms"), builtin.ComboBox {
			value = mode:old(),
			items = {
				builtin.ComboBoxItem { value = "merged", content = builtin.TextView { text = _("One list, sorted by time") } },
				builtin.ComboBoxItem { value = "cycle", content = builtin.TextView { text = _("One platform at a time, in turn") } },
			},
			onValueChange = function(value)
				mode:set(value)
				sendChoices(chosen:old(), value, layoutState:old(), colourState:old())
			end,
		}),
		builtin.Button {
			meta = { class = "secondary" },
			content = builtin.TextView { text = _("Forget this board (it was removed)") },
			onClick = function()
				send(string.format("forget\t%d", param.id))
				boards[param.id] = nil
				pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(BoardWindow, windowKey(param.id)) end)
				openKey = nil
			end,
		},
	}
	local right = builtin.BoxLayout { meta = { class = "tf3api-plan-side" }, orientation = vertical, children = side }
	return builtin.BoxLayout {
		meta = { class = "tf3api-board-content" },
		orientation = horizontal,
		children = left ~= nil and { left, right } or { right },
	}
end)

BoardWindow = react.RegisterWrapperRecipe("Tf3apiBoardWindow", builtin.Window, function(param)
	local info = boards[param.id] or {}
	return builtin.Window {
		meta = { class = "tf3api-board-window" },
		id = windowKey(param.id),
		title = info.stationName ~= nil and string.format(_("%s - station diagram"), info.stationName) or _("Departure board"),
		closable = true,
		movable = true,
		onClose = function()
			pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(BoardWindow, windowKey(param.id)) end)
			if openKey == windowKey(param.id) then openKey = nil end
		end,
		content = BoardWindowContent(param),
	}
end)

function openBoard(id)
	local key = windowKey(id)
	if openKey ~= nil and openKey ~= key then
		local old = openKey
		pcall(function() game_react_globals.getDefaultWindowApi().removeWindow(BoardWindow, old) end)
	end
	local ok, err = pcall(function() game_react_globals.getDefaultWindowApi().addWindow(BoardWindow, key, { id = id }) end)
	if not ok then
		log("could not open the board window: " .. tostring(err))
		return
	end
	openKey = key
	log("opened the window of board " .. tostring(id))
end

-- only while the player is looking round, not with a tool in hand
local function clicksAllowed()
	local ok, tool = pcall(function() return (game_react_globals.getDefaultToolStackApi().getActiveTool()) end)
	if not ok then return true end
	local name = tool ~= nil and tostring(tool.name) or nil
	return name == nil or name == "EntityDetailsTool"
end

local function poll()
	local b = bridge()
	if b == nil or type(b.takeBoardClick) ~= "function" then return end
	if type(b.take) == "function" then
		for _i = 1, 64 do
			local okTake, message = pcall(b.take, UI_CHANNEL)
			if not okTake or type(message) ~= "string" then break end
			-- a station's plan: "plan\tgroup\tx0 y0 x1 y1 ux uy|n:x:y;...\tscene"
			local group, infoText, scene = message:match("^plan\t(%d+)\t([^\t]*)\t(.*)$")
			if group ~= nil then
				local x0, y0, x1, y1, ux, uy, cx, cy, tagText = infoText:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)|(.*)$")
				if tonumber(x0) ~= nil then
					local plan = { x0 = tonumber(x0), y0 = tonumber(y0), x1 = tonumber(x1), y1 = tonumber(y1), ux = tonumber(ux), uy = tonumber(uy),
						cx = tonumber(cx), cy = tonumber(cy), tags = {}, scene = scene }
					for n, x, y in (tagText or ""):gmatch("(%d+):(%-?[%d.]+):(%-?[%d.]+)") do
						plan.tags[#plan.tags + 1] = { n = tonumber(n), x = tonumber(x), y = tonumber(y) }
					end
					plans[tonumber(group)] = plan
					planVersion = planVersion + 1
				end
			end
			-- a board: "board\tid\tstationName\tkind\tplatforms\tchosen\tmode\tlayout\tentity\t\tgroup fx fy"
			local id, name, kind, platforms, chosen, mode, layout, _entity, _plan, where =
				message:match("^board\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)$")
			id = tonumber(id)
			if id ~= nil then
				local entry = { layout = layout ~= "" and layout or "national", stationName = name ~= "" and name or nil, kind = kind,
					platforms = {}, chosen = {}, mode = mode ~= "" and mode or "merged" }
				for n in platforms:gmatch("%d+") do entry.platforms[#entry.platforms + 1] = tonumber(n) end
				for n in chosen:gmatch("%d+") do entry.chosen[tonumber(n)] = true end
				local g, fx, fy = (where or ""):match("^(%d+) (%-?[%d.]+) (%-?[%d.]+)$")
				entry.group, entry.fx, entry.fy = tonumber(g), tonumber(fx), tonumber(fy)
				local old = boards[id]
				if old == nil or old.fx ~= entry.fx or old.fy ~= entry.fy or old.group ~= entry.group then planVersion = planVersion + 1 end
				boards[id] = entry
			end
		end
	end
	-- A click on a board is ours alone while the player is just looking round: the game would give it to the
	-- station or building behind the board. Not with a tool in hand, nor with our window open over the view.
	frameCount = frameCount + 1
	if openKey ~= nil and openGroup ~= nil and plans[openGroup] ~= nil then
		local entry = trains[openGroup]
		if entry == nil or frameCount - entry.at >= TRAINS_EVERY then
			trains[openGroup] = { at = frameCount, cars = readTrains(openGroup, plans[openGroup]) }
			planVersion = planVersion + 1
		end
	end
	local allowed = clicksAllowed()
	local own = (allowed and openKey == nil) and "1" or "0"
	if own ~= saidOwn and type(b.boardClicks) == "function" then
		saidOwn = own
		pcall(b.boardClicks, own)
	end
	local ok, id = pcall(b.takeBoardClick)
	if ok and type(id) == "string" and allowed then
		local board = tonumber(id)
		-- only a board the boards script has told us about (its id may not be an entity of the game)
		if board ~= nil and boards[board] ~= nil then openBoard(board) end
	end
end

local BoardsHost = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "Tf3apiBoardsHost", function()
	react.onStep(function()
		local ok, err = pcall(poll)
		if not ok and logged < 20 then log("polling failed: " .. tostring(err)) end
	end)
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {} }
end)

-- The card in the game's own window of a board that stayed a plain construction: the settings without the plan.
-- (A game file is named from the root of the game, "::/...": a bare "/..." would be looked for in this mod.
-- Should the game's file not be there, the card is simply missing - the rest of this script still works.)
local BoardCard
do
	local ok, err = pcall(function()
		local eow = ug_require "::/gui/entity_window/empty_construction/empty_construction_eow.script.tl"
		BoardCard = react.RegisterPluginRecipe(eow.EmptyConstructionEowExtensionPoint, "Tf3apiBoardCard", function(params)
			local id = params ~= nil and params.entityId or nil
			if id == nil or boards[id] == nil then
				return builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = {} }
			end
			return BoardWindowContent({ id = id, noView = true })
		end)
	end)
	if not ok then log("the card for the game's construction window could not be set up: " .. tostring(err)) end
end

local M = { BoardsHost = BoardsHost, BoardWindow = BoardWindow, BoardCard = BoardCard }
function data() return M end
return M
