#pragma once

#include <cstdint>

// Byte-pattern scanning over the game's main module, resolved once at startup and cached by callers.
// Pattern format: hex bytes separated by spaces, "??" for a wildcard byte, e.g. "48 8B 05 ?? ?? ?? ?? C3".

namespace tf3opt::sigscan {

// Returns the address of the single match inside the main module's executable sections, or 0.
// Logs and returns 0 when there is no match or more than one match (ambiguous signatures are refused).
uintptr_t FindUnique(const char* name, const char* pattern);

// Resolves a RIP-relative operand: instructionAddress + instructionLength + int32 at (instructionAddress + dispOffset).
uintptr_t ResolveRipRelative(uintptr_t instructionAddress, int dispOffset, int instructionLength);

} // namespace tf3opt::sigscan
