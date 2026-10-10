#include "log.h"

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

namespace tf3opt::log {
namespace {

CRITICAL_SECTION g_lock;
bool g_ready = false;
FILE* g_file = nullptr;

std::wstring LogPath() {
    wchar_t exePath[MAX_PATH] = {};
    DWORD len = GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring path(exePath, len);
    size_t slash = path.find_last_of(L"\\/");
    if (slash != std::wstring::npos) path.resize(slash + 1);
    return path + L"tf3opt.log";
}

} // namespace

void Init() {
    if (g_ready) return;
    InitializeCriticalSection(&g_lock);
    _wfopen_s(&g_file, LogPath().c_str(), L"w");  // overwrite each launch: one session per log
    g_ready = true;
}

void Shutdown() {
    if (!g_ready) return;
    EnterCriticalSection(&g_lock);
    if (g_file) {
        fclose(g_file);
        g_file = nullptr;
    }
    LeaveCriticalSection(&g_lock);
}

void Write(const char* fmt, ...) {
    if (!g_ready || !g_file) return;

    va_list args;
    va_start(args, fmt);
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(nullptr, 0, fmt, copy);
    va_end(copy);
    if (needed < 0) {
        va_end(args);
        return;
    }
    std::vector<char> text(static_cast<size_t>(needed) + 1);
    vsnprintf(text.data(), text.size(), fmt, args);
    va_end(args);

    SYSTEMTIME t;
    GetLocalTime(&t);
    EnterCriticalSection(&g_lock);
    fprintf(g_file, "[%02u:%02u:%02u.%03u] %s\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, text.data());
    fflush(g_file);  // low volume (startup + rare events only), so flushing every line is fine
    LeaveCriticalSection(&g_lock);
}

} // namespace tf3opt::log
