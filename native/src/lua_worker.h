#pragma once

#include <cstddef>
#include <string>

// A Lua state of our own on a thread of our own.
//
// A script mod's heavy, pure work (the road-naming rules, for one) cannot be moved off the game's threads
// from inside the game's Lua: a Lua state belongs to one thread at a time. This module makes a separate
// state with the game's own Lua 5.2 (lua_newstate, the base / string / table / math libraries, lua_load,
// lua_pcallk - all located by signature) and runs it on a worker thread. Work goes in as text and comes back
// as text; the worker state also has the tf3api table, so the script running there can hand results straight
// to the native side (road labels, files, messages) without going back through the game's threads.
//
// One worker, started on first use:
//   Start(files)   loads Lua files into the worker state. Each file is run once and whatever it returns is
//                  stored in a global named after the file ("core.lua" -> core). Starting again replaces the
//                  state. One of the files is expected to define the global function tf3_job(input).
//   Run(input)     queues a call of tf3_job(input) and returns the job's number (0 = refused).
//   Take(...)      the next finished job, if any: its number, whether it succeeded, and the text it returned
//                  (or the error).
// Jobs run one at a time, in order. The thread sleeps until there is something to do.
//
// tf3api.ini [Worker]:
//   Enabled=1     0 = no worker; scripts then do the work themselves, a slice a frame
//   SelfTest=0    1 = at startup, make a state, run a line of Lua in it and log the result

namespace tf3api::lua_worker {

// False when the Lua functions could not be located or the worker is switched off.
bool Available();

// files: paths separated by newlines, relative to the game folder; only .lua files under mods are accepted.
// Returns false with a reason when the list is refused. Loading itself happens on the worker thread; a
// file that fails to load is reported by the first job's result.
bool Start(const std::string& files, std::string* reason);

// Returns the job number, or 0 when the worker is not started, is busy with too many jobs, or the input is
// too large.
unsigned Run(const char* input, size_t length);

// Returns false when no job has finished.
bool Take(unsigned* job, bool* ok, std::string* text);

void Install();
void Uninstall();

} // namespace tf3api::lua_worker
