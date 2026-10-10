#pragma once

// Diagnostics: logs the call stack of the first few std::bad_alloc exceptions the game throws
// (first-chance, via a vectored exception handler), as module+offset frames, so the code path that
// fails can be found with static RE. Read-only: it never handles or swallows the exception.
//
// Added 2026-10-10 to chase an out-of-memory crash (texture streaming / simulation bad_alloc) seen with
// the cockpit depth fix active. Toggle: tf3opt.ini [Debug] BadAllocProbe (default 1).

namespace tf3opt::crash_probe {

void Install();
void Uninstall();

} // namespace tf3opt::crash_probe
