#pragma once

#include <cstdint>

// Overlay renderer: this DLL's own drawing pass in the game's frame.
//
// Under the game's interface (the default, [Overlay] UnderInterface=1): the game draws a frame's screen image
// in several render passes. The first of them that draws anything starts by putting the picture of the world
// on the screen and goes on with the interface's bars and buttons; the last lays the windows and panels over
// that. The overlay's draws are recorded into the game's command buffer inside that first pass, right after
// its first draw, so that they lie over the world and under all of the interface. Where the overlay's pipeline
// does not fit the game's pass, it records a pass of its own just before the game's last pass instead (over
// the world and the bars, under the windows); which pass is the last is learned from the frame before. The
// game's own drawing state on the command buffer is put back afterwards (vkstats does that).
//
// On top of everything (the fallback, used whenever the above cannot be done for a frame): just before the
// game presents a frame, the overlay records one small render pass into the same swapchain image (loading what
// the game drew, blending text and rectangles over it) and submits it to the game's queue. It waits on
// whatever the game's present was waiting on and makes the present wait on the overlay instead, so the order
// is always: game frame, overlay, present.
//
// It owns its Vulkan objects (render pass, pipeline, font atlas, per-image framebuffers and buffers) and
// rebuilds the per-image ones whenever the game replaces its swapchain. The font atlas is rasterised from a
// system font with GDI at startup; no third-party font code or font files are shipped.
//
// First use: text in screen space (a status line). World-space road names build on this.
// If anything fails the overlay switches itself off for the session and the game presents as usual.
//
// tf3api.ini [Overlay]:
//   Enabled=0        1 = draw the overlay from the start
//   UnderInterface=1 1 = draw under the game's windows where that is possible, 0 = always on top
//   ToggleKey=0      virtual-key code that switches it on/off while playing (117 = F6, 0 = none)
//   Font=Segoe UI    system font for overlay text

namespace tf3api::overlay {

// Requires vkstats to be installed (it owns the Vulkan lookup hooks).
void Install();
void Uninstall();

// ---- Drawing, valid only inside a frame callback (see SetFrameCallback) --------------------------------

// Colours are 0xAABBGGRR (red in the low byte).
constexpr uint32_t kWhite = 0xFFFFFFFFu;

// A filled rectangle in pixels, origin top-left.
void Rect(float x, float y, float width, float height, uint32_t colour);
// Text with its top-left corner at (x, y); `size` is the line height in pixels. Returns the width drawn.
float Text(float x, float y, float size, uint32_t colour, const char* text);
// Width `Text` would use.
float TextWidth(float size, const char* text);
// Text along a baseline that may be rotated: (x, y) is the left end of the baseline, `angle` in radians
// (0 = left to right, positive = clockwise on screen).
void TextRotated(float x, float y, float size, float angle, uint32_t colour, const char* text);

// Called once per frame while the overlay is on, on the thread that records the game's frame (or the one that
// presents it, in the fallback). Width and height are the frame's size in pixels. One callback; setting a new
// one replaces the old.
using FrameCallback = void (*)(float width, float height);
void SetFrameCallback(FrameCallback callback);

} // namespace tf3api::overlay
