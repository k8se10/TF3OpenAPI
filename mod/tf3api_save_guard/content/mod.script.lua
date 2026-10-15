-- TF3OpenAPI save guard: the junction pieces.
--
-- Streets a construction lays itself (a roundabout, the ramps of an interchange, the entrance street of a depot) are one-way
-- pieces drawn for one side of the road. They are part of a construction's result, so they cannot be turned when the street
-- types are (guard.script.lua): when such a result is made, and the game keeps to another side than the data was written for
-- (the native layer knows both, see driving_side.h), each one-way piece is turned round and what names its nodes follows
-- (sides.lua, edgeLists). The lanes inside buildings are turned by the native layer itself.
--
-- A fault here must never cost the game a construction: every step is guarded and a result that cannot be read is
-- returned as it was.

local MOD = "tf3api_save_guard"
local sides = require(MOD .. "::/save_guard/sides.lua")

local function log(text)
	pcall(function() tf3api.log("[" .. MOD .. "] " .. text) end)
end

-- the side this game keeps to and the side its data was written for, as the native layer was told
local function mustTurn()
	local ok, _, desired, authored = pcall(function() return tf3api.drivingSide() end)
	if not ok then return false end
	return (desired == "R" or desired == "L") and (authored == "R" or authored == "L") and desired ~= authored
end

-- Is this street type one-way? (Every road lane runs the same way.) The name is the one a construction gives its edges.
local function isOneWay(name)
	if type(name) ~= "string" then return false end
	local ok, answer = pcall(function()
		local rep = api.res.streetTemplateRep
		local id
		for _, form in ipairs({ name, name:gsub("^/", ""), "::" .. (name:sub(1, 1) == "/" and name or "/" .. name) }) do
			local found = rep.find(form)
			if found ~= nil and found >= 0 then id = found break end
		end
		if id == nil then return false end
		local template = rep.getAsTable(id)
		if type(template) ~= "table" or template.roadType ~= "STREET" then return false end
		return sides.templateSide(template) == nil and sides.hasRoadLanes(template)
	end)
	return ok and answer == true
end

local seen = setmetatable({}, { __mode = "k" })
local told = 0

local function adapt(result)
	if type(result) ~= "table" or seen[result] or type(result.edgeLists) ~= "table" then return end
	seen[result] = true
	if not mustTurn() then return end
	local ok, turned = pcall(sides.edgeLists, result.edgeLists, isOneWay)
	if ok and turned and turned > 0 and told < 5 then
		told = told + 1
		log(turned .. " one-way piece(s) of a construction turned to the side the game keeps to")
	elseif not ok then
		log("a construction's streets could not be turned: " .. tostring(turned))
	end
end

local JUNCTIONS = {
	"updateFnRoundabout", "updateFnCloverleafInterchange", "updateFnDiamondInterchange",
	"updateFnDivergingDiamondInterchange", "updateFnTInterchange", "updateFnTrumpetInterchange",
}

-- scripts whose update function lays streets of its own
local function laysStreets(key)
	return key:find("/depots/road/", 1, true) ~= nil or key:find("/stations/street/", 1, true) ~= nil
		or key:find("/industries/", 1, true) ~= nil
end

function data()
	return {
		runFn = function()
			addModifier("loadScript", function(fileName, script)
				local key = tostring(fileName)
				if type(script) ~= "table" then return script end
				local ok, err = pcall(function()
					if key:find("street_construction/street_constructions.script", 1, true) then
						for _, name in ipairs(JUNCTIONS) do
							local original = script[name]
							if type(original) == "function" then
								script[name] = function(...)
									local result = original(...)
									adapt(result)
									return result
								end
							end
						end
					elseif key:find("scripts/construction/construction.script", 1, true) and type(script.constructWithModules) == "function" then
						local original = script.constructWithModules
						script.constructWithModules = function(...)
							local result = original(...)
							adapt(result)
							return result
						end
					elseif laysStreets(key) and key:find(".script", 1, true) and type(script.updateFn) == "function" then
						local original = script.updateFn
						script.updateFn = function(...)
							local result = original(...)
							adapt(result)
							return result
						end
					end
				end)
				if not ok then log("a script could not be wrapped (" .. key .. "): " .. tostring(err)) end
				return script
			end)
		end,
	}
end
