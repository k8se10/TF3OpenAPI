-- TF3 Optimizations: camera diagnostic (development only, never published).
--
-- Purpose: confirm the cockpit / first-person camera clamp, and learn the camera API's conventions before
-- building our own vehicle-attached camera. Samples the camera continuously (not only while following):
-- eye/center, raw camera data (Vec5f: center.x, center.y, distance, angle, pitch), height above terrain,
-- near/far planes (the cockpit view uses near = 0.5 m, which identifies it), the raw follow-entity value,
-- and - when a followed vehicle can be identified - its position and direction.
--
-- Output: <userdata>/tf3opt_camera_diag/samples.lua via app.saveUserdata (the game appends ".lua"), plus
-- "[tf3opt_camera_diag]" lines in crash_dump/stdout.txt for errors.
-- Read-only: it never changes the camera or any game state.

local TAG = "[tf3opt_camera_diag] "
local DIR, FILE = "tf3opt_camera_diag", "samples"
local SAMPLE_EVERY_FRAMES = 30   -- ~2 samples a second at 60 fps
local SAVE_EVERY_FRAMES = 120    -- write the file every ~2 s
local MAX_SAMPLES = 600          -- keep the newest samples only (~5 min)
local MAX_ERRORS = 20

local frame = 0
local errors = 0
local out = { info = {}, samples = {} }

local function logError(where, err)
	if errors >= MAX_ERRORS then return end
	errors = errors + 1
	local text = TAG .. where .. ": " .. tostring(err)
	if not pcall(debugPrint, text) then print(text) end
end

local function call(where, fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, res = pcall(fn, ...)
	if ok then return res end
	logError(where, res)
	return nil
end

-- best-effort conversion of engine values (Vec*, native vectors, tables) into plain tables
local function plain(v, depth)
	depth = depth or 0
	local t = type(v)
	if t ~= "table" and t ~= "userdata" then return v end
	if depth > 3 then return tostring(v) end
	local okXYZ, xyz = pcall(function() return { x = v.x, y = v.y, z = v.z } end)
	if okXYZ and type(xyz.x) == "number" then return xyz end
	local res = {}
	local okIdx = pcall(function()
		for i = 1, 8 do
			local x = v[i]
			if x == nil then break end
			res[i] = plain(x, depth + 1)
		end
	end)
	if okIdx and #res > 0 then return res end
	return tostring(v)
end

local function followedEntity(raw)
	local ok, e = pcall(function() return raw[1] end)
	if ok and type(e) == "number" and e >= 0 then return e end
	if type(raw) == "number" and raw >= 0 then return raw end
	return nil
end

local function guiUpdate()
	frame = frame + 1
	if frame == 1 then
		out.info.started = true
		out.info.terrainHeightRange = plain(call("mapgen", api.engine.mapgen and api.engine.mapgen.getMinMaxValidTerrainHeight))
	end
	if frame % SAMPLE_EVERY_FRAMES == 0 then
		local cam = api.gui and api.gui.camera
		if cam ~= nil then
			local followRaw = call("getFollowEntity", cam.getFollowEntity)
			local entity = followedEntity(followRaw)
			local veh = api.engine.util and api.engine.util.vehicle
			local s = {
				frame = frame,
				eye = plain(call("getEye", cam.getEye)),
				center = plain(call("getCenter", cam.getCenter)),
				cameraData = plain(call("getCameraData", cam.getCameraData)),
				aboveTerrain = call("getHeightAboveTerrain", cam.getHeightAboveTerrain),
				nearFar = plain(call("getNearFar", cam.getNearFar)),
				followRaw = plain(followRaw),
			}
			if entity ~= nil and veh ~= nil then
				s.vehiclePos = plain(call("vehicle.getPosition", veh.getPosition, entity))
				s.vehicleDir = plain(call("vehicle.getDirection", veh.getDirection, entity))
			end
			table.insert(out.samples, s)
			while #out.samples > MAX_SAMPLES do table.remove(out.samples, 1) end
		end
	end
	if frame % SAVE_EVERY_FRAMES == 0 then
		call("saveUserdata", app and app.saveUserdata, DIR, FILE, out)
	end
end

local M = { guiUpdate = guiUpdate }
function data() return M end
return M
