#include "own_mods.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>
#include <shlobj.h>

#include <cstdint>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "MinHook.h"

namespace fs = std::filesystem;

namespace tf3api::own_mods {
namespace {

#if defined(__has_include)
#if __has_include("own_mods.inc")
#define TF3_HAVE_OWN_MODS 1
#endif
#endif

#ifdef TF3_HAVE_OWN_MODS
const unsigned char kPacked[] = {
#include "own_mods.inc"
};
#else
const unsigned char kPacked[] = { 0 };
#endif

constexpr const char* kSourceName = "TF3OpenAPI";
constexpr const char* kManifest = "tf3api_extracted.txt";

// ---- Inflate (raw deflate, RFC 1951), after Mark Adler's "puff" (zlib licence) --------------------------------

struct Inflater {
    const uint8_t* in;
    size_t inLen, inPos;
    uint8_t* out;
    size_t outLen, outPos;
    uint32_t bitBuf;
    int bitCount;
    bool failed;
};

struct Huffman {
    uint16_t count[16];
    uint16_t symbol[288];
};

int Bits(Inflater& s, int need) {
    long val = s.bitBuf;
    while (s.bitCount < need) {
        if (s.inPos >= s.inLen) {
            s.failed = true;
            return 0;
        }
        val |= static_cast<long>(s.in[s.inPos++]) << s.bitCount;
        s.bitCount += 8;
    }
    s.bitBuf = static_cast<uint32_t>(val >> need);
    s.bitCount -= need;
    return static_cast<int>(val & ((1L << need) - 1));
}

int Construct(Huffman& h, const short* length, int n) {
    for (int len = 0; len <= 15; ++len) h.count[len] = 0;
    for (int symbol = 0; symbol < n; ++symbol) h.count[length[symbol]]++;
    if (h.count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= 15; ++len) {
        left <<= 1;
        left -= h.count[len];
        if (left < 0) return left;
    }
    short offs[16];
    offs[1] = 0;
    for (int len = 1; len < 15; ++len) offs[len + 1] = static_cast<short>(offs[len] + h.count[len]);
    for (int symbol = 0; symbol < n; ++symbol) {
        if (length[symbol] != 0) h.symbol[offs[length[symbol]]++] = static_cast<uint16_t>(symbol);
    }
    return left;
}

int Decode(Inflater& s, const Huffman& h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= 15; ++len) {
        code |= Bits(s, 1);
        if (s.failed) return -1;
        const int count = h.count[len];
        if (code - count < first) return h.symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -1;
}

bool Codes(Inflater& s, const Huffman& lencode, const Huffman& distcode) {
    static const short lens[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    static const short lext[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    static const short dists[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
    static const short dext[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
    for (;;) {
        int symbol = Decode(s, lencode);
        if (symbol < 0) return false;
        if (symbol < 256) {
            if (s.outPos >= s.outLen) return false;
            s.out[s.outPos++] = static_cast<uint8_t>(symbol);
        } else if (symbol == 256) {
            return true;
        } else {
            symbol -= 257;
            if (symbol >= 29) return false;
            const int len = lens[symbol] + Bits(s, lext[symbol]);
            symbol = Decode(s, distcode);
            if (symbol < 0 || symbol >= 30) return false;
            const size_t dist = static_cast<size_t>(dists[symbol] + Bits(s, dext[symbol]));
            if (s.failed || dist > s.outPos || s.outPos + static_cast<size_t>(len) > s.outLen) return false;
            for (int i = 0; i < len; ++i, ++s.outPos) s.out[s.outPos] = s.out[s.outPos - dist];
        }
    }
}

bool Inflate(const uint8_t* in, size_t inLen, uint8_t* out, size_t outLen) {
    Inflater s{ in, inLen, 0, out, outLen, 0, 0, 0, false };
    int last;
    do {
        last = Bits(s, 1);
        const int type = Bits(s, 2);
        if (s.failed) return false;
        if (type == 0) {
            s.bitBuf = 0;
            s.bitCount = 0;
            if (s.inPos + 4 > s.inLen) return false;
            const unsigned len = s.in[s.inPos] | (s.in[s.inPos + 1] << 8);
            const unsigned nlen = s.in[s.inPos + 2] | (s.in[s.inPos + 3] << 8);
            s.inPos += 4;
            if (len != (~nlen & 0xFFFF) || s.inPos + len > s.inLen || s.outPos + len > s.outLen) return false;
            std::memcpy(s.out + s.outPos, s.in + s.inPos, len);
            s.inPos += len;
            s.outPos += len;
        } else if (type == 1) {
            static Huffman lencode, distcode;
            static bool built = false;
            if (!built) {
                short lengths[288];
                int symbol = 0;
                for (; symbol < 144; ++symbol) lengths[symbol] = 8;
                for (; symbol < 256; ++symbol) lengths[symbol] = 9;
                for (; symbol < 280; ++symbol) lengths[symbol] = 7;
                for (; symbol < 288; ++symbol) lengths[symbol] = 8;
                Construct(lencode, lengths, 288);
                for (symbol = 0; symbol < 30; ++symbol) lengths[symbol] = 5;
                Construct(distcode, lengths, 30);
                built = true;
            }
            if (!Codes(s, lencode, distcode)) return false;
        } else if (type == 2) {
            static const short order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
            const int nlen = Bits(s, 5) + 257, ndist = Bits(s, 5) + 1, ncode = Bits(s, 4) + 4;
            if (s.failed || nlen > 286 || ndist > 30) return false;
            short lengths[320];
            int index = 0;
            for (; index < ncode; ++index) lengths[order[index]] = static_cast<short>(Bits(s, 3));
            for (; index < 19; ++index) lengths[order[index]] = 0;
            Huffman lencode, distcode;
            if (Construct(lencode, lengths, 19) != 0) return false;
            index = 0;
            while (index < nlen + ndist) {
                int symbol = Decode(s, lencode);
                if (symbol < 0) return false;
                if (symbol < 16) {
                    lengths[index++] = static_cast<short>(symbol);
                } else {
                    int len = 0, rep;
                    if (symbol == 16) {
                        if (index == 0) return false;
                        len = lengths[index - 1];
                        rep = 3 + Bits(s, 2);
                    } else if (symbol == 17) {
                        rep = 3 + Bits(s, 3);
                    } else {
                        rep = 11 + Bits(s, 7);
                    }
                    if (s.failed || index + rep > nlen + ndist) return false;
                    while (rep--) lengths[index++] = static_cast<short>(len);
                }
            }
            if (lengths[256] == 0) return false;
            int err = Construct(lencode, lengths, nlen);
            if (err != 0 && (err < 0 || nlen != lencode.count[0] + lencode.count[1])) return false;
            err = Construct(distcode, lengths + nlen, ndist);
            if (err != 0 && (err < 0 || ndist != distcode.count[0] + distcode.count[1])) return false;
            if (!Codes(s, lencode, distcode)) return false;
        } else {
            return false;
        }
    } while (!last);
    return s.outPos == s.outLen;
}

uint32_t Crc32(const uint8_t* data, size_t size) {
    static uint32_t table[256];
    static bool ready = false;
    if (!ready) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = true;
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < size; ++i) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

// ---- Folder and files -------------------------------------------------------------------------------------

fs::path g_folder;          // where the mods are, once Extract has run
fs::path g_convertedRoot;   // where converted mods go (a folder for each game below it)

struct Scan {
    fs::path path;
    std::string source;
};
std::vector<Scan> g_scans;   // the folders added to the game's scan, with the source each is stamped with

fs::path Long(const fs::path& path) {
    std::wstring text = path.wstring();
    if (text.size() < 240 || text.rfind(L"\\\\?\\", 0) == 0) return path;
    return fs::path(L"\\\\?\\" + text);
}

fs::path FolderPath() {
    PWSTR known = nullptr;
    fs::path base;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &known)) && known != nullptr) base = known;
    if (known != nullptr) CoTaskMemFree(known);
    if (base.empty()) return {};
    return base / L"TF3OpenAPI" / L"mods";
}

std::wstring FromUtf8(const std::string& text) {
    if (text.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), w.data(), n);
    return w;
}

std::string ToUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
    return s;
}

struct Packed {
    std::string name;
    uint32_t raw, packed, crc;
    const uint8_t* data;
};

bool ReadPacked(std::vector<Packed>* files) {
    const uint8_t* p = kPacked;
    const uint8_t* end = kPacked + sizeof(kPacked);
    if (sizeof(kPacked) < 8 || std::memcmp(p, "TF3M", 4) != 0) return false;
    uint32_t count;
    std::memcpy(&count, p + 4, 4);
    p += 8;
    for (uint32_t i = 0; i < count; ++i) {
        if (end - p < 2) return false;
        uint16_t nameLen;
        std::memcpy(&nameLen, p, 2);
        p += 2;
        if (end - p < nameLen + 12) return false;
        Packed f;
        f.name.assign(reinterpret_cast<const char*>(p), nameLen);
        p += nameLen;
        std::memcpy(&f.raw, p, 4);
        std::memcpy(&f.packed, p + 4, 4);
        std::memcpy(&f.crc, p + 8, 4);
        p += 12;
        if (static_cast<size_t>(end - p) < f.packed) return false;
        f.data = p;
        p += f.packed;
        files->push_back(std::move(f));
    }
    return true;
}

bool SafeName(const std::string& name) {
    if (name.empty() || name.size() > 400 || name[0] == '/' || name.find("..") != std::string::npos || name.find('\\') != std::string::npos ||
        name.find(':') != std::string::npos) {
        return false;
    }
    return true;
}

std::map<std::string, uint32_t> ReadManifest(const fs::path& file) {
    std::map<std::string, uint32_t> m;
    std::ifstream in(Long(file), std::ios::binary);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t tab = line.find('\t');
        if (tab == std::string::npos) continue;
        m[line.substr(tab + 1)] = static_cast<uint32_t>(std::strtoul(line.substr(0, tab).c_str(), nullptr, 16));
    }
    return m;
}

