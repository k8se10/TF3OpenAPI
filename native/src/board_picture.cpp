#include "boards.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

// The picture of a departure board's screen: which dots are lit for given lines of text, and the points of
// the texture for those dots. Kept apart from the Vulkan side so that it can be tested by itself: what it
// paints must equal, byte for byte, the picture tools/build_boards.py ships with the mod.

namespace tf3api::boards {
namespace {

// ---- The picture ----------------------------------------------------------------------------------------
// Must give the same picture as tools/build_boards.py, which draws the one the mod ships with.

const uint8_t kBoardFont[95][5] = {
#include "board_font.inc"
};
constexpr int kFontHeight = 7, kFontGap = 1, kFontSpace = 3;
constexpr int kLineTops[kTextLines] = {4, 15, 26};
constexpr int kClockTop = 38;
constexpr uint8_t kUnlit[3] = {30, 17, 4};    // red, green, blue of a dark dot
constexpr uint8_t kLit[3] = {255, 150, 24};   // of a lit one: amber

// The columns of a line of text: each a 7-bit number, lowest bit at the top. A character's empty side
// columns are dropped, one dark column stands between two characters, a space is three.
void LineColumns(const char* text, std::vector<uint8_t>* out) {
    out->clear();
    if (text == nullptr) return;
    bool first = true;
    for (const char* p = text; *p != 0; ++p) {
        if (!first) out->insert(out->end(), kFontGap, 0);
        first = false;
        unsigned char c = static_cast<unsigned char>(*p);
        if (c == ' ') {
            out->insert(out->end(), kFontSpace, 0);
            continue;
        }
        if (c < 32 || c > 126) c = '?';
        const uint8_t* columns = kBoardFont[c - 32];
        int from = 0, to = 5;
        while (from < to && columns[from] == 0) ++from;
        while (to > from && columns[to - 1] == 0) --to;
        if (from == to) out->push_back(0);
        for (int i = from; i < to; ++i) out->push_back(columns[i]);
    }
}

// Lights the columns from `left` on, never at or beyond `limit`.
void PutColumns(const std::vector<uint8_t>& columns, int left, int limit, int top, std::vector<uint8_t>* dots) {
    const int count = static_cast<int>(columns.size());
    limit = (std::min)(limit, kColumns);
    for (int i = 0; i < count && left + i < limit; ++i) {
        if (left + i < 0) continue;
        for (int row = 0; row < kFontHeight; ++row) {
            if ((columns[i] >> row) & 1) (*dots)[static_cast<size_t>(top + row) * kColumns + left + i] = 1;
        }
    }
}

// where the parts of a departure line stand (columns of dots)
constexpr int kTimeLeft = 2, kDestinationLeft = 34, kPlatformRight = 198, kExpectedRight = 238, kFieldGap = 3;

void PutLine(const char* text, int top, std::vector<uint8_t>* dots) {
    std::vector<uint8_t> columns;
    if (std::strchr(text, '\t') == nullptr) {
        // an ordinary line: centred
        LineColumns(text, &columns);
        const int count = static_cast<int>(columns.size());
        PutColumns(columns, (std::max)(0, (kColumns - count) / 2), kColumns, top, dots);
        return;
    }
    // a departure: time, destination, platform, expected
    std::string fields[4];
    int field = 0;
    for (const char* p = text; *p != 0; ++p) {
        if (*p == '\t') {
            if (field < 3) ++field;
            continue;
        }
        fields[field].push_back(*p);
    }
    std::vector<uint8_t> expected, platform;
    LineColumns(fields[3].c_str(), &expected);
    LineColumns(fields[2].c_str(), &platform);
    const int expectedLeft = kExpectedRight - static_cast<int>(expected.size());
    // the platform keeps its place, unless the expected time is long enough to need the room
    const int platformRight = (std::min)(kPlatformRight, expectedLeft - kFieldGap);
    const int platformLeft = platformRight - static_cast<int>(platform.size());
    PutColumns(expected, expectedLeft, kColumns, top, dots);
    PutColumns(platform, platformLeft, kColumns, top, dots);
    LineColumns(fields[0].c_str(), &columns);
    PutColumns(columns, kTimeLeft, kDestinationLeft - 1, top, dots);
    LineColumns(fields[1].c_str(), &columns);
    // a long destination is cut off before the platform
    PutColumns(columns, kDestinationLeft, (platform.empty() ? expectedLeft : platformLeft) - kFieldGap, top, dots);
}

} // namespace

void Compose(const char* const* lines, int count, const char* clock, std::vector<uint8_t>* dots) {
    dots->assign(static_cast<size_t>(kRows) * kColumns, 0);
    for (int i = 0; i < count && i < kTextLines; ++i) {
        if (lines[i] != nullptr && lines[i][0] != 0) PutLine(lines[i], kLineTops[i], dots);
    }
    if (clock != nullptr && clock[0] != 0) PutLine(clock, kClockTop, dots);
}

void Paint(const std::vector<uint8_t>& dots, std::vector<uint8_t>* pixels, std::vector<size_t>* levelOffsets) {
    Paint(dots, kWidth, kHeight, pixels, levelOffsets);
}

void Paint(const std::vector<uint8_t>& dots, int width, int height, std::vector<uint8_t>* pixels, std::vector<size_t>* levelOffsets) {
    width = (std::max)(width, static_cast<int>(kWidth));
    height = (std::max)(height, static_cast<int>(kHeight));
    // one dot, once: how much of each point of its block the round dot covers, for a dark and a lit dot
    uint8_t stamp[2][kDot * kDot * 4];
    const double middle = (kDot - 1) / 2.0, radius = kDot * 0.36;
    for (int y = 0; y < kDot; ++y) {
        for (int x = 0; x < kDot; ++x) {
            const double d = std::hypot(x - middle, y - middle);
            const double cover = (std::max)(0.0, (std::min)(1.0, radius + 0.5 - d));
            for (int lit = 0; lit < 2; ++lit) {
                const uint8_t* colour = lit ? kLit : kUnlit;
                uint8_t* p = stamp[lit] + (y * kDot + x) * 4;
                p[0] = static_cast<uint8_t>(colour[2] * cover);   // blue
                p[1] = static_cast<uint8_t>(colour[1] * cover);
                p[2] = static_cast<uint8_t>(colour[0] * cover);   // red
                p[3] = 255;
            }
        }
    }
    size_t total = 0;
    levelOffsets->clear();
    for (int w = width, h = height;; w = (std::max)(1, w / 2), h = (std::max)(1, h / 2)) {
        levelOffsets->push_back(total);
        total += static_cast<size_t>(w) * h * 4;
        if (w == 1 && h == 1) break;
    }
    pixels->assign(total, 0);
    uint8_t* top = pixels->data();
    if (width > kWidth || height > kHeight) {   // the margin: black
        for (size_t i = 3; i < static_cast<size_t>(width) * height * 4; i += 4) top[i] = 255;
    }
    for (int row = 0; row < kRows; ++row) {
        for (int column = 0; column < kColumns; ++column) {
            const uint8_t* from = stamp[dots[static_cast<size_t>(row) * kColumns + column] ? 1 : 0];
            for (int y = 0; y < kDot; ++y) {
                std::memcpy(top + (static_cast<size_t>(row * kDot + y) * width + column * kDot) * 4, from + y * kDot * 4, kDot * 4);
            }
        }
    }
    int w = width, h = height;
    for (size_t level = 1; level < levelOffsets->size(); ++level) {
        const uint8_t* big = pixels->data() + (*levelOffsets)[level - 1];
        uint8_t* small = pixels->data() + (*levelOffsets)[level];
        const int nw = (std::max)(1, w / 2), nh = (std::max)(1, h / 2);
        for (int y = 0; y < nh; ++y) {
            const int y0 = (std::min)(h - 1, y * 2), y1 = (std::min)(h - 1, y * 2 + 1);
            for (int x = 0; x < nw; ++x) {
                const int x0 = (std::min)(w - 1, x * 2), x1 = (std::min)(w - 1, x * 2 + 1);
                for (int k = 0; k < 4; ++k) {
                    const int sum = big[(static_cast<size_t>(y0) * w + x0) * 4 + k] + big[(static_cast<size_t>(y0) * w + x1) * 4 + k] +
                                    big[(static_cast<size_t>(y1) * w + x0) * 4 + k] + big[(static_cast<size_t>(y1) * w + x1) * 4 + k];
                    small[(static_cast<size_t>(y) * nw + x) * 4 + k] = static_cast<uint8_t>((sum + 2) / 4);
                }
            }
        }
        w = nw;
        h = nh;
    }
}

} // namespace tf3api::boards
