#include "sigscan.h"

#include "log.h"

#include <windows.h>

#include <cstring>
#include <vector>

namespace tf3opt::sigscan {
namespace {

struct Pattern {
    std::vector<uint8_t> bytes;
    std::vector<bool> mask;  // true = must match
};

bool Parse(const char* text, Pattern& out) {
    const char* p = text;
    while (*p) {
        while (*p == ' ') ++p;
        if (!*p) break;
        if (p[0] == '?') {
            out.bytes.push_back(0);
            out.mask.push_back(false);
            p += (p[1] == '?') ? 2 : 1;
            continue;
        }
        char hex[3] = {p[0], p[1], 0};
        if (!isxdigit(static_cast<unsigned char>(hex[0])) || !isxdigit(static_cast<unsigned char>(hex[1]))) return false;
        out.bytes.push_back(static_cast<uint8_t>(strtoul(hex, nullptr, 16)));
        out.mask.push_back(true);
        p += 2;
    }
    return !out.bytes.empty();
}

} // namespace

uintptr_t FindUnique(const char* name, const char* patternText) {
    Pattern pattern;
    if (!Parse(patternText, pattern)) {
        TF3_LOG("sigscan %s: invalid pattern", name);
        return 0;
    }

    auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    auto* section = IMAGE_FIRST_SECTION(nt);

    uintptr_t found = 0;
    int matches = 0;
    const size_t n = pattern.bytes.size();
    for (WORD s = 0; s < nt->FileHeader.NumberOfSections; ++s, ++section) {
        if (!(section->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uint8_t* start = base + section->VirtualAddress;
        size_t size = section->Misc.VirtualSize;
        if (size < n) continue;
        for (size_t i = 0; i + n <= size; ++i) {
            if (start[i] != pattern.bytes[0]) continue;
            size_t k = 1;
            while (k < n && (!pattern.mask[k] || start[i + k] == pattern.bytes[k])) ++k;
            if (k == n) {
                if (++matches == 1) found = reinterpret_cast<uintptr_t>(start + i);
            }
        }
    }

    if (matches == 1) {
        TF3_LOG("sigscan %s: found at +0x%llx", name, static_cast<unsigned long long>(found - reinterpret_cast<uintptr_t>(base)));
        return found;
    }
    TF3_LOG("sigscan %s: %s (%d matches) - refusing to hook", name, matches == 0 ? "NOT FOUND" : "AMBIGUOUS", matches);
    return 0;
}

uintptr_t ResolveRipRelative(uintptr_t instructionAddress, int dispOffset, int instructionLength) {
    int32_t disp = 0;
    std::memcpy(&disp, reinterpret_cast<const void*>(instructionAddress + dispOffset), sizeof(disp));
    return instructionAddress + instructionLength + disp;
}

} // namespace tf3opt::sigscan
