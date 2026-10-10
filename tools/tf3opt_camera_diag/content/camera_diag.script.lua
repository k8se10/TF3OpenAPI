-- TF3 Optimizations: camera diagnostic (development only, never published).
--
-- Purpose: confirm the cockpit / first-person camera clamp, and learn the camera API's conventions before
-- building our own vehicle-attached camera. While the camera follows a vehicle (follow view or cockpit) it
-- records the camera eye/center, the raw camera data (Vec5f: center.x, center.y, distance, angle, pitch),
-- the height above terrain, the near/far planes, and the followed vehicle's own position and direction.
--
-- Output: a Lua table written with app.saveUserdata to <userdata>/tf3opt_camera_diag/samples.lua
-- (the game's stdout log isn't reachable on this install). The folder path itself is stored in the file.
-- Read-only: it never changes the camera or any game state.

local DIR, FILE = "tf3opt_camera_diag", "samples.lua"
local SAMPLE_EVERY_FRAMES = 15   -- ~4 samples a second at 60 fps while following
local MIN_Z_CHANGE = 0.5         -- take a sample when the eye moved at least this much vertically (m)
local HEARTBEAT_FRAMES = 120     -- otherwise one sample every ~2 s while following
local SAVE_EVERY_FRAMES = 120    -- write the file at most every ~2 s
local MAX_SAMPLES = 400          -- keep the newest samples only

local frame = 0
local lastZ = nil
local lastSampleFrame = -1000000
local lastSaveFrame = -1000000
local dirty = false
local wasFollowing = false
local out = { info = {}, events = {}, samples = {} }

local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, res = pcall(fn, ...)
	if ok then return res end
	return nil
end

local function v3(v)
	if v == nil then return nil end
	local ok, t = pcall(function() return { v.x, v.y, v.z } end)
	return ok and t or tostring(v)
end

local function list(v, n)
	if v == nil then return nil end
	local ok, t = pcall(function()
		local r = {}
		for i = 1, n do r[i] = v[i] end
		return r
	end)
	return ok and t or tostring(v)
end

local function save(force)
	if not dirty and not force then return end
	if not force and frame - lastSaveFrame < SAVE_EVERY_FRAMES then return end
	lastSaveFrame = frame
	dirty = false
	local ok, err = pcall(app.saveUserdata, DIR, FILE, out)
	if not ok then out.info.saveError = tostring(err) end
end

local function init()
	out.info.userDataFolder = call(app and app.getUserDataFolder)
	out.info.terrainHeightRange = list(call(api.engine.mapgen and api.engine.mapgen.getMinMaxValidTerrainHeight), 2)
	out.info.started = true
	save(true)
end

local function guiUpdate()
	frame = frame + 1
	if frame == 1 then init() end
	if frame % SAMPLE_EVERY_FRAMES ~= 0 then save(false) return end

	local cam = api.gui and api.gui.camera
	if cam == nil then return end

	local follow = call(cam.getFollowEntity)
	local entity = follow and call(function() return follow[1] end)
	local following = entity ~= nil and entity ~= -1

	if following ~= wasFollowing then
		wasFollowing = following
		lastZ = nil
		table.insert(out.events, { frame = frame, following = following, entity = entity })
		dirty = true
	end
	if not following then save(false) return end

	local eye = call(cam.getEye)
	local z = eye and call(function() return eye.z end)
	local moved = (z ~= nil) and (lastZ == nil or math.abs(z - lastZ) >= MIN_Z_CHANGE)
	if moved or frame - lastSampleFrame >= HEARTBEAT_FRAMES then
		lastZ = z
		lastSampleFrame = frame
		local veh = api.engine.util and api.engine.util.vehicle
		table.insert(out.samples, {
			frame = frame,
			entity = entity,
			eye = v3(eye),
			center = v3(call(cam.getCenter)),
			cameraData = list(call(cam.getCameraData), 5),
			aboveTerrain = call(cam.getHeightAboveTerrain),
			nearFar = list(call(cam.getNearFar), 2),
			vehiclePos = v3(call(veh and veh.getPosition, entity)),
			vehicleDir = v3(call(veh and veh.getDirection, entity)),
		})
		while #out.samples > MAX_SAMPLES do table.remove(out.samples, 1) end
		dirty = true
	end
	save(false)
end

local M = { guiUpdate = guiUpdate }
function data() return M end
return M
