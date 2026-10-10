#pragma once

// Diagnostics: in-process sampling profiler.
//
// On a hotkey it samples every thread of the game for a few seconds (suspend, read registers, walk the
// stack, resume) and writes a report next to the exe: CPU time per thread (threads are named by the
// engine), and for the busiest threads the functions that account for the time - by "self" time (the
// engine function running, including time inside system libraries it called), by inclusive time, and,
// for samples where the thread is waiting, which engine code is waiting.
//
// Lua: the game runs its scripts (its own and mods') in an embedded Lua 5.2.2. When a sampled thread is
// inside the interpreter, its Lua call stack is read as well, so the report names the script file and
// function line that the time belongs to (re_notes/scripting/lua_vm.md). Read-only: nothing is hooked.
//
// The exe has no symbols: functions are reported as module+offset. tools/annotate_profile.py labels them
// from the strings each function references and from the names recorded in re_notes.
//
// Safety rules while a thread is suspended: no heap allocation and no loader/OS lookups that take locks
// (the suspended thread may hold them). Stacks are unwound with each module's own unwind table, read once
// before sampling starts, and tallied only after the thread is resumed.
//
// tf3opt.ini [Profiler]:
//   Enabled=1        registers the hotkey (idle cost: none)
//   Key=119          virtual-key code that starts a capture (119 = F8). The key is taken over while the
//                    game runs, so the game itself no longer sees it.
//   Seconds=10       capture length
//   RateHz=500       samples per second per thread
//   Continuous=0     1 = no hotkey: capture back to back for the whole session, one report per `Seconds`.
//                    tf3opt_profile.txt is always the latest; the tf3opt_profiles folder keeps the
//                    newest `Keep` of them. Costs CPU the whole time (one sampling thread plus brief
//                    pauses of busy threads).
//   Keep=30          continuous mode: how many reports to keep
//   AutoCaptureAfter=0   seconds after startup to run one capture without the hotkey (0 = never); for
//                        profiling loading, and for the smoke test
//
// Output: tf3opt_profile.txt next to the exe (overwritten by each capture), plus a line in tf3opt.log.

namespace tf3opt::profiler {

void Install();
void Uninstall();

} // namespace tf3opt::profiler
