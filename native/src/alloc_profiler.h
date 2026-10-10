#pragma once

// Diagnostics: allocation profiler for tracking down memory growth.
//
// Hooks ntdll!NtAllocateVirtualMemory (every heap/allocator ultimately commits memory through it) and,
// for each commit made by this process, totals the committed bytes per call stack in a fixed-size
// table (no heap use inside the hook). A monitor thread logs the process's private bytes every 30 s
// and, each time private bytes grow another 2 GB past the starting point, writes the top call stacks
// by committed bytes to tf3opt.log.
//
// Added 2026-10-10 to find the ~45 MB/s growth seen once the cockpit camera goes below world height
// -100 with the depth fix active. Off by default: tf3opt.ini [Debug] AllocProfiler=1.
// Requires MinHook to be initialised before Install().

namespace tf3opt::alloc_profiler {

void Install();
void Uninstall();

} // namespace tf3opt::alloc_profiler
