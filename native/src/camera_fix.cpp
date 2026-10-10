#include "camera_fix.h"

#include "config.h"
#include "log.h"
#include "sigscan.h"

#include <windows.h>

#include <cstdint>
#include <cstring>

namespace tf3opt::camera_fix {
namespace {

// Clamp sequence at the end of the FollowAction eye builder (build 40408 @ 0x140532be9):
//   C5 FA 10 05 ?? ?? ?? ??   vmovss  xmm0, [rip+X]      ; -100.0 (floor)
//   C4 C1 78 2F C3            vcomiss xmm0, xmm11        ; floor > eyeZ ?
//   77 0D                     ja      +0x0D              ; -> store floor        <- patched to NOP NOP
//   C5 FA 10 05 ?? ?? ?? ??   vmovss  xmm0, [rip+Y]      ; 6000.0 (ceiling)
//   C4 C1 7A 5D C3            vminss  xmm0, xmm0, xmm11  ; min(ceiling, eyeZ)
//   C4 C1 7A 11 46 08         vmovss  [r14+8], xmm0      ; store eye.z
constexpr char kPattern[] =
    "C5 FA 10 05 ?? ?? ?? ?? C4 C1 78 2F C3 77 0D C5 FA 10 05 ?? ?? ?? ?? C4 C1 7A 5D C3 C4 C1 7A 11 46 08";
constexpr size_t kJumpOffset = 13;
constexpr uint8_t kOriginal[2] = {0x77, 0x0D};
constexpr uint8_t kPatched[2] = {0x90, 0x90};

uint8_t* g_site = nullptr;  // address of the patched jump while the fix is active

bool WriteCode(uint8_t* at, const uint8_t (&bytes)[2]) {
    DWORD oldProtect = 0;
    if (!VirtualProtect(at, sizeof(bytes), PAGE_EXECUTE_READWRITE, &oldProtect)) return false;
    std::memcpy(at, bytes, sizeof(bytes));
    DWORD unused = 0;
    VirtualProtect(at, sizeof(bytes), oldProtect, &unused);
    FlushInstructionCache(GetCurrentProcess(), at, sizeof(bytes));
    return true;
}

} // namespace

void Install() {
    if (!config::GetBool("Camera", "CockpitDepthFix", true)) {
        TF3_LOG("camera_fix: disabled in tf3opt.ini ([Camera] CockpitDepthFix=0)");
        return;
    }

    uintptr_t match = sigscan::FindUnique("cockpit eye height clamp", kPattern);
    if (match == 0) {
        TF3_LOG("camera_fix: not applied (signature not found - different game build?)");
        return;
    }

    auto* site = reinterpret_cast<uint8_t*>(match + kJumpOffset);
    if (std::memcmp(site, kOriginal, sizeof(kOriginal)) != 0) {
        TF3_LOG("camera_fix: not applied (unexpected bytes %02X %02X at the jump)", site[0], site[1]);
        return;
    }
    if (!WriteCode(site, kPatched)) {
        TF3_LOG("camera_fix: not applied (VirtualProtect failed, error %lu)", GetLastError());
        return;
    }
    g_site = site;
    TF3_LOG("camera_fix: applied - cockpit eye no longer clamped to -100 (6000 ceiling kept)");
}

void Uninstall() {
    if (g_site == nullptr) return;
    if (std::memcmp(g_site, kPatched, sizeof(kPatched)) == 0) WriteCode(g_site, kOriginal);
    g_site = nullptr;
}

} // namespace tf3opt::camera_fix