// ---- The scan hook ------------------------------------------------------------------------------------------
// modhub UpdateLocalInstallations scans the game's mod folders with one helper, once for each folder, giving
// it the source name to stamp on what it finds there (re_notes/ui/mod_sources.md). After the scan for "DLC"
// this scans our own folder too, under our own name.

using ScanFn = void (*)(void* context, const fs::path* folder, const std::string* source, void* out);
ScanFn g_original = nullptr;
void* g_target = nullptr;

void HookScan(void* context, const fs::path* folder, const std::string* source, void* out) {
    g_original(context, folder, source, out);
    if (source != nullptr && *source == "DLC") {
        for (const Scan& scan : g_scans) g_original(context, &scan.path, &scan.source, out);
    }
}

} // namespace

fs::path ConvertedRoot() { return g_convertedRoot; }

fs::path Extract() {
    if (!config::GetBool("OwnMods", "Enabled", false)) return {};
    try {
        // the folders for converted mods, whether or not anything is packed in
        {
            const fs::path mods = FolderPath();
            if (!mods.empty()) {
                const fs::path converted = mods.parent_path() / L"converted";
                std::error_code made;
                for (const wchar_t* game : { L"trf", L"tf1", L"tf2" }) fs::create_directories(Long(converted / game), made);
                if (!made) g_convertedRoot = converted;
            }
        }
        std::vector<Packed> files;
        if (!ReadPacked(&files) || files.empty()) {
            TF3_LOG("own mods: nothing is packed into this DLL (run tools/embed_mods.py before building)");
            return {};
        }
        const fs::path folder = FolderPath();
        if (folder.empty()) {
            TF3_LOG("own mods: the AppData folder could not be found");
            return {};
        }
        std::error_code ec;
        fs::create_directories(Long(folder), ec);
        if (ec) {
            TF3_LOG("own mods: cannot create the mods folder: %s", ec.message().c_str());
            return {};
        }
        const fs::path manifestPath = folder / kManifest;
        std::map<std::string, uint32_t> before = ReadManifest(manifestPath);
        std::map<std::string, uint32_t> after;
        int written = 0, failed = 0;
        std::vector<uint8_t> raw;
        for (const Packed& f : files) {
            if (!SafeName(f.name)) {
                ++failed;
                continue;
            }
            const fs::path target = folder / FromUtf8(f.name);
            auto known = before.find(f.name);
            std::error_code e2;
            bool current = known != before.end() && known->second == f.crc && fs::is_regular_file(Long(target), e2);
            if (current) {
                // the size on disk is what was written; a file edited by hand is put back
                current = fs::file_size(Long(target), e2) == f.raw && !e2;
            }
            if (!current) {
                raw.resize(f.raw);
                if (!Inflate(f.data, f.packed, raw.data(), f.raw) || Crc32(raw.data(), raw.size()) != f.crc) {
                    TF3_LOG("own mods: %s is damaged in this DLL", f.name.c_str());
                    ++failed;
                    continue;
                }
                fs::create_directories(Long(target.parent_path()), e2);
                std::ofstream out(Long(target), std::ios::binary | std::ios::trunc);
                if (!out) {
                    TF3_LOG("own mods: cannot write %s", f.name.c_str());
                    ++failed;
                    continue;
                }
                out.write(reinterpret_cast<const char*>(raw.data()), static_cast<std::streamsize>(raw.size()));
                out.close();
                ++written;
            }
            after[f.name] = f.crc;
        }
        // a file written earlier and no longer shipped is removed; nothing else in the folder is touched
        int removed = 0;
        for (const auto& [name, crc] : before) {
            if (after.count(name) == 0 && SafeName(name)) {
                std::error_code e2;
                if (fs::remove(Long(folder / FromUtf8(name)), e2)) ++removed;
            }
        }
        std::ofstream manifest(Long(manifestPath), std::ios::binary | std::ios::trunc);
        for (const auto& [name, crc] : after) {
            char hex[16];
            std::snprintf(hex, sizeof(hex), "%08x", crc);
            manifest << hex << '\t' << name << '\n';
        }
        TF3_LOG("own mods: %zu files in %s (%d written, %d removed, %d failed)", after.size(), ToUtf8(folder.wstring()).c_str(), written, removed, failed);
        g_folder = folder;
        return folder;
    } catch (const std::exception& e) {
        TF3_LOG("own mods: stopped - %s", e.what());
    } catch (...) {
        TF3_LOG("own mods: stopped for an unknown reason");
    }
    return {};
}

