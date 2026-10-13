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
