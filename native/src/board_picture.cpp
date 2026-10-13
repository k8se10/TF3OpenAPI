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

constexpr int kRowTops[kRowLines] = {1, 11, 21, 31, 41};

void HideFrom(bool rows, int line, int column, std::vector<uint8_t>* dots) {
    if (line < 0 || line >= (rows ? kRowLines : kTextLines) || dots->size() < static_cast<size_t>(kRows) * kColumns) return;
    const int top = rows ? kRowTops[line] : kLineTops[line];
    column = (std::max)(0, column);
    for (int row = top; row < top + kFontHeight && row < kRows; ++row) {
        for (int c = column; c < kColumns; ++c) (*dots)[static_cast<size_t>(row) * kColumns + c] = 0;
    }
}

namespace {

// A field of a row, laid out: its dots, where it begins, the column it must stay before, and whether it
// scrolls when it does not fit (a field written with a leading "~").
struct Field {
    std::vector<uint8_t> columns;
    int left = 0, limit = kColumns;
    bool scroll = false;
};
constexpr int kScrollGap = 40;   // dark columns between the end of a scrolling text and its start again

int LayRow(const char* row, const char* clock, Field* fields, int most) {
    int fieldCount = 0;
    const char* p = row;
    while (fieldCount < most) {
        std::string text;
        while (*p != 0 && *p != '\t') {
            if (*p == 1) text += (clock != nullptr ? clock : "--:--:--");
            else text.push_back(*p);
            ++p;
        }
        Field& field = fields[fieldCount++];
        field = Field();
        if (!text.empty() && text[0] == '~') {
            field.scroll = true;
            text.erase(0, 1);
        }
        int align = 0, at = 0;   // 0 centred, 1 left edge at, 2 right edge at
        if (text.size() >= 2 && (text[0] == '<' || text[0] == '>') && text[1] >= '0' && text[1] <= '9') {
            align = text[0] == '<' ? 1 : 2;
            size_t i = 1;
            while (i < text.size() && text[i] >= '0' && text[i] <= '9' && at < 1000) at = at * 10 + (text[i++] - '0');
            if (i < text.size() && text[i] == ' ') ++i;
            text.erase(0, i);
        }
        LineColumns(text.c_str(), &field.columns);
        const int width = static_cast<int>(field.columns.size());
        field.left = align == 1 ? at : (align == 2 ? at - width : (kColumns - width) / 2);
        if (field.scroll && align == 0 && width > kColumns) field.left = 0;
        if (*p == 0) break;
        ++p;
    }
    for (int i = 0; i < fieldCount; ++i) {
        // not into the nearest field that begins to its right
        for (int j = 0; j < fieldCount; ++j) {
            if (j != i && !fields[j].columns.empty() && fields[j].left > fields[i].left) {
                fields[i].limit = (std::min)(fields[i].limit, fields[j].left - kFieldGap);
            }
        }
    }
    return fieldCount;
}

bool Scrolls(const Field& field) {
    return field.scroll && static_cast<int>(field.columns.size()) > field.limit - (std::max)(0, field.left);
}

} // namespace

bool RowScrolls(const char* row) {
    if (row == nullptr || row[0] == 0) return false;
    Field fields[8];
    const int count = LayRow(row, nullptr, fields, 8);
    for (int i = 0; i < count; ++i) {
        if (Scrolls(fields[i])) return true;
    }
    return false;
}

void ComposeRows(const char* const* rows, int count, const char* clock, std::vector<uint8_t>* dots) {
    ComposeRows(rows, count, clock, nullptr, dots);
}

void ComposeRows(const char* const* rows, int count, const char* clock, const int* scroll, std::vector<uint8_t>* dots) {
    dots->assign(static_cast<size_t>(kRows) * kColumns, 0);
    for (int r = 0; r < count && r < kRowLines; ++r) {
        if (rows[r] == nullptr || rows[r][0] == 0) continue;
        Field fields[8];
        const int fieldCount = LayRow(rows[r], clock, fields, 8);
        for (int i = 0; i < fieldCount; ++i) {
            const Field& field = fields[i];
            if (!Scrolls(field)) {
                PutColumns(field.columns, field.left, field.limit, kRowTops[r], dots);
                continue;
            }
            // too long for its room: the text runs past, round and round, `scroll` columns along
            const int left = (std::max)(0, field.left);
            const int room = field.limit - left;
            const int width = static_cast<int>(field.columns.size());
            const int period = width + kScrollGap;
            const int offset = scroll != nullptr && scroll[r] > 0 ? scroll[r] % period : 0;
            std::vector<uint8_t> window(static_cast<size_t>((std::max)(0, room)), 0);
            for (int c = 0; c < room; ++c) {
                const int from = (offset + c) % period;
                if (from < width) window[static_cast<size_t>(c)] = field.columns[static_cast<size_t>(from)];
            }
            PutColumns(window, left, field.limit, kRowTops[r], dots);
        }
    }
}

void Paint(const std::vector<uint8_t>& dots, std::vector<uint8_t>* pixels, std::vector<size_t>* levelOffsets) {
    Paint(dots, kWidth, kHeight, pixels, levelOffsets);
}

void Paint(const std::vector<uint8_t>& dots, int width, int height, std::vector<uint8_t>* pixels, std::vector<size_t>* levelOffsets) {
    Paint(dots, width, height, kLit, pixels, levelOffsets);
}

void Paint(const std::vector<uint8_t>& dots, int width, int height, const uint8_t lit[3], std::vector<uint8_t>* pixels,
           std::vector<size_t>* levelOffsets) {
    // the dark dots: the shipped shade for amber, otherwise an eighth of the lit colour
    uint8_t unlit[3] = {kUnlit[0], kUnlit[1], kUnlit[2]};
    if (lit[0] != kLit[0] || lit[1] != kLit[1] || lit[2] != kLit[2]) {
        for (int k = 0; k < 3; ++k) unlit[k] = static_cast<uint8_t>(lit[k] / 8);
    }
    width = (std::max)(width, static_cast<int>(kWidth));
    height = (std::max)(height, static_cast<int>(kHeight));
    // one dot, once: how much of each point of its block the round dot covers, for a dark and a lit dot
    uint8_t stamp[2][kDot * kDot * 4];
    const double middle = (kDot - 1) / 2.0, radius = kDot * 0.36;
    for (int y = 0; y < kDot; ++y) {
        for (int x = 0; x < kDot; ++x) {
            const double d = std::hypot(x - middle, y - middle);
            const double cover = (std::max)(0.0, (std::min)(1.0, radius + 0.5 - d));
            for (int on = 0; on < 2; ++on) {
                const uint8_t* colour = on ? lit : unlit;
                uint8_t* p = stamp[on] + (y * kDot + x) * 4;
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
