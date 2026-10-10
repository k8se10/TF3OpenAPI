#pragma once

// Settings from "tf3opt.ini" next to the game executable. Read on demand; missing file or key -> default.
//
//   [Camera]
//   CockpitDepthFix=0   ; 1 = cockpit follows below world height -100 (leaks memory until culling lands)
//   [Debug]
//   BadAllocProbe=1     ; log stacks of the first bad_alloc throws
//   AllocProfiler=0     ; 1 = record committed bytes per call stack (adds overhead)
//   [Occlusion]
//   Enabled=0           ; 1 = terrain occlusion culling (see occlusion.h for the other keys)

namespace tf3opt::config {

bool GetBool(const char* section, const char* key, bool defaultValue);
int GetInt(const char* section, const char* key, int defaultValue);
float GetFloat(const char* section, const char* key, float defaultValue);

} // namespace tf3opt::config
