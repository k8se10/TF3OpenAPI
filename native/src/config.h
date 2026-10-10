#pragma once

// Settings from "tf3opt.ini" next to the game executable. Read on demand; missing file or key -> default.
//
//   [Camera]
//   CockpitDepthFix=1   ; 0 = vanilla cockpit camera (clamped at world height -100)

namespace tf3opt::config {

bool GetBool(const char* section, const char* key, bool defaultValue);

} // namespace tf3opt::config
