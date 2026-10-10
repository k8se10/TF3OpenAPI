#include "config.h"

#include <windows.h>

#include <cstdlib>
#include <string>

namespace tf3opt::config {
namespace {

std::string IniPath() {
    char exePath[MAX_PATH] = {};
    DWORD len = GetModuleFileNameA(nullptr, exePath, MAX_PATH);
    std::string path(exePath, len);
    size_t slash = path.find_last_of("\\/");
    if (slash != std::string::npos) path.resize(slash + 1);
    return path + "tf3opt.ini";
}

} // namespace

bool GetBool(const char* section, const char* key, bool defaultValue) {
    return GetPrivateProfileIntA(section, key, defaultValue ? 1 : 0, IniPath().c_str()) != 0;
}

int GetInt(const char* section, const char* key, int defaultValue) {
    return static_cast<int>(GetPrivateProfileIntA(section, key, defaultValue, IniPath().c_str()));
}

float GetFloat(const char* section, const char* key, float defaultValue) {
    char text[64] = {};
    if (GetPrivateProfileStringA(section, key, "", text, sizeof(text), IniPath().c_str()) == 0) return defaultValue;
    char* end = nullptr;
    float value = strtof(text, &end);
    return end == text ? defaultValue : value;
}

} // namespace tf3opt::config
