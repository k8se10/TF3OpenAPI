// Checks that the native layer paints a board's screen exactly as the mod's shipped picture is painted.
//
//   board_picture_test.exe <repository root>
//
// The shipped picture (mod/tf3api_departure_boards/.../screen_00.dds, made by tools/build_boards.py) shows
// the resting message and "--:--:--". The same lines painted by the native code must give the same bytes,
// every mip level included: then what is written live and what a board shows without the layer are one
// picture, and the two fonts cannot drift apart unnoticed.
#include "boards.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("usage: board_picture_test <repository root>\n");
        return 2;
    }
    const std::string path = std::string(argv[1]) + "/mod/tf3api_departure_boards/content/textures/tf3api_departure_boards/screen_00.dds";
    std::ifstream in(path, std::ios::binary);
    std::vector<unsigned char> file((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (file.size() < 128) {
        printf("cannot read %s\n", path.c_str());
        return 2;
    }
    const char* lines[3] = {"TF3OpenAPI", "Departure information unavailable", "github.com/k8se10/TF3OpenAPI"};
    std::vector<uint8_t> dots, pixels;
    std::vector<size_t> offsets;
    tf3api::boards::Compose(lines, 3, "--:--:--", &dots);
    tf3api::boards::Paint(dots, &pixels, &offsets);
    int failed = 0;
    if (pixels.size() != file.size() - 128) {
        printf("FAILED: %zu bytes painted, the file holds %zu\n", pixels.size(), file.size() - 128);
        ++failed;
    } else {
        size_t different = 0, first = 0;
        for (size_t i = 0; i < pixels.size(); ++i) {
            if (pixels[i] != file[128 + i]) {
                if (different == 0) first = i;
                ++different;
            }
        }
        if (different != 0) {
            printf("FAILED: %zu bytes differ from the shipped picture, the first at %zu\n", different, first);
            ++failed;
        }
    }
    // another screen: the same dots in a larger texture, as its shipped file has them
    {
        const int slot = 13;
        const std::string other = std::string(argv[1]) + "/mod/tf3api_departure_boards/content/textures/tf3api_departure_boards/screen_13.dds";
        std::ifstream in2(other, std::ios::binary);
        std::vector<unsigned char> file2((std::istreambuf_iterator<char>(in2)), std::istreambuf_iterator<char>());
        std::vector<uint8_t> pixels2;
        std::vector<size_t> offsets2;
        tf3api::boards::Paint(dots, tf3api::boards::SlotWidth(slot), tf3api::boards::SlotHeight(slot), &pixels2, &offsets2);
        if (file2.size() < 128) {
            printf("screen 13: file not there (run tools/build_boards.py) - not compared\n");
        } else if (pixels2.size() != file2.size() - 128 || memcmp(pixels2.data(), file2.data() + 128, pixels2.size()) != 0) {
            printf("FAILED: screen 13 painted (%zu bytes) is not its shipped picture (%zu bytes)\n", pixels2.size(), file2.size() - 128);
            ++failed;
        }
        // a departure line lights the left and the right of the board and leaves the middle gap dark
        const char* departure[3] = {"13:45\tLiverpool Lime Street\t6B\tOn time", "", ""};
        std::vector<uint8_t> d;
        tf3api::boards::Compose(departure, 3, nullptr, &d);
        size_t left = 0, right = 0, far = 0;
        for (int row = 0; row < 14; ++row) {
            for (int c = 0; c < 30; ++c) left += d[static_cast<size_t>(row) * tf3api::boards::kColumns + c];
            for (int c = 200; c < 240; ++c) right += d[static_cast<size_t>(row) * tf3api::boards::kColumns + c];
            for (int c = 238; c < 240; ++c) far += d[static_cast<size_t>(row) * tf3api::boards::kColumns + c];
        }
        if (left == 0 || right == 0 || far != 0) {
            printf("FAILED: departure line layout (left %zu, right %zu, beyond the edge %zu)\n", left, right, far);
            ++failed;
        }
    }
    // rows laid out by the script: fields at their places, the clock put in, no field running into the next
    {
        const char* rows[5] = {"<2 DEPARTURES\t>238 \x01", "<2 A very long destination name that would run on and on\t<124 IC 2\t>204 12\t>238 13:50", "", "", "Penryn"};
        std::vector<uint8_t> d;
        tf3api::boards::ComposeRows(rows, 5, "12:34:56", &d);
        const auto litIn = [&](int row0, int row1, int c0, int c1) {
            size_t n = 0;
            for (int row = row0; row < row1; ++row) for (int c = c0; c < c1; ++c) n += d[static_cast<size_t>(row) * tf3api::boards::kColumns + c];
            return n;
        };
        std::vector<uint8_t> other;
        tf3api::boards::ComposeRows(rows, 5, "12:34:57", &other);
        if (litIn(1, 8, 2, 60) == 0 || litIn(1, 8, 200, 238) == 0 || litIn(1, 8, 238, 240) != 0 || litIn(1, 8, 0, 2) != 0) {
            printf("FAILED: heading row (left %zu, clock %zu)\n", litIn(1, 8, 2, 60), litIn(1, 8, 200, 238));
            ++failed;
        }
        if (litIn(11, 18, 121, 124) != 0 || litIn(11, 18, 2, 121) == 0 || litIn(11, 18, 124, 150) == 0) {
            printf("FAILED: a long destination ran into the line's name\n");
            ++failed;
        }
        if (litIn(41, 48, 100, 140) == 0 || litIn(41, 48, 0, 60) != 0 || litIn(21, 38, 0, 240) != 0) {
            printf("FAILED: the centred footer or the empty rows\n");
            ++failed;
        }
        if (d == other) {
            printf("FAILED: the clock's code is not replaced by the clock\n");
            ++failed;
        }
    }
    // a scrolling field: stays put when it fits, moves when it does not, and a refresh hides the part not reached
    {
        const char* shortRow[5] = {"", "~<2 Calling at: Truro only", "", "", ""};
        const char* longRow[5] = {"", "~<2 Calling at: Redruth, Camborne, Hayle, St Erth, Penzance, Truro, Falmouth Docks and Penryn", "", "", ""};
        if (tf3api::boards::RowScrolls(shortRow[1]) || !tf3api::boards::RowScrolls(longRow[1]) || tf3api::boards::RowScrolls("<2 a long plain row that is not marked to scroll at all, however long it is")) {
            printf("FAILED: which rows scroll\n");
            ++failed;
        }
        const int none[5] = {0, 0, 0, 0, 0}, along[5] = {0, 30, 0, 0, 0};
        std::vector<uint8_t> a, b, c, e;
        tf3api::boards::ComposeRows(longRow, 5, nullptr, none, &a);
        tf3api::boards::ComposeRows(longRow, 5, nullptr, along, &b);
        tf3api::boards::ComposeRows(shortRow, 5, nullptr, none, &c);
        tf3api::boards::ComposeRows(shortRow, 5, nullptr, along, &e);
        size_t litA = 0;
        for (uint8_t v : a) litA += v;
        if (a == b || c != e || litA == 0) {
            printf("FAILED: scrolling (long row moved: %s, short row stayed: %s)\n", a != b ? "yes" : "no", c == e ? "yes" : "no");
            ++failed;
        }
        tf3api::boards::HideFrom(true, 1, 60, &a);
        size_t beyond = 0, before = 0;
        for (int row = 11; row < 18; ++row) {
            for (int col = 0; col < tf3api::boards::kColumns; ++col) (col >= 60 ? beyond : before) += a[static_cast<size_t>(row) * tf3api::boards::kColumns + col];
        }
        if (beyond != 0 || before == 0) {
            printf("FAILED: a refresh half way (%zu lit before column 60, %zu after)\n", before, beyond);
            ++failed;
        }
    }
    if (offsets.size() != 11) {
        printf("FAILED: %zu levels, expected 11\n", offsets.size());
        ++failed;
    }
    // lit dots: the three lines and the clock light something, an empty board nothing
    size_t lit = 0;
    for (uint8_t d : dots) lit += d;
    tf3api::boards::Compose(nullptr, 0, nullptr, &dots);
    size_t none = 0;
    for (uint8_t d : dots) none += d;
    if (lit < 500 || none != 0) {
        printf("FAILED: %zu dots lit with text, %zu without\n", lit, none);
        ++failed;
    }
    printf("board picture test: %s (%zu dots lit, %zu bytes, %zu levels)\n", failed == 0 ? "ALL OK" : "FAILED", lit, pixels.size(), offsets.size());
    return failed == 0 ? 0 : 1;
}
