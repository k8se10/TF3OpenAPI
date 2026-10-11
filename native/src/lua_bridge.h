#pragma once

// The bridge between this DLL and the game's scripts.
//
// The game embeds Lua 5.2.2 and creates many Lua states (one per worker thread for game scripts, plus the
// UI states). Each state opens the Lua base library once, right after it is created; this module hooks
// that function and, in the same call, adds one global table to the new state:
//
//     tf3api.version            number, the API version (currently 5; setRoadLabels came with 2, takeRoadClick with 3, post and take with 4, the click position with 5, the info text with 6, the worker with 7)
//     tf3api.has(name)          true if the named function exists in this build of the DLL
//     tf3api.log(text)          writes a line to tf3api.log (rate-limited)
//     tf3api.writeFile(name, text)
//                               writes text to <game folder>\tf3api_out\<name>; returns true, or
//                               false plus a reason. Plain file names only (letters, digits, . _ -),
//                               data and document extensions only, never a path.
//     tf3api.setRoadLabels(text)
//                               hands the road names to draw in the world to the native side (format in
//                               road_labels.h); returns the number of roads taken, or false plus a reason
//     tf3api.takeRoadClick()    the road whose label the player clicked since the last call: id, name,
//                               number, class, length in metres, segment count, flags, the world
//                               x, y of the spot on the road, and the road's info text; or false
//     tf3api.post(channel, text)
//     tf3api.take(channel)      named message queues shared by all script states: post leaves a text, take
//                               returns the oldest one or false. For a mod's own scripts to talk to each
//                               other across Lua states.
//     tf3api.workerAvailable()  whether the DLL can run a Lua state of its own on a worker thread
//     tf3api.workerStart(files) loads .lua files (paths under mods, one a line) into that state
//     tf3api.workerRun(input)   queues tf3_job(input) there; returns the job's number, or false
//     tf3api.workerTake()       job number, succeeded, text - of the next finished job; or false
//                               (see lua_worker.h)
//
// Scripts must treat the table as optional: `if tf3api and tf3api.has("writeFile") then ...`.
// Functions never raise Lua errors; they report failure through their return values.
//
// Nothing here changes game state. RE trail: re_notes/scripting/lua_vm.md.
//
// tf3api.ini [Bridge]:
//   Enabled=0    1 = register the table (default off until verified in-game)

namespace tf3api::lua_bridge {

// Requires MinHook to be initialised.
void Install();
void Uninstall();

} // namespace tf3api::lua_bridge
