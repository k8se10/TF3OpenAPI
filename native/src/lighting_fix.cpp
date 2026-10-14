#include "lighting_fix.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <cstdint>
#include <cstring>

namespace tf3api::lighting_fix {
namespace {

// The light-bucket settings in CRenderer's constructor (build 40420 @ 0x1402e6597, base register rsi):
//   C7 86 9C 00 00 00 20 00 00 00   mov dword [rsi+0x9c], 32      ; buckets down the screen
//   C7 86 A0 00 00 00 18 00 00 00   mov dword [rsi+0xa0], 24      ; slices into the distance
//   C7 86 A4 00 00 00 40 00 00 00   mov dword [rsi+0xa4], 64      ; lights per bucket   <- the value patched
//   C7 86 A8 00 00 00 00 20 CB 45   mov dword [rsi+0xa8], 6500.0  ; light distance
// The pattern takes the base register's byte open; the three neighbours are checked as they are.
constexpr char kPattern[] =
    "C7 ?? 9C 00 00 00 20 00 00 00 C7 ?? A0 00 00 00 18 00 00 00 C7 ?? A4 00 00 00 40 00 00 00 C7 ?? A8 00 00 00 00 20 CB 45";
constexpr size_t kValueOffset = 26;
constexpr uint32_t kOriginal = 64;

uint8_t* g_site = nullptr;

bool WriteValue(uint8_t* at, uint32_t value) {
    DWORD oldProtect = 0;
    if (!VirtualProtect(at, sizeof(value), PAGE_EXECUTE_READWRITE, &oldProtect)) return false;
    std::memcpy(at, &value, sizeof(value));
    DWORD unused = 0;
    VirtualProtect(at, sizeof(value), oldProtect, &unused);
    FlushInstructionCache(GetCurrentProcess(), at, sizeof(value));
    return true;
}

} // namespace

void Install() {
    const int wanted = config::GetInt("Lighting", "MaxLightsPerBucket", 0);
    if (wanted <= 0) {
        TF3_LOG("lighting_fix: off ([Lighting] MaxLightsPerBucket=0) - the game's 64 lights per screen bucket");
        return;
    }
    // The light lists grow with what is actually in them each frame; a bound keeps a mistyped value sane.
    const uint32_t value = static_cast<uint32_t>(wanted < 16 ? 16 : (wanted > 1024 ? 1024 : wanted));
    const uintptr_t match = sigscan::FindUnique("light bucket settings", kPattern);
    if (match == 0) {
        TF3_LOG("lighting_fix: not applied (signature not found - different game build?)");
        return;
    }
    auto* site = reinterpret_cast<uint8_t*>(match + kValueOffset);
    uint32_t current = 0;
    std::memcpy(&current, site, sizeof(current));
    if (current != kOriginal) {
        TF3_LOG("lighting_fix: not applied (the value found is %u, not the expected %u)", current, kOriginal);
        return;
    }
    if (!WriteValue(site, value)) {
        TF3_LOG("lighting_fix: not applied (VirtualProtect failed, error %lu)", GetLastError());
        return;
    }
    g_site = site;
    TF3_LOG("lighting_fix: applied - up to %u lights per screen bucket (the game's own is %u); takes effect when the game makes its renderer",
            value, kOriginal);
}

void Uninstall() {
    if (g_site == nullptr) return;
    WriteValue(g_site, kOriginal);
    g_site = nullptr;
}

} // namespace tf3api::lighting_fix
