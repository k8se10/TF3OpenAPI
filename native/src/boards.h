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
// (tf3api.boardText / tf3api.boardClock). Until a script has said anything the board keeps the picture it
// ships with.
//
// Screens: the mod ships kSlots screen textures, so that boards at different stations can show different
// things. The game gives no way to ask which of its images belongs to which file, so every screen's file
// has a size of its own (the dots in the top left corner, a dark margin to the right and below, which the
// screen's model does not show): an image is known by its width and height.
//
// A line whose text changes is refreshed as real boards do it: cleared, and the new text drawn in column by
// column from the left over [Boards] RefreshMs (default 1600; 0 = at once). The clock just ticks. A field
// that scrolls (see ComposeRows) starts to move a moment after its line has been drawn in.
//
// tf3api.ini [Boards] Enabled=1 (default 0 until it has been seen working). Needs [Vulkan] Hooks=1.

namespace tf3api::boards {

constexpr int kColumns = 240, kRows = 50, kDot = 8;
constexpr int kWidth = kColumns * kDot, kHeight = kRows * kDot;
constexpr int kTextLines = 3;
constexpr int kRowLines = 5;   // rows of text of a screen laid out by its script (SetSlotRows)
constexpr int kSlots = 32;
// the size of a screen's texture
inline int SlotWidth(int slot) { return kWidth + 16 * (slot % 8); }
inline int SlotHeight(int slot) { return kHeight + 16 * (slot / 8); }

void Install();
void Uninstall();

// The lines of text of one screen (any may be null or empty). A line without a tab is centred. A line with
// tabs is a departure: "time <tab> destination <tab> platform <tab> expected" - time and destination at the
// left, platform and expected at the right. A screen nobody has set shows the "not connected" lines.
// Returns false when nothing changed or the slot does not exist.
bool SetSlotLines(int slot, const char* const* lines, int count);
// The same for screen 0.
bool SetLines(const char* const* lines, int count);
// A screen laid out by the script: up to kRowLines rows of text, the whole height of the board. A row is
// one or more fields separated by tabs. A field may begin with where it stands: "<N " its left edge at
// column N, ">N " its right edge at column N (columns of dots, 0 .. 239); a field without that is centred.
// A field never runs into the one to its right. The character with code 1 in a field stands for the clock
// (HH:MM:SS), which the native side keeps running by itself.
bool SetSlotRows(int slot, const char* const* rows, int count);
// The clock line: seconds since midnight of the game's day, or a negative number for "not known" ("--:--:--").
bool SetClock(int secondsOfDay);
// How many of the game's images are being written to at the moment (0: no board's texture is loaded).
int ImagesSeen();

// ---- For tests ----
// The dots of the picture for the given lines and clock text: kRows x kColumns, row by row, 1 = lit.
void Compose(const char* const* lines, int count, const char* clock, std::vector<uint8_t>* dots);
// The dots of a screen laid out in rows (see SetSlotRows); `clock` is the text put in place of code 1.
void ComposeRows(const char* const* rows, int count, const char* clock, std::vector<uint8_t>* dots);
// The same with each row's scrolling fields `scroll[row]` columns along (null: at their start). A field
// written with a leading "~" (before its "<N " or ">N ") scrolls when it is too long for its room: the text
// runs past from right to left, round and round, with a dark gap between its end and its start.
void ComposeRows(const char* const* rows, int count, const char* clock, const int* scroll, std::vector<uint8_t>* dots);
// Whether a row has a scrolling field that is too long for its room (so the screen has to keep moving).
bool RowScrolls(const char* row);
// Puts out the dots of one line from `column` on (the part a refresh has not reached yet). `rows`: the line
// is a row of a screen laid out in rows, else one of the three lines.
void HideFrom(bool rows, int line, int column, std::vector<uint8_t>* dots);
// The picture of those dots as the game's texture holds it: kWidth x kHeight points of blue, green, red,
// opacity, with every smaller level after it (each half the size, down to one point).
void Paint(const std::vector<uint8_t>& dots, std::vector<uint8_t>* pixels, std::vector<size_t>* levelOffsets);
// The same in a texture of width x height points (at least kWidth x kHeight): the dots in the top left
// corner, the rest black.
void Paint(const std::vector<uint8_t>& dots, int width, int height, std::vector<uint8_t>* pixels, std::vector<size_t>* levelOffsets);

} // namespace tf3api::boards