void Install() {
    if (g_folder.empty() && g_convertedRoot.empty()) return;
    if (!g_folder.empty()) g_scans.push_back({ g_folder, kSourceName });
    if (!g_convertedRoot.empty()) {
        g_scans.push_back({ g_convertedRoot / L"trf", "TF3OpenAPI-TrF" });
        g_scans.push_back({ g_convertedRoot / L"tf1", "TF3OpenAPI-TF1" });
        g_scans.push_back({ g_convertedRoot / L"tf2", "TF3OpenAPI-TF2" });
    }
    g_target = reinterpret_cast<void*>(sigscan::FindUnique(
        "ModHub folder scan",
        "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 56 48 81 EC B0 00 00 00 4D 8B F1 49 8B E8 48 8B F2 48 8B D9 C5 F9 EF C0"));
    if (g_target == nullptr) {
        TF3_LOG("own mods: the game's mod folder scan was not found - the TF3OpenAPI mods folder is not scanned");
        return;
    }
    MH_STATUS status = MH_CreateHook(g_target, reinterpret_cast<void*>(&HookScan), reinterpret_cast<void**>(&g_original));
    if (status == MH_OK) status = MH_EnableHook(g_target);
    if (status != MH_OK) {
        TF3_LOG("own mods: the hook could not be installed (%s)", MH_StatusToString(status));
        g_target = nullptr;
        return;
    }
    TF3_LOG("own mods: the game's mod scan also looks in %zu TF3OpenAPI folders (sources TF3OpenAPI, -TrF, -TF1, -TF2)", g_scans.size());
}

void Uninstall() {
    if (g_target == nullptr) return;
    MH_DisableHook(g_target);
    g_target = nullptr;
}

} // namespace tf3api::own_mods
