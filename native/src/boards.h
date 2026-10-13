#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

// Departure boards: the lit dots of a board's screen are written, live, into the texture the game draws
// the screen with.
//
// A board's screen is a flat part with a glowing texture of 1920 x 400 points: 240 x 50 dots of 8 x 8 points
// (mod/tf3api_departure_boards, built by tools/build_boards.py). The game loads that texture like any other;
// this module notices the image the game makes for it (by its size), and when the text to show changes it
// copies a new picture into that image. Occlusion, glow and night then come from the game's own drawing.
//
// What is shown: up to three lines of text and a clock line, set by script through the bridge
// (tf3api.boardLines / tf3api.boardClock). Until a script has said anything the board keeps the picture it
// ships with.
//
// tf3api.ini [Boards] Enabled=1 (default 0 until it has been seen working). Needs [Vulkan] Hooks=1.

namespace tf3api::boards {

constexpr int kColumns = 240, kRows = 50, kDot = 8;
constexpr int kWidth = kColumns * kDot, kHeight = kRows * kDot;
constexpr int kTextLines = 3;

void Install();
void Uninstall();

// The lines of text, centred (any may be null or empty). Returns false when nothing changed.
bool SetLines(const char* const* lines, int count);
// The clock line: seconds since midnight of the game's day, or a negative number for "not known" ("--:--:--").
bool SetClock(int secondsOfDay);
// How many of the game's images are being written to at the moment (0: no board's texture is loaded).
int ImagesSeen();

// ---- For tests ----
// The dots of the picture for the given lines and clock text: kRows x kColumns, row by row, 1 = lit.
void Compose(const char* const* lines, int count, const char* clock, std::vector<uint8_t>* dots);
// The picture of those dots as the game's texture holds it: kWidth x kHeight points of blue, green, red,
// opacity, with every smaller level after it (each half the size, down to one point).
void Paint(const std::vector<uint8_t>& dots, std::vector<uint8_t>* pixels, std::vector<size_t>* levelOffsets);

} // namespace tf3api::boards
