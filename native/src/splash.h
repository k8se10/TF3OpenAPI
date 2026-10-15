#pragma once

// Our logo on the game's splash screen, after the Paradox Interactive logo.
//
// The splash (UI::SplashScreen, build 40420) is a list of pictures with a time each, built by one function
// that adds an entry per call: the Urban Games logo, the Paradox logo, then an empty entry that ends it. This
// hooks that function and, when the empty ending entry comes, first adds one more picture of the same kind.
// The picture is made like the others (an image view, shown by the game's own sequence, with its own fade),
// but its pixels are replaced by the logo built into this DLL, so no file has to be found at that point of the
// start-up. tf3api.ini [Splash] Enabled=1 (default 1), Seconds (stay, default 1.0), ZoomSeconds, ZoomPercent, FadeSeconds, SwapRB=0. The game only shows or hides
// a splash picture, so the zoom (the picture's texture window) and the fade (the pixels' strength) are redone on
// every step of the splash.

namespace tf3api::splash {

void Install();
void Uninstall();

} // namespace tf3api::splash
