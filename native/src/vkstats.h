#pragma once

#include <cstdint>
#include <vector>

// Diagnostics: per-frame timing and counts of the game's own Vulkan calls.
//
// The game loads vulkan-1.dll at runtime and asks it for every function pointer by name. This module
// hooks the two lookup functions (vkGetDeviceProcAddr / vkGetInstanceProcAddr) and, for a short list of
// calls, hands the game a thin wrapper that times or counts the call and forwards it unchanged. Nothing
// about what is rendered changes. A frame ends at vkQueuePresentKHR.
//
// What it answers: how long a frame is, how much of it the game spends waiting inside acquire / submit /
// present / fence waits, how many draw calls, pipeline binds and descriptor updates a frame contains, and
// whether pipelines or shader modules are still being created while playing.
//
// tf3api.ini [Vulkan] Hooks=1 (default 1). The statistics are printed at the top of each profiler report;
// swapchain parameters are logged to tf3api.log when created. The overlay draws through the same hooks.

namespace tf3api::vkstats {

struct Totals {
    uint64_t frames = 0;
    // Time inside the call, in QueryPerformanceCounter ticks.
    uint64_t ticksAcquire = 0, ticksPresent = 0, ticksSubmit = 0, ticksWaitFences = 0, ticksWaitIdle = 0;
    uint64_t ticksCreatePipelines = 0;
    // Counts.
    uint64_t submits = 0, fenceWaits = 0;
    uint64_t draws = 0;          // vkCmdDraw + vkCmdDrawIndexed
    uint64_t indirectCalls = 0;  // vkCmdDraw(Indexed)Indirect(Count) commands
    uint64_t indirectDraws = 0;  // draws those commands may issue (drawCount / maxDrawCount)
    uint64_t instances = 0;      // sum of instanceCount over direct draws
    uint64_t indices = 0;        // sum of indexCount * instanceCount (vertexCount for non-indexed)
    uint64_t pipelineBinds = 0, descriptorSetBinds = 0, descriptorSetUpdates = 0, vertexBufferBinds = 0;
    uint64_t renderPasses = 0;
    uint64_t pipelinesCreated = 0, shaderModulesCreated = 0, buffersCreated = 0, memoryAllocations = 0;
    // Texture and resource traffic.
    uint64_t imagesCreated = 0, imagesDestroyed = 0, imageViewsCreated = 0, samplersCreated = 0;
    uint64_t imageUploads = 0;        // vkCmdCopyBufferToImage commands (texture data sent to the GPU)
    uint64_t imageUploadRegions = 0;  // mip levels / layers those commands carried
    uint64_t buffersDestroyed = 0, descriptorSetAllocations = 0;
};

// Requires MinHook to be initialised. Loads vulkan-1.dll early so the lookups can be hooked before the game
// asks for its function pointers.
void Install();
void Uninstall();

bool Active();          // hooks installed and at least one wrapper handed out
Totals Snapshot();      // running totals since startup
double TicksToMs(uint64_t ticks);
// Present-to-present times in ms for frames [firstFrame, lastFrame) (at most the newest 8192).
void FrameTimesMs(uint64_t firstFrame, uint64_t lastFrame, std::vector<float>* out);
// Render passes begun since startup, grouped by render-area size (the most common kMaxPassSizes sizes seen).
constexpr int kMaxPassSizes = 48;
struct PassSizes {
    uint32_t width[kMaxPassSizes] = {};
    uint32_t height[kMaxPassSizes] = {};
    uint64_t count[kMaxPassSizes] = {};
    uint64_t draws[kMaxPassSizes] = {};    // direct draw calls recorded inside passes of this size
    uint64_t indices[kMaxPassSizes] = {};  // indices (x instances) those draws carried
    uint64_t other = 0;  // passes whose size did not fit in the table
};
PassSizes SnapshotPassSizes();
// Timeout (ns) the game passed to its most recent vkAcquireNextImageKHR; UINT64_MAX = wait forever.
uint64_t LastAcquireTimeout();
// Name of the GPU the game created its device on ("" until it has).
const char* DeviceName();

// ---- For other modules that draw with the game's Vulkan device (the overlay) ---------------------------

using VoidFn = void (*)();
// The game's VkInstance / VkPhysicalDevice / VkDevice, or nullptr before the game has created them.
void* Instance();
void* PhysicalDevice();
void* Device();
// The real driver entry point for a Vulkan function (never one of this module's wrappers), or nullptr.
VoidFn DeviceProc(const char* name);
VoidFn InstanceProc(const char* name);
// Queue family a VkQueue was obtained from, or UINT32_MAX if the game never asked for it through us.
uint32_t QueueFamilyOf(void* queue);

// Callbacks into a drawing module. All are called on the game thread that made the Vulkan call.
struct Listener {
    // A swapchain exists: its handle, surface format (VkFormat) and size.
    void (*swapchainCreated)(uint64_t swapchain, uint32_t format, uint32_t width, uint32_t height) = nullptr;
    // Called before the swapchain is destroyed (also when it is replaced by a new one).
    void (*swapchainDestroying)(uint64_t swapchain) = nullptr;
    // Called before the device is destroyed.
    void (*deviceDestroying)() = nullptr;
    // Called before every vkQueuePresentKHR. Returns the VkPresentInfoKHR to present with: the one given, or
    // a replacement owned by the listener that stays valid until the next call.
    const void* (*beforePresent)(void* queue, const void* presentInfo) = nullptr;
};
void SetListener(const Listener& listener);

} // namespace tf3api::vkstats
