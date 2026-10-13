#include "sigscan.h"

#include "log.h"

#include <windows.h>

#include <cstring>
#include <vector>

namespace tf3api::sigscan {
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

void FindAll(const char* patternText, size_t limit, std::vector<uintptr_t>* out) {
    out->clear();
    Pattern pattern;
    if (!Parse(patternText, pattern)) return;
    auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    auto* section = IMAGE_FIRST_SECTION(nt);
    const size_t n = pattern.bytes.size();
    for (WORD s = 0; s < nt->FileHeader.NumberOfSections; ++s, ++section) {
        if (!(section->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uint8_t* start = base + section->VirtualAddress;
        const size_t size = section->Misc.VirtualSize;
        if (size < n) continue;
        for (size_t i = 0; i + n <= size; ++i) {
            if (start[i] != pattern.bytes[0]) continue;
            size_t k = 1;
            while (k < n && (!pattern.mask[k] || start[i + k] == pattern.bytes[k])) ++k;
            if (k == n) {
                out->push_back(reinterpret_cast<uintptr_t>(start + i));
                if (out->size() >= limit) return;
            }
        }
    }
}

namespace {

struct Image {
    uint8_t* base = nullptr;
    IMAGE_NT_HEADERS* nt = nullptr;
    IMAGE_SECTION_HEADER* sections = nullptr;
    WORD count = 0;
};

Image Open(void* module) {
    Image image;
    image.base = static_cast<uint8_t*>(module);
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(image.base);
    image.nt = reinterpret_cast<IMAGE_NT_HEADERS*>(image.base + dos->e_lfanew);
    image.sections = IMAGE_FIRST_SECTION(image.nt);
    image.count = image.nt->FileHeader.NumberOfSections;
    return image;
}

// Every place a text stands as a whole string (a zero before it and after it) outside the code.
void FindTexts(const Image& image, const char* text, std::vector<uintptr_t>* out) {
    const size_t n = std::strlen(text);
    if (n == 0) return;
    for (WORD s = 0; s < image.count; ++s) {
        const IMAGE_SECTION_HEADER& section = image.sections[s];
        if (section.Characteristics & IMAGE_SCN_MEM_EXECUTE) continue;
        if (!(section.Characteristics & IMAGE_SCN_CNT_INITIALIZED_DATA)) continue;
        const uint8_t* start = image.base + section.VirtualAddress;
        const size_t size = section.Misc.VirtualSize < section.SizeOfRawData ? section.Misc.VirtualSize : section.SizeOfRawData;
        if (size < n + 1) continue;
        for (size_t i = 0; i + n + 1 <= size; ++i) {
            if (start[i] != static_cast<uint8_t>(text[0])) continue;
            if (i > 0 && start[i - 1] != 0) continue;
            if (start[i + n] != 0) continue;
            if (std::memcmp(start + i, text, n) != 0) continue;
            out->push_back(reinterpret_cast<uintptr_t>(start + i));
        }
    }
}

// The function table entry that holds an address, following a chained entry to the function it belongs to.
uintptr_t FunctionStart(const Image& image, uintptr_t address) {
    const IMAGE_DATA_DIRECTORY& dir = image.nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
    if (dir.VirtualAddress == 0 || dir.Size < sizeof(RUNTIME_FUNCTION)) return 0;
    const auto* table = reinterpret_cast<const RUNTIME_FUNCTION*>(image.base + dir.VirtualAddress);
    const size_t entries = dir.Size / sizeof(RUNTIME_FUNCTION);
    const DWORD rva = static_cast<DWORD>(address - reinterpret_cast<uintptr_t>(image.base));
    size_t lo = 0, hi = entries;
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (rva < table[mid].BeginAddress) hi = mid;
        else if (rva >= table[mid].EndAddress) lo = mid + 1;
        else {
            const RUNTIME_FUNCTION* entry = &table[mid];
            // a part of a function laid out away from its body names the body's entry
            for (int hops = 0; hops < 8; ++hops) {
                const uint8_t* info = image.base + (entry->UnwindData & ~3u);
                const uint8_t flags = info[0] >> 3;
                if (!(flags & UNW_FLAG_CHAININFO)) break;
                const size_t codes = (static_cast<size_t>(info[2]) + 1) & ~static_cast<size_t>(1);
                entry = reinterpret_cast<const RUNTIME_FUNCTION*>(info + 4 + codes * 2);
            }
            return reinterpret_cast<uintptr_t>(image.base) + entry->BeginAddress;
        }
    }
    return 0;
}

} // namespace

uintptr_t FunctionStartIn(void* module, uintptr_t address) { return FunctionStart(Open(module), address); }

uintptr_t FindByTextsIn(void* module, const char* const* texts, size_t count, int* matches) {
    if (matches) *matches = 0;
    if (!module || !texts || count == 0) return 0;
    const Image image = Open(module);

    // where each text stands
    std::vector<std::vector<uintptr_t>> places(count);
    std::vector<uintptr_t> wanted;
    for (size_t t = 0; t < count; ++t) {
        FindTexts(image, texts[t], &places[t]);
        if (places[t].empty()) return 0;
        wanted.insert(wanted.end(), places[t].begin(), places[t].end());
    }
    uintptr_t lowest = wanted[0], highest = wanted[0];
    for (uintptr_t w : wanted) {
        if (w < lowest) lowest = w;
        if (w > highest) highest = w;
    }

    // the functions that take the address of each (lea reg, [rip + disp32])
    std::vector<std::vector<uintptr_t>> users(count);
    for (WORD s = 0; s < image.count; ++s) {
        const IMAGE_SECTION_HEADER& section = image.sections[s];
        if (!(section.Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        const uint8_t* start = image.base + section.VirtualAddress;
        const size_t size = section.Misc.VirtualSize;
        for (size_t i = 0; i + 7 <= size; ++i) {
            if ((start[i] & 0xFB) != 0x48 || start[i + 1] != 0x8D || (start[i + 2] & 0xC7) != 0x05) continue;
            int32_t disp = 0;
            std::memcpy(&disp, start + i + 3, sizeof(disp));
            const uintptr_t target = reinterpret_cast<uintptr_t>(start + i + 7) + disp;
            if (target < lowest || target > highest) continue;
            for (size_t t = 0; t < count; ++t) {
                bool hit = false;
                for (uintptr_t place : places[t]) hit = hit || place == target;
                if (!hit) continue;
                const uintptr_t fn = FunctionStart(image, reinterpret_cast<uintptr_t>(start + i));
                if (fn == 0) continue;
                bool known = false;
                for (uintptr_t u : users[t]) known = known || u == fn;
                if (!known) users[t].push_back(fn);
            }
        }
    }

    // the functions that use every one of them
    uintptr_t found = 0;
    int n = 0;
    for (uintptr_t candidate : users[0]) {
        bool all = true;
        for (size_t t = 1; t < count && all; ++t) {
            bool has = false;
            for (uintptr_t u : users[t]) has = has || u == candidate;
            all = has;
        }
        if (all) {
            if (++n == 1) found = candidate;
        }
    }
    if (matches) *matches = n;
    return n == 1 ? found : 0;
}

uintptr_t FindByTexts(const char* name, const char* const* texts, size_t count) {
    void* module = GetModuleHandleW(nullptr);
    int matches = 0;
    const uintptr_t found = FindByTextsIn(module, texts, count, &matches);
    if (found != 0) {
        TF3_LOG("sigscan %s: found by its texts at +0x%llx", name,
                static_cast<unsigned long long>(found - reinterpret_cast<uintptr_t>(module)));
        return found;
    }
    TF3_LOG("sigscan %s: by its texts %s (%d functions)", name, matches == 0 ? "NOT FOUND" : "AMBIGUOUS", matches);
    return 0;
}

uintptr_t FindUniqueOrByTexts(const char* name, const char* pattern, const char* const* texts, size_t count) {
    const uintptr_t found = FindUnique(name, pattern);
    if (found != 0 || !texts || count == 0) return found;
    return FindByTexts(name, texts, count);
}

uintptr_t ResolveRipRelative(uintptr_t instructionAddress, int dispOffset, int instructionLength) {
    int32_t disp = 0;
    std::memcpy(&disp, reinterpret_cast<const void*>(instructionAddress + dispOffset), sizeof(disp));
    return instructionAddress + instructionLength + disp;
}

} // namespace tf3api::sigscan
