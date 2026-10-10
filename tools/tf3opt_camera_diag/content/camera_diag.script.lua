-- TF3 Optimizations: camera diagnostic (development only, never published).
--
-- Purpose: find out whether the cockpit / first-person camera is clamped to a fixed minimum height.
-- While the camera follows a vehicle (follow view or cockpit), it logs the camera eye and look-at
-- positions, the height above terrain and the near/far planes. If the eye's z stops going down at a
-- fixed value while the vehicle keeps descending, that value is the clamp.
--
-- Output: lines starting with "[tf3opt_camera_diag]" in the game's crash_dump/stdout.txt.
-- Read-only: it never changes the camera or any game state.

local TAG = "[tf3opt_camera_diag] "
local LOG_EVERY_FRAMES = 15      -- check about 4 times a second at 60 fps
local MIN_Z_CHANGE = 0.5         -- log when eye z moved at least this much (m)
local HEARTBEAT_FRAMES = 120     -- also log every ~2 s while following, even if nothing moved
local MAX_LINES = 3000           -- hard cap so a long session can't flood the log

local frame = 0
local lines = 0
local lastZ = nil
local lastLogFrame = -1000000
local wasFollowing = false
local staticLogged = false

local function log(msg)
	if lines >= MAX_LINES then return end
	lines = lines + 1
	local text = TAG .. msg
	if not pcall(debugPrint, text) then print(text) end
end

local function vec(v)
	if v == nil then return "nil" end
	local ok, s = pcall(function() return string.format("%.2f/%.2f/%.2f", v.x, v.y, v.z) end)
	return ok and s or tostring(v)
end

local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, res = pcall(fn, ...)
	if ok then return res end
	return nil
end

local function logStatic()
	staticLogged = true
	local range = call(api.engine.mapgen and api.engine.mapgen.getMinMaxValidTerrainHeight)
	local rangeText = "nil"
	if type(range) == "table" or type(range) == "userdata" then
		local ok, s = pcall(function() return string.format("%.2f .. %.2f", range[1], range[2]) end)
		rangeText = ok and s or tostring(range)
	end
	log("loaded; valid terrain height range = " .. rangeText)
end

local function guiUpdate()
	frame = frame + 1
	if not staticLogged then logStatic() end
	if frame % LOG_EVERY_FRAMES ~= 0 then return end

	local cam = api.gui and api.gui.camera
	if cam == nil then return end

	local follow = call(cam.getFollowEntity)
	local entity = nil
	if type(follow) == "table" or type(follow) == "userdata" then
		entity = call(function() return follow[1] end)
	end
	local following = entity ~= nil and entity ~= -1

	if following ~= wasFollowing then
		log(following and ("follow start, entity " .. tostring(entity)) or "follow end")
		wasFollowing = following
		lastZ = nil
	end
	if not following then return end

	local eye = call(cam.getEye)
	local center = call(cam.getCenter)
	local z = eye and call(function() return eye.z end)
	local moved = (z ~= nil) and (lastZ == nil or math.abs(z - lastZ) >= MIN_Z_CHANGE)
	if not moved and frame - lastLogFrame < HEARTBEAT_FRAMES then return end

	lastZ = z
	lastLogFrame = frame
	log(string.format("entity %s | eye %s | center %s | eye-center dz %s | aboveTerrain %s | nearFar %s",
		tostring(entity), vec(eye), vec(center),
		(eye and center) and string.format("%.2f", eye.z - center.z) or "?",
		tostring(call(cam.getHeightAboveTerrain)),
		vec(call(function() local nf = cam.getNearFar(); return { x = nf.x, y = nf.y, z = 0 } end))))
end

local M = { guiUpdate = guiUpdate }
function data() return M end
return M
