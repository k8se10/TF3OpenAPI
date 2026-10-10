# Shadow maps

Build 40408. Disassembly (pefile + capstone) of the exe, plus live Vulkan pass counts from the in-DLL
profiler, 2026-10-10.

## How the engine picks the shadow map size

Function at `+0xe0840` (references the string `ShadowMap`; called once per frame from `+0xe3250`, which
`CRenderer::NewUpdate` calls at `+0x30009f`). It recomputes the size every call and re-creates the render
targets only when the size or cascade count changed (early exit at `+0xe1280`).

```
p = 64
while p < viewportW * 3/2  or  p < viewportH * 3/2:   p *= 2      ; this+0x20 / this+0x24
size = floor(qualityFactor * p + 0.5)                              ; this+0x28 (float)
if maxSize > 0: size = min(size, maxSize)                          ; this+0x0C (int), 0 in vanilla
size = min(size, 4096)                                             ; mov esi,1000h / cmovg
store size to this+0xA0 (w) and this+0xA4 (h); cascade count this+0x2C -> this+0xA8
```

So the size follows the screen, not a quality table: the next power of two at or above 1.5x the larger
viewport dimension. 1920x1080 -> 4096 (2880 rounds up), 2560x1440 -> 4096, 3840x2160 -> 4096 (8192
clamped). The shadow-quality setting only supplies the factor (High 1.0 -> 4096, the user's lowered
setting -> 2048, observed live).

`this+0x2C` is the cascade count (checked to be 1..4 right after the call; climate `.env.lua` files set
`shadows.numCascades = 4`).

The `mov esi, 1000h` immediate must not be patched: `esi` is reused further down as the 4 KB threshold of
an MSVC large-allocation check.

## Live cost (2560x1441, shadow quality High, user's early-mid game save)

- 27 render passes per frame at 4096x4096 = 453 megapixels of 587 total per frame.
- With the quality setting lowered: 18 passes at 2048x2048 = 75 megapixels of ~191; cockpit view went
  from about 20 fps to about 40 fps (user-reported; profiler window 23.2 ms).
- Pass count per cascade (27 / 4, 18 / 4) is not explained yet.

## Control

`native/src/shadow_tuning.cpp` hooks the sizing function and writes the engine's own maximum-size field
(`this+0x0C`) from `tf3api.ini [Shadows] MaxResolution`, so the game itself allocates the smaller targets.
Signature = function prologue through the `lea eax,[rax+rax*2] / cdq / sub / sar` sequence (unique).
