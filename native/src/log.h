#pragma once

// Minimal file logger: writes "tf3api.log" next to the game executable.
// Thread-safe, line-buffered through a small lock; formatting uses vsnprintf into a growing buffer
// (never sprintf_s into a fixed buffer - see CLAUDE.md §5 on fail-fast UCRT overflows).

namespace tf3api::log {

void Init();
void Shutdown();
void Write(const char* fmt, ...);

} // namespace tf3api::log

#define TF3_LOG(...) ::tf3api::log::Write(__VA_ARGS__)
