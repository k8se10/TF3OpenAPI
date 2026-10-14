#include "mod_converter.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <sstream>
#include <system_error>
#include <vector>

#include "lua.hpp"

namespace fs = std::filesystem;

namespace tf3api::mod_converter {

namespace {

const unsigned char kRules[] = {
#include "convert_lua.inc"
};

// shipped inside a converted station mod (see converter/station_shim.lua)
const unsigned char kStationShim[] = {
#include "station_shim_lua.inc"
};

// changes for particular old mods (see converter/remasters.lua)
const unsigned char kRemasters[] = {
#include "remasters_lua.inc"
};

// the notice every converted mod carries (converter/notice.script.lua)
const unsigned char kNotice[] = {
#include "notice_lua.inc"
};

// Isotherm Sans Bold (SIL Open Font License 1.1, native/third_party/isotherm_sans/OFL.txt), for remasters whose
// labels name it (written by tools/embed_font.py)
const unsigned char kIsothermSansBold[] = {
#include "isotherm_sans_bold.inc"
};

const char* const kInboxName = "legacy_mods";
const char* const kStateName = "tf3api_converted.txt";   // inside the inbox: what was converted, and from what
const char* const kStageName = ".tf3api_stage";          // inside the inbox: a conversion in progress

fs::path FromUtf8(const char* text) { return fs::path(std::u8string(reinterpret_cast<const char8_t*>(text))); }

// Old mods have long file names; with the game's folder in front they can pass the 260 characters most file
// calls stop at. The extended form of an absolute path has no such limit.
fs::path Long(const fs::path& path) {
    std::error_code ec;
    fs::path absolute = fs::absolute(path, ec);
    if (ec) return path;
    std::wstring text = absolute.lexically_normal().make_preferred().wstring();
    if (text.rfind(L"\\\\", 0) == 0) return fs::path(text);   // already extended, or a network path
    return fs::path(L"\\\\?\\" + text);
}

std::string ToUtf8(const fs::path& path) {
    std::u8string s = path.generic_u8string();
    return std::string(reinterpret_cast<const char*>(s.data()), s.size());
}

// The rules may read anywhere under the old mod and write anywhere under the staging folder, nowhere else.
struct Job {
    fs::path source;
    fs::path stage;
};

// every old mod in the inbox: one may use files of another
std::vector<fs::path> g_inbox;
uint32_t g_inboxHash = 0;
bool g_stations = false;
bool g_stationDebug = false;
bool g_remasters = true;
bool g_glassParts = false;
bool g_packTextures = false;
bool g_labelFont = false;

bool IsUnder(const fs::path& path, const fs::path& root) {
    std::error_code ec;
    fs::path p = fs::weakly_canonical(Long(path), ec);
    if (ec) return false;
    fs::path r = fs::weakly_canonical(Long(root), ec);
    if (ec) return false;
    auto pi = p.begin();
    for (auto ri = r.begin(); ri != r.end(); ++ri, ++pi) {
        if (pi == p.end() || *pi != *ri) return false;
    }
    return true;
}

Job* JobOf(lua_State* L) { return static_cast<Job*>(lua_touserdata(L, lua_upvalueindex(1))); }

int HostList(lua_State* L) {
    Job* job = JobOf(L);
    fs::path root = FromUtf8(luaL_checkstring(L, 1));
    lua_newtable(L);
    if (!IsUnder(root, job->source)) return 1;
    std::error_code ec;
    lua_Integer n = 0;
    const fs::path longRoot = Long(root);
    for (fs::recursive_directory_iterator it(longRoot, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
        if (!it->is_regular_file(ec)) continue;
        std::string rel = ToUtf8(it->path().lexically_relative(longRoot));
        lua_pushlstring(L, rel.data(), rel.size());
        lua_rawseti(L, -2, ++n);
    }
    return 1;
}

// The other old mods in the inbox and the files each has: { { folder = <name>, files = { <path>, ... } }, ... }.
// Names only; nothing of another mod can be read through this.
int HostSiblings(lua_State* L) {
    Job* job = JobOf(L);
    lua_newtable(L);
    lua_Integer count = 0;
    const std::string own = ToUtf8(job->source.filename());
    for (const fs::path& folder : g_inbox) {
        const std::string name = ToUtf8(folder.filename());
        if (name == own) continue;
        lua_newtable(L);
        lua_pushlstring(L, name.data(), name.size());
        lua_setfield(L, -2, "folder");
        lua_newtable(L);
        std::error_code ec;
        lua_Integer n = 0;
        const fs::path longRoot = Long(folder);
        for (fs::recursive_directory_iterator it(longRoot, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
            if (!it->is_regular_file(ec)) continue;
            std::string rel = ToUtf8(it->path().lexically_relative(longRoot));
            lua_pushlstring(L, rel.data(), rel.size());
            lua_rawseti(L, -2, ++n);
        }
        lua_setfield(L, -2, "files");
        lua_rawseti(L, -2, ++count);
    }
    return 1;
}

int ReadUpTo(lua_State* L, std::streamsize limit) {
    Job* job = JobOf(L);
    fs::path path = FromUtf8(luaL_checkstring(L, 1));
    if (!IsUnder(path, job->source)) return 0;
    std::ifstream in(Long(path), std::ios::binary);
    if (!in) return 0;
    std::string data;
    if (limit < 0) {
        std::ostringstream all;
        all << in.rdbuf();
        data = all.str();
    } else {
        data.resize(static_cast<size_t>(limit));
        in.read(data.data(), limit);
        data.resize(static_cast<size_t>(in.gcount()));
    }
    lua_pushlstring(L, data.data(), data.size());
    return 1;
}

int HostRead(lua_State* L) { return ReadUpTo(L, -1); }

int HostReadHead(lua_State* L) {
    lua_Integer n = luaL_checkinteger(L, 2);
    if (n < 0) n = 0;
    if (n > 65536) n = 65536;
    return ReadUpTo(L, static_cast<std::streamsize>(n));
}

int HostWrite(lua_State* L) {
    Job* job = JobOf(L);
    fs::path path = FromUtf8(luaL_checkstring(L, 1));
    size_t size = 0;
    const char* data = luaL_checklstring(L, 2, &size);
    if (!IsUnder(path, job->stage)) return luaL_error(L, "write outside the output folder: %s", lua_tostring(L, 1));
    std::error_code ec;
    fs::create_directories(Long(path.parent_path()), ec);
    std::ofstream out(Long(path), std::ios::binary | std::ios::trunc);
    if (!out) return luaL_error(L, "cannot write %s", lua_tostring(L, 1));
    out.write(data, static_cast<std::streamsize>(size));
    return 0;
}

int HostCopy(lua_State* L) {
    Job* job = JobOf(L);
    fs::path from = FromUtf8(luaL_checkstring(L, 1));
    fs::path to = FromUtf8(luaL_checkstring(L, 2));
    if (!IsUnder(from, job->source)) return luaL_error(L, "copy from outside the old mod: %s", lua_tostring(L, 1));
    if (!IsUnder(to, job->stage)) return luaL_error(L, "copy to outside the output folder: %s", lua_tostring(L, 2));
    std::error_code ec;
    fs::create_directories(Long(to.parent_path()), ec);
    fs::copy_file(Long(from), Long(to), fs::copy_options::overwrite_existing, ec);
    if (ec) return luaL_error(L, "cannot copy %s: %s", lua_tostring(L, 1), ec.message().c_str());
    return 0;
}

// A .tga picture (uncompressed or run-length packed, 8, 24 or 32 bits) read into rows of blue-green-red-alpha,
// top row first. False when the file is not one of those.
bool ReadTga(const fs::path& path, uint32_t* width, uint32_t* height, std::vector<uint8_t>* pixels) {
    std::ifstream in(Long(path), std::ios::binary);
    if (!in) return false;
    std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (file.size() < 18) return false;
    const uint8_t idLength = file[0], colourMap = file[1], kind = file[2], bits = file[16], descriptor = file[17];
    const uint32_t w = file[12] | (file[13] << 8), h = file[14] | (file[15] << 8);
    const bool packed = (kind == 10 || kind == 11);
    const bool grey = (kind == 3 || kind == 11);
    if (colourMap != 0 || !(kind == 2 || kind == 3 || packed)) return false;
    if (w == 0 || h == 0 || w > 16384 || h > 16384) return false;
    if (!((grey && bits == 8) || (!grey && (bits == 24 || bits == 32)))) return false;
    const size_t step = bits / 8;
    const size_t count = static_cast<size_t>(w) * h;
    std::vector<uint8_t> raw(count * step);
    size_t at = 18 + idLength;
    if (!packed) {
        if (file.size() < at + raw.size()) return false;
        std::copy(file.begin() + at, file.begin() + at + raw.size(), raw.begin());
    } else {
        size_t done = 0;
        while (done < count) {
            if (at >= file.size()) return false;
            const uint8_t head = file[at++];
            const size_t run = (head & 0x7f) + 1;
            if (done + run > count) return false;
            if (head & 0x80) {
                if (at + step > file.size()) return false;
                for (size_t i = 0; i < run; ++i) std::copy(file.begin() + at, file.begin() + at + step, raw.begin() + (done + i) * step);
                at += step;
            } else {
                if (at + run * step > file.size()) return false;
                std::copy(file.begin() + at, file.begin() + at + run * step, raw.begin() + done * step);
                at += run * step;
            }
            done += run;
        }
    }
    const bool topFirst = (descriptor & 0x20) != 0;
    const bool rightFirst = (descriptor & 0x10) != 0;
    pixels->assign(count * 4, 255);
    for (uint32_t y = 0; y < h; ++y) {
        const uint32_t from = topFirst ? y : (h - 1 - y);
        for (uint32_t x = 0; x < w; ++x) {
            const uint8_t* p = &raw[(static_cast<size_t>(from) * w + (rightFirst ? (w - 1 - x) : x)) * step];
            uint8_t* q = &(*pixels)[(static_cast<size_t>(y) * w + x) * 4];
            if (grey) { q[0] = q[1] = q[2] = p[0]; }
            else { q[0] = p[0]; q[1] = p[1]; q[2] = p[2]; if (step == 4) q[3] = p[3]; }
        }
    }
    *width = w;
    *height = h;
    return true;
}

// Writes rows of blue-green-red-alpha as an uncompressed .dds with every mip level (each the one above averaged
// two by two). Returns the number of levels, 0 on failure.
// A Radiance picture (.hdr, "RGBE": three mantissas and a shared exponent a pixel, plain or run-length packed
// by scanline). The older games took these for lamp pictures; the newer one reads the file but cannot use the
// format it gets from it ("Unsupported format E5B9G9R9UfloatPack32", seen in its log). Read here into ordinary
// 8-bit pixels (blue, green, red, alpha - as the .dds writer takes them), scaled so that the brightest value in
// the picture is full white; *peak is that brightest value, so the caller can keep the brightness elsewhere.
bool ReadHdr(const fs::path& path, uint32_t* width, uint32_t* height, std::vector<uint8_t>* pixels, double* peak) {
    std::ifstream in(Long(path), std::ios::binary);
    if (!in) return false;
    std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (file.size() < 16 || std::memcmp(file.data(), "#?", 2) != 0) return false;
    // the header: lines of text up to an empty line, then the size line "-Y <height> +X <width>"
    size_t at = 0;
    auto line = [&file, &at]() {
        std::string text;
        while (at < file.size() && file[at] != '\n') text.push_back(static_cast<char>(file[at++]));
        if (at < file.size()) ++at;
        return text;
    };
    bool rgbe = false;
    for (;;) {
        if (at >= file.size()) return false;
        const std::string text = line();
        if (text.empty()) break;
        if (text.find("FORMAT=32-bit_rle_rgbe") != std::string::npos) rgbe = true;
    }
    if (!rgbe) return false;
    const std::string size = line();
    unsigned w = 0, h = 0;
    // (the usual orientation only: top row first, left to right)
    if (size.compare(0, 3, "-Y ") != 0) return false;
    char* rest = nullptr;
    h = static_cast<unsigned>(std::strtoul(size.c_str() + 3, &rest, 10));
    if (rest == nullptr || std::strncmp(rest, " +X ", 4) != 0) return false;
    w = static_cast<unsigned>(std::strtoul(rest + 4, nullptr, 10));
    if (w == 0 || h == 0 || w > 16384 || h > 16384) return false;
    std::vector<uint8_t> raw(static_cast<size_t>(w) * h * 4);
    for (unsigned y = 0; y < h; ++y) {
        uint8_t* row = raw.data() + static_cast<size_t>(y) * w * 4;
        if (at + 4 > file.size()) return false;
        const bool packed = w >= 8 && w < 32768 && file[at] == 2 && file[at + 1] == 2 && ((static_cast<unsigned>(file[at + 2]) << 8) | file[at + 3]) == w;
        if (packed) {
            at += 4;
            for (int channel = 0; channel < 4; ++channel) {
                unsigned x = 0;
                while (x < w) {
                    if (at >= file.size()) return false;
                    unsigned count = file[at++];
                    if (count > 128) {
                        count -= 128;
                        if (at >= file.size() || x + count > w) return false;
                        const uint8_t value = file[at++];
                        while (count-- > 0) row[(x++) * 4 + channel] = value;
                    } else {
                        if (count == 0 || at + count > file.size() || x + count > w) return false;
                        while (count-- > 0) row[(x++) * 4 + channel] = file[at++];
                    }
                }
            }
        } else {
            if (at + static_cast<size_t>(w) * 4 > file.size()) return false;
            std::memcpy(row, file.data() + at, static_cast<size_t>(w) * 4);
            at += static_cast<size_t>(w) * 4;
        }
    }
    std::vector<float> values(static_cast<size_t>(w) * h * 3);
    double top = 0.0;
    for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) {
        const uint8_t e = raw[i * 4 + 3];
        const double scale = e == 0 ? 0.0 : std::ldexp(1.0, static_cast<int>(e) - 136);
        for (int c = 0; c < 3; ++c) {
            const double v = raw[i * 4 + c] * scale;
            values[i * 3 + c] = static_cast<float>(v);
            if (v > top) top = v;
        }
    }
    if (!(top > 0.0)) return false;
    pixels->assign(static_cast<size_t>(w) * h * 4, 255);
    for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) {
        for (int c = 0; c < 3; ++c) {
            const double v = values[i * 3 + c] / top * 255.0 + 0.5;
            (*pixels)[i * 4 + (2 - c)] = static_cast<uint8_t>(v > 255.0 ? 255.0 : v);   // red first in the file, blue first here
        }
    }
    *width = w;
    *height = h;
    *peak = top;
    return true;
}

// How a picture is written. The game's own vehicle pictures (1,917 of them, counted) are all packed in
// blocks of 4 x 4 points with every mip level: colour with opacity as "DXT5", colour without and the
// metal / gloss / shade and colour-blend pictures as "DXT1", normal maps as two channels ("BC5").
// A packed picture takes a quarter to an eighth of the room, on disk and on the graphics card.
enum class Packing { Plain, Colour, ColourOpacity, Normal };

// One channel of a block as two end values and sixteen 3-bit steps between them (the opacity of DXT5 and
// each channel of BC5). `values`: 16 numbers.
void PackChannel(const uint8_t* values, uint8_t* out) {
    uint8_t low = 255, high = 0;
    for (int i = 0; i < 16; ++i) {
        if (values[i] < low) low = values[i];
        if (values[i] > high) high = values[i];
    }
    out[0] = high;
    out[1] = low;
    uint64_t bits = 0;
    if (high > low) {
        // with high first there are eight steps: high, low, then six between, counted from high
        for (int i = 0; i < 16; ++i) {
            const int step = ((high - values[i]) * 7 + (high - low) / 2) / (high - low);   // 0 = high .. 7 = low
            const int code = step == 0 ? 0 : step == 7 ? 1 : step + 1;
            bits |= static_cast<uint64_t>(code) << (i * 3);
        }
    }
    for (int i = 0; i < 6; ++i) out[2 + i] = static_cast<uint8_t>(bits >> (i * 8));
}

// The colour of a block as two 16-bit end colours and sixteen 2-bit steps (DXT1, and the colour half of
// DXT5). `block`: 16 points of blue, green, red, opacity. The ends are the two ends of the block's colours
// along the direction in which they differ most.
void PackColour(const uint8_t* block, uint8_t* out) {
    int low[3] = {255, 255, 255}, high[3] = {0, 0, 0};
    for (int i = 0; i < 16; ++i) {
        for (int c = 0; c < 3; ++c) {
            const int v = block[i * 4 + c];
            if (v < low[c]) low[c] = v;
            if (v > high[c]) high[c] = v;
        }
    }
    // which corners of the box the colours run between: by how blue and green go with red
    long long withRed[2] = {0, 0};
    const int mid[3] = {(low[0] + high[0]) / 2, (low[1] + high[1]) / 2, (low[2] + high[2]) / 2};
    for (int i = 0; i < 16; ++i) {
        const int r = block[i * 4 + 2] - mid[2];
        withRed[0] += static_cast<long long>(block[i * 4 + 0] - mid[0]) * r;
        withRed[1] += static_cast<long long>(block[i * 4 + 1] - mid[1]) * r;
    }
    int a[3], b[3];   // blue, green, red of the two ends
    a[2] = high[2];
    b[2] = low[2];
    for (int c = 0; c < 2; ++c) {
        if (withRed[c] >= 0) { a[c] = high[c]; b[c] = low[c]; }
        else { a[c] = low[c]; b[c] = high[c]; }
    }
    auto to565 = [](const int* v) { return static_cast<uint16_t>(((v[2] * 31 + 127) / 255) << 11 | ((v[1] * 63 + 127) / 255) << 5 | ((v[0] * 31 + 127) / 255)); };
    uint16_t c0 = to565(a), c1 = to565(b);
    if (c0 < c1) {
        const uint16_t swap = c0;
        c0 = c1;
        c1 = swap;
    }
    uint32_t indices = 0;
    if (c0 != c1) {
        auto from565 = [](uint16_t v, int* outColour) {
            outColour[2] = ((v >> 11) & 31) * 255 / 31;
            outColour[1] = ((v >> 5) & 63) * 255 / 63;
            outColour[0] = (v & 31) * 255 / 31;
        };
        int palette[4][3];
        from565(c0, palette[0]);
        from565(c1, palette[1]);
        for (int c = 0; c < 3; ++c) {
            palette[2][c] = (2 * palette[0][c] + palette[1][c]) / 3;
            palette[3][c] = (palette[0][c] + 2 * palette[1][c]) / 3;
        }
        for (int i = 0; i < 16; ++i) {
            int best = 0;
            long bestError = -1;
            for (int k = 0; k < 4; ++k) {
                long error = 0;
                for (int c = 0; c < 3; ++c) {
                    const long d = block[i * 4 + c] - palette[k][c];
                    error += d * d;
                }
                if (bestError < 0 || error < bestError) {
                    bestError = error;
                    best = k;
                }
            }
            indices |= static_cast<uint32_t>(best) << (i * 2);
        }
    }
    out[0] = static_cast<uint8_t>(c0);
    out[1] = static_cast<uint8_t>(c0 >> 8);
    out[2] = static_cast<uint8_t>(c1);
    out[3] = static_cast<uint8_t>(c1 >> 8);
    for (int i = 0; i < 4; ++i) out[4 + i] = static_cast<uint8_t>(indices >> (i * 8));
}

// One level of a picture (rows of blue, green, red, opacity), packed.
std::vector<uint8_t> PackLevel(const std::vector<uint8_t>& level, uint32_t w, uint32_t h, Packing packing) {
    const uint32_t across = (w + 3) / 4, down = (h + 3) / 4;
    const size_t blockBytes = packing == Packing::Colour ? 8 : 16;
    std::vector<uint8_t> out(static_cast<size_t>(across) * down * blockBytes);
    for (uint32_t by = 0; by < down; ++by) {
        for (uint32_t bx = 0; bx < across; ++bx) {
            uint8_t block[64];
            for (uint32_t y = 0; y < 4; ++y) {
                const uint32_t sy = (std::min)(h - 1, by * 4 + y);
                for (uint32_t x = 0; x < 4; ++x) {
                    const uint32_t sx = (std::min)(w - 1, bx * 4 + x);   // past the edge: the edge again
                    std::memcpy(block + (y * 4 + x) * 4, level.data() + (static_cast<size_t>(sy) * w + sx) * 4, 4);
                }
            }
            uint8_t* to = out.data() + (static_cast<size_t>(by) * across + bx) * blockBytes;
            uint8_t channel[16];
            if (packing == Packing::Colour) {
                PackColour(block, to);
            } else if (packing == Packing::ColourOpacity) {
                for (int i = 0; i < 16; ++i) channel[i] = block[i * 4 + 3];
                PackChannel(channel, to);
                PackColour(block, to + 8);
            } else {   // a normal map: red, then green
                for (int i = 0; i < 16; ++i) channel[i] = block[i * 4 + 2];
                PackChannel(channel, to);
                for (int i = 0; i < 16; ++i) channel[i] = block[i * 4 + 1];
                PackChannel(channel, to + 8);
            }
        }
    }
    return out;
}

uint32_t WriteDdsWithMips(const fs::path& path, uint32_t width, uint32_t height, std::vector<uint8_t> level, Packing packing = Packing::Plain) {
    uint32_t levels = 1;
    for (uint32_t w = width, h = height; w > 1 || h > 1; w = (w > 1 ? w / 2 : 1), h = (h > 1 ? h / 2 : 1)) ++levels;
    std::error_code ec;
    fs::create_directories(Long(path.parent_path()), ec);
    std::ofstream out(Long(path), std::ios::binary | std::ios::trunc);
    if (!out) return 0;
    auto put = [&out](uint32_t v) { out.write(reinterpret_cast<const char*>(&v), 4); };
    out.write("DDS ", 4);
    if (packing == Packing::Plain) {
        put(124); put(0x2100F); put(height); put(width); put(width * 4); put(0); put(levels);
        for (int i = 0; i < 11; ++i) put(0);
        put(32); put(0x41); put(0); put(32); put(0x00FF0000); put(0x0000FF00); put(0x000000FF); put(0xFF000000);
        put(0x401008); put(0); put(0); put(0); put(0);
    } else {
        const uint32_t top = ((width + 3) / 4) * ((height + 3) / 4) * (packing == Packing::Colour ? 8u : 16u);
        put(124); put(0xA1007); put(height); put(width); put(top); put(0); put(levels);
        for (int i = 0; i < 11; ++i) put(0);
        put(32); put(0x4); out.write(packing == Packing::Colour ? "DXT1" : packing == Packing::ColourOpacity ? "DXT5" : "DX10", 4);
        put(0); put(0); put(0); put(0); put(0);
        put(0x401008); put(0); put(0); put(0); put(0);
        if (packing == Packing::Normal) {   // the longer header that names the format by number: 83 = two channels, 4 x 4 blocks
            put(83); put(3); put(0); put(1); put(0);
        }
    }
    uint32_t w = width, h = height;
    for (uint32_t n = 0; n < levels; ++n) {
        if (packing == Packing::Plain) {
            out.write(reinterpret_cast<const char*>(level.data()), static_cast<std::streamsize>(level.size()));
        } else {
            const std::vector<uint8_t> packed = PackLevel(level, w, h, packing);
            out.write(reinterpret_cast<const char*>(packed.data()), static_cast<std::streamsize>(packed.size()));
        }
        if (n + 1 == levels) break;
        const uint32_t nw = w > 1 ? w / 2 : 1, nh = h > 1 ? h / 2 : 1;
        std::vector<uint8_t> next(static_cast<size_t>(nw) * nh * 4);
        for (uint32_t y = 0; y < nh; ++y) {
            const uint32_t y0 = (h > 1) ? y * 2 : 0, y1 = (h > 1) ? y * 2 + 1 : 0;
            for (uint32_t x = 0; x < nw; ++x) {
                const uint32_t x0 = (w > 1) ? x * 2 : 0, x1 = (w > 1) ? x * 2 + 1 : 0;
                for (int c = 0; c < 4; ++c) {
                    const uint32_t sum = level[(static_cast<size_t>(y0) * w + x0) * 4 + c] + level[(static_cast<size_t>(y0) * w + x1) * 4 + c] +
                                         level[(static_cast<size_t>(y1) * w + x0) * 4 + c] + level[(static_cast<size_t>(y1) * w + x1) * 4 + c];
                    next[(static_cast<size_t>(y) * nw + x) * 4 + c] = static_cast<uint8_t>((sum + 2) / 4);
                }
            }
        }
        level.swap(next);
        w = nw;
        h = nh;
    }
    return out ? levels : 0;
}

int HostResource(lua_State* L) {
    const std::string name = luaL_checkstring(L, 1);
    if (name == "remasters.lua") {
        lua_pushlstring(L, reinterpret_cast<const char*>(kRemasters), sizeof(kRemasters));
        return 1;
    }
    if (name == "notice.script.lua") {
        lua_pushlstring(L, reinterpret_cast<const char*>(kNotice), sizeof(kNotice));
        return 1;
    }
    if (name == "font:IsothermSans-Bold.ttf") {
        lua_pushlstring(L, reinterpret_cast<const char*>(kIsothermSansBold), sizeof(kIsothermSansBold));
        return 1;
    }
    if (name != "station_shim.lua") return 0;
    lua_pushlstring(L, reinterpret_cast<const char*>(kStationShim), sizeof(kStationShim));
    return 1;
}

// host.paint(file, x0, y0, x1, y1, fromX, fromY): in a .dds picture of the output, what is inside the rectangle
// (points; top left first; the far edges not included) is painted over with what is at (fromX, fromY), in every
// mip level. Packed pictures are changed by whole 4 x 4 blocks, copied as they are: nothing is unpacked or
// packed again, so every packed format works alike. Only blocks wholly inside the rectangle are changed.
// Returns the number of blocks (or points) changed, or nothing when the file is not a .dds this can change.
int HostPaint(lua_State* L) {
    Job* job = JobOf(L);
    fs::path file = FromUtf8(luaL_checkstring(L, 1));
    if (!IsUnder(file, job->stage)) return luaL_error(L, "paint outside the output folder: %s", lua_tostring(L, 1));
    const lua_Integer x0 = luaL_checkinteger(L, 2), y0 = luaL_checkinteger(L, 3), x1 = luaL_checkinteger(L, 4), y1 = luaL_checkinteger(L, 5);
    const lua_Integer fromX = luaL_checkinteger(L, 6), fromY = luaL_checkinteger(L, 7);
    try {
        std::vector<uint8_t> data;
        {
            std::ifstream in(Long(file), std::ios::binary);
            if (!in) return 0;
            data.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
        }
        auto u32 = [&data](size_t at) -> uint32_t {
            return static_cast<uint32_t>(data[at]) | (static_cast<uint32_t>(data[at + 1]) << 8) | (static_cast<uint32_t>(data[at + 2]) << 16) | (static_cast<uint32_t>(data[at + 3]) << 24);
        };
        if (data.size() < 128 || std::memcmp(data.data(), "DDS ", 4) != 0) return 0;
        const uint32_t height = u32(12), width = u32(16);
        uint32_t levels = u32(28);
        if (levels == 0) levels = 1;
        const uint32_t formatFlags = u32(80), fourCC = u32(84), bitCount = u32(88);
        size_t offset = 128;
        uint32_t blockSide = 1, blockBytes = 0;
        auto code = [](const char* s) { return static_cast<uint32_t>(static_cast<unsigned char>(s[0])) | (static_cast<uint32_t>(static_cast<unsigned char>(s[1])) << 8) | (static_cast<uint32_t>(static_cast<unsigned char>(s[2])) << 16) | (static_cast<uint32_t>(static_cast<unsigned char>(s[3])) << 24); };
        if (formatFlags & 0x4) {   // a packed format, named by four letters
            blockSide = 4;
            if (fourCC == code("DXT1") || fourCC == code("ATI1") || fourCC == code("BC4U")) blockBytes = 8;
            else if (fourCC == code("DXT2") || fourCC == code("DXT3") || fourCC == code("DXT4") || fourCC == code("DXT5") || fourCC == code("ATI2") || fourCC == code("BC5U")) blockBytes = 16;
            else if (fourCC == code("DX10")) {
                if (data.size() < 148) return 0;
                offset = 148;
                const uint32_t dxgi = u32(128);
                if ((dxgi >= 70 && dxgi <= 72) || (dxgi >= 79 && dxgi <= 81)) blockBytes = 8;                       // BC1, BC4
                else if ((dxgi >= 73 && dxgi <= 78) || (dxgi >= 82 && dxgi <= 84) || (dxgi >= 94 && dxgi <= 99)) blockBytes = 16;   // BC2, BC3, BC5, BC6H, BC7
                else if (dxgi == 28 || dxgi == 29 || dxgi == 87 || dxgi == 88 || dxgi == 91 || dxgi == 93) { blockSide = 1; blockBytes = 4; }   // 8 bits a channel
                else return 0;
            } else return 0;
        } else {
            if (bitCount == 0 || bitCount % 8 != 0 || bitCount > 32) return 0;
            blockBytes = bitCount / 8;
        }
        if (width == 0 || height == 0 || x0 < 0 || y0 < 0 || x1 > width || y1 > height || x0 >= x1 || y0 >= y1 || fromX < 0 || fromY < 0 || fromX >= width || fromY >= height) return 0;
        lua_Integer changed = 0;
        for (uint32_t level = 0; level < levels; ++level) {
            const uint32_t w = (std::max)(1u, width >> level), h = (std::max)(1u, height >> level);
            const uint32_t across = (w + blockSide - 1) / blockSide, down = (h + blockSide - 1) / blockSide;
            const size_t size = static_cast<size_t>(across) * down * blockBytes;
            if (offset + size > data.size()) break;
            const uint32_t bx0 = ((static_cast<uint32_t>(x0) >> level) + blockSide - 1) / blockSide, bx1 = (static_cast<uint32_t>(x1) >> level) / blockSide;
            const uint32_t by0 = ((static_cast<uint32_t>(y0) >> level) + blockSide - 1) / blockSide, by1 = (static_cast<uint32_t>(y1) >> level) / blockSide;
            const uint32_t sx = (std::min)(across - 1, (static_cast<uint32_t>(fromX) >> level) / blockSide), sy = (std::min)(down - 1, (static_cast<uint32_t>(fromY) >> level) / blockSide);
            uint8_t source[16] = {};
            std::memcpy(source, data.data() + offset + (static_cast<size_t>(sy) * across + sx) * blockBytes, blockBytes);
            for (uint32_t by = by0; by < by1 && by < down; ++by) {
                for (uint32_t bx = bx0; bx < bx1 && bx < across; ++bx) {
                    std::memcpy(data.data() + offset + (static_cast<size_t>(by) * across + bx) * blockBytes, source, blockBytes);
                    ++changed;
                }
            }
            offset += size;
        }
        if (changed == 0) return 0;
        std::ofstream out(Long(file), std::ios::binary | std::ios::trunc);
        out.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
        if (!out) return 0;
        lua_pushinteger(L, changed);
        return 1;
    } catch (...) {
        return 0;
    }
}

int HostMakeMips(lua_State* L) {
    Job* job = JobOf(L);
    fs::path from = FromUtf8(luaL_checkstring(L, 1));
    fs::path to = FromUtf8(luaL_checkstring(L, 2));
    if (!IsUnder(from, job->source) || !IsUnder(to, job->stage)) return 0;
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> pixels;
    try {
        // a .tga, or a Radiance .hdr; for the latter a fourth value comes back: the brightest value in the
        // picture, which the written picture has as full white
        double peak = 0.0;
        std::string extension = ToUtf8(from.extension());
        for (char& c : extension) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        const bool hdr = extension == ".hdr";
        if (hdr ? !ReadHdr(from, &width, &height, &pixels, &peak) : !ReadTga(from, &width, &height, &pixels)) return 0;
        // Third argument "normal": the picture is a normal map. Where nothing was painted, some are left plain
        // grey or a dark blue, which does not say "flat" but "leaning hard to one side" (by red and green, the
        // two values the games read), and the surface is lit wrongly there. Grey, and anything that leans by
        // more than about 50 degrees, is made flat (rows are blue, green, red, opacity).
        long long flattened = 0;
        const char* use = lua_isstring(L, 3) ? lua_tostring(L, 3) : "";
        if (!hdr && std::strcmp(use, "normal") == 0) {
            for (size_t i = 0; i + 3 < pixels.size(); i += 4) {
                const int b = pixels[i], g = pixels[i + 1], r = pixels[i + 2];
                const int high = (std::max)(r, (std::max)(g, b)), low = (std::min)(r, (std::min)(g, b));
                const double x = (r - 128) / 127.0, y = (g - 128) / 127.0;
                if (high - low <= 8 || x * x + y * y > 0.6) {
                    pixels[i] = 255;
                    pixels[i + 1] = 128;
                    pixels[i + 2] = 128;
                    ++flattened;
                }
            }
        }
        const double flatShare = pixels.empty() ? 0.0 : static_cast<double>(flattened) / static_cast<double>(pixels.size() / 4);
        // packed as the game's own pictures are, when asked for: a normal map as two channels, a picture
        // with any opacity below full as colour with opacity, the rest as colour alone
        Packing packing = Packing::Plain;
        if (g_packTextures && width >= 4 && height >= 4) {
            if (std::strcmp(use, "normal") == 0) packing = Packing::Normal;
            else {
                packing = Packing::Colour;
                for (size_t i = 3; i < pixels.size(); i += 4) {
                    if (pixels[i] != 255) {
                        packing = Packing::ColourOpacity;
                        break;
                    }
                }
            }
        }
        const uint32_t levels = WriteDdsWithMips(to, width, height, std::move(pixels), packing);
        if (levels == 0) return 0;
        lua_pushinteger(L, width);
        lua_pushinteger(L, height);
        lua_pushinteger(L, levels);
        // fourth value: for a .hdr the brightest value in it; for a normal map the part of it that was grey
        lua_pushnumber(L, hdr ? peak : flatShare);
        return 4;
    } catch (...) {
        return 0;   // out of memory on a huge picture and the like: the caller copies the file as it is
    }
}

// host.alphaBands(file): how opaque a picture of the old mod is - sixteen numbers, the part of the picture whose
// opacity lies in each sixteenth from clear to solid. Read from a small mip level of a .dds (packed formats with
// an opacity of their own, or 32 bits a point) or from a .tga. Nothing when the picture has no such opacity.
int HostAlphaBands(lua_State* L) {
    Job* job = JobOf(L);
    fs::path file = FromUtf8(luaL_checkstring(L, 1));
    if (!IsUnder(file, job->source)) return 0;
    try {
        uint64_t bands[16] = {};
        uint64_t total = 0;
        std::string extension = ToUtf8(file.extension());
        for (char& c : extension) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (extension == ".tga") {
            uint32_t width = 0, height = 0;
            std::vector<uint8_t> pixels;
            if (!ReadTga(file, &width, &height, &pixels)) return 0;
            const size_t step = (std::max<size_t>)(1, (static_cast<size_t>(width) * height) / 262144);
            for (size_t i = 0; i + 3 < pixels.size(); i += 4 * step) { ++bands[pixels[i + 3] >> 4]; ++total; }
        } else {
            std::vector<uint8_t> data;
            {
                std::ifstream in(Long(file), std::ios::binary);
                if (!in) return 0;
                data.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
            }
            auto u32 = [&data](size_t at) -> uint32_t {
                return static_cast<uint32_t>(data[at]) | (static_cast<uint32_t>(data[at + 1]) << 8) | (static_cast<uint32_t>(data[at + 2]) << 16) | (static_cast<uint32_t>(data[at + 3]) << 24);
            };
            if (data.size() < 128 || std::memcmp(data.data(), "DDS ", 4) != 0) return 0;
            const uint32_t height = u32(12), width = u32(16);
            uint32_t levels = u32(28);
            if (levels == 0) levels = 1;
            const uint32_t formatFlags = u32(80), bitCount = u32(88);
            const std::string fourCC(reinterpret_cast<const char*>(data.data()) + 84, 4);
            size_t offset = 128;
            int kind = 0;   // 2: opacity in 16 steps a point (BC2), 3: two ends and steps between (BC3), 4: 32 bits a point
            if (formatFlags & 0x4) {
                if (fourCC == "DXT2" || fourCC == "DXT3") kind = 2;
                else if (fourCC == "DXT4" || fourCC == "DXT5") kind = 3;
                else if (fourCC == "DX10" && data.size() >= 148) {
                    offset = 148;
                    const uint32_t dxgi = u32(128);
                    if (dxgi >= 73 && dxgi <= 75) kind = 2;
                    else if (dxgi >= 76 && dxgi <= 78) kind = 3;
                    else if (dxgi == 28 || dxgi == 29 || dxgi == 87 || dxgi == 91) kind = 4;
                }
            } else if (bitCount == 32 && (formatFlags & 0x1)) {
                kind = 4;
            }
            if (kind == 0 || width == 0 || height == 0) return 0;
            const uint32_t side = kind == 4 ? 1 : 4;
            const size_t bytes = kind == 4 ? 4 : 16;
            for (uint32_t level = 0; level < levels; ++level) {
                const uint32_t w = (std::max)(1u, width >> level), h = (std::max)(1u, height >> level);
                const size_t across = (w + side - 1) / side, down = (h + side - 1) / side;
                const size_t size = across * down * bytes;
                if (offset + size > data.size()) break;
                // the first level of at most 512 points a side (or the last there is): enough to tell
                if ((std::max)(w, h) <= 512 || level + 1 == levels) {
                    for (size_t block = 0; block < across * down; ++block) {
                        const uint8_t* p = data.data() + offset + block * bytes;
                        if (kind == 4) {
                            ++bands[p[3] >> 4];
                            ++total;
                        } else if (kind == 2) {
                            for (int i = 0; i < 16; ++i) { ++bands[(p[i / 2] >> ((i & 1) * 4)) & 0xF]; ++total; }
                        } else {
                            uint32_t ends[8] = { p[0], p[1] };
                            if (ends[0] > ends[1]) {
                                for (uint32_t i = 1; i <= 6; ++i) ends[1 + i] = ((7 - i) * ends[0] + i * ends[1]) / 7;
                            } else {
                                for (uint32_t i = 1; i <= 4; ++i) ends[1 + i] = ((5 - i) * ends[0] + i * ends[1]) / 5;
                                ends[6] = 0;
                                ends[7] = 255;
                            }
                            uint64_t bits = 0;
                            for (int i = 0; i < 6; ++i) bits |= static_cast<uint64_t>(p[2 + i]) << (8 * i);
                            for (int i = 0; i < 16; ++i) { ++bands[ends[(bits >> (3 * i)) & 7] >> 4]; ++total; }
                        }
                    }
                    break;
                }
                offset += size;
            }
        }
        if (total == 0) return 0;
        lua_createtable(L, 16, 0);
        for (int i = 0; i < 16; ++i) {
            lua_pushnumber(L, static_cast<double>(bands[i]) / static_cast<double>(total));
            lua_rawseti(L, -2, i + 1);
        }
        return 1;
    } catch (...) {
        return 0;
    }
}

// What the old mod looked like when it was converted: number of files, their total size, the newest change.
std::string Fingerprint(const fs::path& folder) {
    std::error_code ec;
    uint64_t count = 0, bytes = 0;
    int64_t newest = 0;
    for (fs::recursive_directory_iterator it(Long(folder), fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
        std::error_code e2;
        if (!it->is_regular_file(e2)) continue;
        ++count;
        bytes += it->file_size(e2);
        auto time = it->last_write_time(e2).time_since_epoch().count();
        if (!e2 && static_cast<int64_t>(time) > newest) newest = static_cast<int64_t>(time);
    }
    // ... and which rules converted it, so that better rules convert it again
    uint32_t rules = 2166136261u;
    for (unsigned char c : kRules) rules = (rules ^ c) * 16777619u;
    for (unsigned char c : kStationShim) rules = (rules ^ c) * 16777619u;
    if (g_remasters) for (unsigned char c : kRemasters) rules = (rules ^ c) * 16777619u;
    for (unsigned char c : kNotice) rules = (rules ^ c) * 16777619u;
    rules = (rules ^ (g_glassParts ? 4u : 0u)) * 16777619u;
    rules = (rules ^ (g_packTextures ? 8u : 0u)) * 16777619u;
    rules = (rules ^ (g_labelFont ? 16u : 0u)) * 16777619u;
    rules = (rules ^ (g_stations ? 1u : 0u)) * 16777619u;
    rules = (rules ^ (g_stationDebug ? 2u : 0u)) * 16777619u;
    // ... and which other old mods were there: a mod that uses another's files converts differently with it
    rules = (rules ^ g_inboxHash) * 16777619u;
    return std::to_string(count) + "/" + std::to_string(bytes) + "/" + std::to_string(newest) + "/" + std::to_string(rules);
}

struct Done {
    std::string fingerprint;
    std::string modId;
};

std::map<std::string, Done> ReadState(const fs::path& file) {
    std::map<std::string, Done> state;
    std::ifstream in(file, std::ios::binary);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t a = line.find('\t');
        size_t b = a == std::string::npos ? a : line.find('\t', a + 1);
        if (b == std::string::npos) continue;
        state[line.substr(b + 1)] = Done{ line.substr(0, a), line.substr(a + 1, b - a - 1) };
    }
    return state;
}

void WriteState(const fs::path& file, const std::map<std::string, Done>& state) {
    std::ofstream out(file, std::ios::binary | std::ios::trunc);
    for (const auto& [folder, done] : state) out << done.fingerprint << '\t' << done.modId << '\t' << folder << '\n';
}

// Runs the rules on one old mod. On success fills modId and summary and leaves the result in "stage".
bool ConvertOne(const fs::path& source, const fs::path& stage, const std::string& folderName, std::string* modId, std::string* summary) {
    Job job{ source, stage };
    lua_State* L = luaL_newstate();
    if (!L) {
        *summary = "no memory for the interpreter";
        return false;
    }
    // only what the rules need: no file, system or debug libraries - files go through the host functions above
    luaL_requiref(L, "_G", luaopen_base, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
    lua_settop(L, 0);
    for (const char* name : { "dofile", "loadfile" }) {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }

    bool ok = false;
    if (luaL_loadbuffer(L, reinterpret_cast<const char*>(kRules), sizeof(kRules), "=convert.lua") != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK) {
        *summary = std::string("the rules do not load: ") + (lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
    } else {
        lua_getfield(L, -1, "convertMod");
        lua_newtable(L);
        const luaL_Reg functions[] = { { "list", HostList }, { "read", HostRead }, { "readHead", HostReadHead }, { "write", HostWrite }, { "copy", HostCopy },
                                         { "makeMips", HostMakeMips }, { "resource", HostResource }, { "siblings", HostSiblings },
                                         { "paint", HostPaint }, { "alphaBands", HostAlphaBands } };
        for (const luaL_Reg& f : functions) {
            lua_pushlightuserdata(L, &job);
            lua_pushcclosure(L, f.func, 1);
            lua_setfield(L, -2, f.name);
        }
        std::string src = ToUtf8(source), dst = ToUtf8(stage);
        lua_pushlstring(L, src.data(), src.size());
        lua_pushlstring(L, dst.data(), dst.size());
        lua_pushlstring(L, folderName.data(), folderName.size());
        lua_newtable(L);
        lua_pushboolean(L, g_stations);
        lua_setfield(L, -2, "stations");
        lua_pushboolean(L, g_stationDebug);
        lua_setfield(L, -2, "stationDebug");
        lua_pushboolean(L, g_remasters);
        lua_setfield(L, -2, "remasters");
        lua_pushboolean(L, g_glassParts);
        lua_setfield(L, -2, "glassParts");
        lua_pushboolean(L, g_labelFont);
        lua_setfield(L, -2, "labelFont");
        if (lua_pcall(L, 5, 1, 0) != LUA_OK) {
            *summary = std::string("the conversion stopped: ") + (lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
        } else if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "modId");
            if (const char* id = lua_tostring(L, -1)) *modId = id;
            lua_pop(L, 1);
            auto count = [L](const char* table, const char* field) -> long long {
                long long n = 0;
                lua_getfield(L, -1, table);
                if (lua_istable(L, -1)) {
                    if (field) {
                        lua_getfield(L, -1, field);
                        n = static_cast<long long>(lua_tointeger(L, -1));
                        lua_pop(L, 1);
                    } else {
                        n = static_cast<long long>(lua_rawlen(L, -1));
                    }
                }
                lua_pop(L, 1);
                return n;
            };
            std::ostringstream text;
            text << count("counts", "models") << " models, " << count("counts", "materials") << " materials, "
                 << count("counts", "textures") << " textures; " << count("problems", nullptr) << " problems, "
                 << count("missing", nullptr) << " missing files";
            *summary = text.str();
            lua_getfield(L, -1, "empty");
            bool empty = lua_toboolean(L, -1) != 0;
            lua_pop(L, 1);
            ok = !modId->empty() && !empty;
            if (empty) *summary = "nothing in it that the converter handles (no res/models or res/textures files)";
            else if (!ok) *summary = "the rules gave no mod id";
        } else {
            *summary = "the rules gave no report";
        }
    }
    lua_close(L);
    return ok;
}

bool SafeModId(const std::string& id) {
    if (id.empty() || id.size() > 120) return false;
    for (char c : id) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
    }
    return true;
}

} // namespace

const char* EmbeddedRules(size_t* size) {
    if (size) *size = sizeof(kRules);
    return reinterpret_cast<const char*>(kRules);
}

Result Run(const fs::path& gameDir, const LogFn& log, bool stations, bool stationDebug, bool remasters, bool glassParts, bool packTextures,
           bool labelFont) {
    Result result;
    g_stations = stations;
    g_stationDebug = stationDebug;
    g_remasters = remasters;
    g_glassParts = glassParts;
    g_packTextures = packTextures;
    g_labelFont = labelFont;
    auto say = [&log](const std::string& text) { if (log) log(text); };
    try {
        std::error_code ec;
        fs::path inbox = Long(gameDir / kInboxName);
        fs::create_directories(inbox, ec);
        if (ec) {
            say("mod converter: cannot create " + ToUtf8(inbox) + ": " + ec.message());
            return result;
        }
        fs::path stateFile = inbox / kStateName;
        fs::path stage = inbox / kStageName;
        fs::path mods = Long(gameDir / "mods" / "release");
        std::map<std::string, Done> state = ReadState(stateFile);
        bool stateChanged = false;

        std::vector<fs::path> folders;
        for (fs::directory_iterator it(inbox, ec), end; !ec && it != end; it.increment(ec)) {
            std::error_code e2;
            if (!it->is_directory(e2)) continue;
            std::string name = ToUtf8(it->path().filename());
            if (name.empty() || name[0] == '.') continue;
            folders.push_back(it->path());
        }
        result.found = static_cast<int>(folders.size());
        std::sort(folders.begin(), folders.end());
        g_inbox = folders;
        g_inboxHash = 2166136261u;
        for (const fs::path& folder : folders) {
            for (unsigned char c : ToUtf8(folder.filename())) g_inboxHash = (g_inboxHash ^ c) * 16777619u;
            g_inboxHash = (g_inboxHash ^ 0x2Fu) * 16777619u;
        }

        for (const fs::path& folder : folders) {
            std::string name = ToUtf8(folder.filename());
            std::string print = Fingerprint(folder);
            auto known = state.find(name);
            if (known != state.end() && known->second.fingerprint == print && fs::exists(mods / known->second.modId / "mod.json", ec)) {
                ++result.upToDate;
                continue;
            }
            fs::remove_all(stage, ec);
            std::string modId, summary;
            if (!ConvertOne(folder, stage, name, &modId, &summary) || !SafeModId(modId)) {
                ++result.failed;
                say("mod converter: \"" + name + "\" not converted - " + summary);
                fs::remove_all(stage, ec);
                continue;
            }
            fs::path target = mods / modId;
            if (fs::exists(target, ec)) {
                // only ever replace a folder an earlier conversion made
                if (!fs::exists(target / "conversion_report.txt", ec)) {
                    ++result.failed;
                    say("mod converter: \"" + name + "\" not converted - mods/release/" + modId + " exists and was not made by the converter");
                    fs::remove_all(stage, ec);
                    continue;
                }
                fs::remove_all(target, ec);
            }
            fs::create_directories(mods, ec);
            fs::rename(stage, target, ec);
            if (ec) {
                ++result.failed;
                say("mod converter: \"" + name + "\" converted but could not be moved to mods/release/" + modId + ": " + ec.message());
                fs::remove_all(stage, ec);
                continue;
            }
            state[name] = Done{ print, modId };
            stateChanged = true;
            ++result.converted;
            say("mod converter: \"" + name + "\" -> mods/release/" + modId + " (" + summary + "); see conversion_report.txt there");
        }
        if (stateChanged) WriteState(stateFile, state);
        if (result.found > 0) {
            say("mod converter: " + std::to_string(result.found) + " old mods in legacy_mods - " + std::to_string(result.converted) + " converted now, " +
                std::to_string(result.upToDate) + " already done, " + std::to_string(result.failed) + " failed");
        }
    } catch (const std::exception& e) {
        say(std::string("mod converter: stopped - ") + e.what());
    } catch (...) {
        say("mod converter: stopped for an unknown reason");
    }
    return result;
}

} // namespace tf3api::mod_converter
