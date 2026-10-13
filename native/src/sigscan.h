#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

// Byte-pattern scanning over the game's main module, resolved once at startup and cached by callers.
// Pattern format: hex bytes separated by spaces, "??" for a wildcard byte, e.g. "48 8B 05 ?? ?? ?? ?? C3".

namespace tf3api::sigscan {

// Returns the address of the single match inside the main module's executable sections, or 0.
// Logs and returns 0 when there is no match or more than one match (ambiguous signatures are refused).
uintptr_t FindUnique(const char* name, const char* pattern);

// Every match of a pattern, up to `limit`, without logging. For the rare function that cannot be told from
// its look-alikes by its bytes: the caller picks the right one by what it refers to.
void FindAll(const char* pattern, size_t limit, std::vector<uintptr_t>* out);

// A second way to find a function, for when its bytes have changed with a game update: by the texts it
// refers to. The game is built with its assertions in, and each assertion names its condition, its source
// file and its function as plain text; those texts stay the same from build to build while the code around
// them is compiled anew. Returns the start of the one function (by the module's own function table) that
// refers to every one of the given texts, or 0 - logged - when no function or more than one does.
// Each text must be a whole string of the executable, exactly as it stands there.
uintptr_t FindByTexts(const char* name, const char* const* texts, size_t count);

// FindUnique, and FindByTexts when the pattern is not found exactly once. `texts` may be null.
uintptr_t FindUniqueOrByTexts(const char* name, const char* pattern, const char* const* texts, size_t count);

// The same search in a module other than the game's own (a file mapped for a test). Not logged.
// `matches` receives how many functions qualified.
uintptr_t FindByTextsIn(void* module, const char* const* texts, size_t count, int* matches);

// The start of the function that holds an address, from a module's function table; 0 when it has none.
uintptr_t FunctionStartIn(void* module, uintptr_t address);

// Resolves a RIP-relative operand: instructionAddress + instructionLength + int32 at (instructionAddress + dispOffset).
uintptr_t ResolveRipRelative(uintptr_t instructionAddress, int dispOffset, int instructionLength);

} // namespace tf3api::sigscan
