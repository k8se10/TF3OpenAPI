#include "log.h"

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <share.h>
#include <string>

namespace tf3api::log {
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
    return path + L"tf3api.log";
}

} // namespace

void Init() {
    if (g_ready) return;
    InitializeCriticalSection(&g_lock);
    // Append, never truncate: a second process loading this DLL (e.g. the game's crash reporter
    // relaunching the exe) must not wipe the session that matters. Each launch starts with a header.
    const std::wstring path = LogPath();
    WIN32_FILE_ATTRIBUTE_DATA info = {};
    if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info) && info.nFileSizeHigh == 0 &&
        info.nFileSizeLow > 4u * 1024u * 1024u) {
        DeleteFileW(path.c_str());  // keep it bounded: start fresh once it passes 4 MB
    }
    // Shared read/write so the log can be read while the game is running (or stuck on an error box).
    g_file = _wfsopen(path.c_str(), L"a", _SH_DENYNO);
    g_ready = true;
    wchar_t cmd[512] = {};
    lstrcpynW(cmd, GetCommandLineW(), 512);
    Write("==== launch pid %lu: %ls", GetCurrentProcessId(), cmd);
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

    // Fixed stack buffer, no heap: this is also called from the out-of-memory probe. vsnprintf
    // truncates safely (unlike sprintf_s, which fails fast on overflow).
    char text[2048];
    va_list args;
    va_start(args, fmt);
    vsnprintf(text, sizeof(text), fmt, args);
    va_end(args);

    SYSTEMTIME t;
    GetLocalTime(&t);
    EnterCriticalSection(&g_lock);
    fprintf(g_file, "[%02u:%02u:%02u.%03u] %s\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, text);
    fflush(g_file);  // low volume (startup + rare events only), so flushing every line is fine
    LeaveCriticalSection(&g_lock);
}

} // namespace tf3api::log
