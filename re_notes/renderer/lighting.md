# Night lighting: lights per screen bucket (build 40420, 2026-10-14)

**Seen:** at night, seen from above over a town, sharp-edged dark rectangles where street-light glow stops;
they move with the screen (user, with a screenshot). Not caused by our occlusion culling or shadow limit: the
screenshot's session had both off.

**How the game lights at night** (read):
- Shader side (`base/content/rendering/programs/shaders/util/light_util.fs`, loose file): clustered lighting.
  The view is a grid of buckets - `u_lightIndexBuffer.params` x, y, z - with z in log slices of depth; a pixel
  is lit only by the lights listed for its bucket (`calcStartIndexAndSize`: per-bucket start and size from a
  prefix sum, then the light indices).
- CPU side: `CRenderer::NewUpdate` starts a job (`0x14030c3e0`, a lambda run on the thread pool; its future at
  renderer data +0x230) that, for each light (0xC0-byte entries matching the shader's `LightSource`), works out
  which buckets its sphere covers and appends it to each - **only while that bucket has fewer than the cap**
  (`if (count < cap)`). The lists are then compacted (empty slots, -1, removed) and prefix-summed, and
  `engine::LightingHelper::Update` (`0x1400c8ce0`) uploads them with their actual size each frame.
- The numbers, set in `CRenderer::CRenderer` (`0x1402e6560`): buckets **32 x 32 x 24**, cap **64 lights per
  bucket** (+0xa4), light distance **6500 m** (+0xa8).

**Cause:** a bucket covering more than 64 lights drops the rest for that bucket only, so a dropped lamp still
lights the neighbouring bucket and its glow ends at the bucket's edge.

**Fix** (`native/src/lighting_fix.{h,cpp}`, `[Lighting] MaxLightsPerBucket`, default 0 = the game's 64): the
constructor's immediate 64 is patched (unique signature over the four bucket settings) before the renderer is
made. Bounded 16..1024. The upload sends the compacted lists' real size each frame, so a higher cap costs only
where buckets are crowded. Not proven: that the GPU storage buffer is resized for a larger list (the upload
passes the size, which points that way). **Seen fixed in the game (user, 2026-10-14: "fixed") at 256.**
