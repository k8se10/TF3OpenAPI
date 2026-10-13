// Checks the "find a function by the texts it refers to" resolver against a game executable on disk.
//
//   sigscan_test.exe <TransportFever3.exe> <cases.tsv>
//
// The executable is only mapped (never run). Each line of the cases file is
//   <expected function start, hex, relative to the image base> TAB <text> [TAB <text> ...]
// as written by tools/make_sig_cases.py from the recovered function names. A case passes when the resolver
// returns exactly that function; it is "not unique" when several functions use the same texts (the resolver
// then rightly refuses), and wrong when it returns another function.
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

namespace tf3api::log {
void Write(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
}
} // namespace tf3api::log

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        printf("usage: sigscan_test <exe> <cases.tsv>\n");
        return 2;
    }
    HMODULE module = LoadLibraryExW(argv[1], nullptr, DONT_RESOLVE_DLL_REFERENCES);
    if (!module) {
        printf("cannot map the executable (error %lu)\n", GetLastError());
        return 2;
    }
    const auto base = reinterpret_cast<uintptr_t>(module);
    std::ifstream in(argv[2], std::ios::binary);
    std::string line;
    int cases = 0, right = 0, notUnique = 0, notFound = 0, wrong = 0;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        std::vector<std::string> fields;
        size_t from = 0;
        for (;;) {
            const size_t tab = line.find('\t', from);
            fields.push_back(line.substr(from, tab == std::string::npos ? std::string::npos : tab - from));
            if (tab == std::string::npos) break;
            from = tab + 1;
        }
        if (fields.size() < 2) continue;
        const uintptr_t expected = base + strtoull(fields[0].c_str(), nullptr, 16);
        std::vector<const char*> texts;
        for (size_t i = 1; i < fields.size(); ++i) texts.push_back(fields[i].c_str());
        int matches = 0;
        const uintptr_t found = tf3api::sigscan::FindByTextsIn(module, texts.data(), texts.size(), &matches);
        ++cases;
        if (found == expected) ++right;
        else if (found != 0) {
            ++wrong;
            if (wrong <= 10) printf("WRONG  expected +0x%llx, got +0x%llx  %s\n", static_cast<unsigned long long>(expected - base),
                                    static_cast<unsigned long long>(found - base), fields[1].c_str());
        } else if (matches > 1) ++notUnique;
        else ++notFound;
    }
    printf("%d cases: %d right, %d refused as not unique, %d not found, %d wrong\n", cases, right, notUnique, notFound, wrong);
    return wrong == 0 && right > 0 ? 0 : 1;
}
