#include "vkstats.h"

#include "config.h"
#include "log.h"

#include <windows.h>

#include <atomic>
#include <cstddef>
#include <cstring>

#include "MinHook.h"

namespace tf3opt::vkstats {
namespace {

using Counter = std::atomic<uint64_t>;
using VoidFn = void (*)();

constexpr uint32_t kFrameRing = 8192;  // power of two

struct Counters {
    Counter frames, ticksAcquire, ticksPresent, ticksSubmit, ticksWaitFences, ticksWaitIdle, ticksCreatePipelines;
    Counter submits, fenceWaits, draws, indirectCalls, indirectDraws, instances, indices;
    Counter pipelineBinds, descriptorSetBinds, descriptorSetUpdates, vertexBufferBinds, renderPasses;
    Counter pipelinesCreated, shaderModulesCreated, buffersCreated, memoryAllocations;
    Counter imagesCreated, imagesDestroyed, imageViewsCreated, samplersCreated, imageUploads, imageUploadRegions;
    Counter buffersDestroyed, descriptorSetAllocations;
};

Counters g;
std::atomic<float> g_frameMs[kFrameRing];
std::atomic<uint64_t> g_lastPresentTicks{0};
std::atomic<bool> g_wrapped{false};
std::atomic<uint64_t> g_lastAcquireTimeout{0};
std::atomic<void*> g_instance{nullptr};  // last VkInstance the game looked functions up on
char g_deviceName[256] = "";
std::atomic<uint64_t> g_passKey[kMaxPassSizes];  // (width << 32) | height, 0 = free slot
Counter g_passCount[kMaxPassSizes];
Counter g_passDraws[kMaxPassSizes], g_passIndices[kMaxPassSizes];
Counter g_passOther;

// Which pass-size slot each command buffer is currently recording into, so draws can be charged to the
// kind of pass they belong to. Small lock-free table keyed by the command buffer handle; a collision only
// makes a few draws go uncounted per size.
constexpr uint32_t kCbSlots = 512;  // power of two
std::atomic<uintptr_t> g_cbKey[kCbSlots];
std::atomic<int> g_cbPass[kCbSlots];

uint32_t CbSlot(void* cb) { return static_cast<uint32_t>((reinterpret_cast<uintptr_t>(cb) >> 4) * 2654435761u) & (kCbSlots - 1); }

void SetCbPass(void* cb, int pass) {
    const uint32_t slot = CbSlot(cb);
    g_cbPass[slot].store(pass, std::memory_order_relaxed);
    g_cbKey[slot].store(reinterpret_cast<uintptr_t>(cb), std::memory_order_relaxed);
}

void CountDrawInPass(void* cb, uint64_t indices) {
    const uint32_t slot = CbSlot(cb);
    if (g_cbKey[slot].load(std::memory_order_relaxed) != reinterpret_cast<uintptr_t>(cb)) return;
    const int pass = g_cbPass[slot].load(std::memory_order_relaxed);
    if (pass < 0 || pass >= kMaxPassSizes) return;
    g_passDraws[pass].fetch_add(1, std::memory_order_relaxed);
    g_passIndices[pass].fetch_add(indices, std::memory_order_relaxed);
}
LARGE_INTEGER g_qpcFreq = {};
bool g_installed = false;

uint64_t Now() {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return static_cast<uint64_t>(t.QuadPart);
}

void Add(Counter& c, uint64_t n = 1) { c.fetch_add(n, std::memory_order_relaxed); }

struct Timed {
    Counter& total;
    uint64_t start = Now();
    explicit Timed(Counter& c) : total(c) {}
    ~Timed() { Add(total, Now() - start); }
};

// ---- Wrappers ----------------------------------------------------------------------------------------
// Vulkan handles are pointers or 64-bit integers; every argument is forwarded untouched. VkResult = int32.

// Only the fields read here; layout per the Vulkan headers (x64).
struct SwapchainCreateInfo {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint64_t surface;
    uint32_t minImageCount;
    uint32_t imageFormat;
    uint32_t imageColorSpace;
    uint32_t width, height;
    uint32_t imageArrayLayers;
    uint32_t imageUsage;
    uint32_t imageSharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices;
    uint32_t preTransform;
    uint32_t compositeAlpha;
    uint32_t presentMode;
    uint32_t clipped;
    uint64_t oldSwapchain;
};
static_assert(offsetof(SwapchainCreateInfo, presentMode) == 0x58, "VkSwapchainCreateInfoKHR layout");

// Returns the pass-size slot, or -1.
int CountPass(uint32_t width, uint32_t height) {
    Add(g.renderPasses);
    const uint64_t key = (static_cast<uint64_t>(width) << 32) | height;
    if (key == 0) return -1;
    for (int i = 0; i < kMaxPassSizes; ++i) {
        uint64_t current = g_passKey[i].load(std::memory_order_relaxed);
        if (current == 0 && g_passKey[i].compare_exchange_strong(current, key, std::memory_order_relaxed)) current = key;
        if (current == key) {
            Add(g_passCount[i]);
            return i;
        }
    }
    Add(g_passOther);
    return -1;
}

// VkRenderPassBeginInfo / VkRenderingInfo up to the render area (x64 layout per the Vulkan headers).
struct RenderPassBeginInfo {
    uint32_t sType;
    const void* pNext;
    uint64_t renderPass;
    uint64_t framebuffer;
    int32_t x, y;
    uint32_t width, height;
};
struct RenderingInfo {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    int32_t x, y;
    uint32_t width, height;
};
static_assert(offsetof(RenderPassBeginInfo, width) == 0x28, "VkRenderPassBeginInfo layout");
static_assert(offsetof(RenderingInfo, width) == 0x1C, "VkRenderingInfo layout");

#define TF3_VK_REAL(name) std::atomic<VoidFn> real_##name{nullptr}
#define TF3_VK_CALL(name, type) (reinterpret_cast<type>(real_##name.load(std::memory_order_relaxed)))

TF3_VK_REAL(AcquireNextImageKHR);
int32_t Wrap_AcquireNextImageKHR(void* device, uint64_t swapchain, uint64_t timeout, uint64_t semaphore, uint64_t fence,
                                 uint32_t* imageIndex) {
    Timed timed(g.ticksAcquire);
    g_lastAcquireTimeout.store(timeout, std::memory_order_relaxed);
    return TF3_VK_CALL(AcquireNextImageKHR, int32_t (*)(void*, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t*))(
        device, swapchain, timeout, semaphore, fence, imageIndex);
}

TF3_VK_REAL(AcquireNextImage2KHR);
int32_t Wrap_AcquireNextImage2KHR(void* device, const void* info, uint32_t* imageIndex) {
    Timed timed(g.ticksAcquire);
    return TF3_VK_CALL(AcquireNextImage2KHR, int32_t (*)(void*, const void*, uint32_t*))(device, info, imageIndex);
}

TF3_VK_REAL(QueuePresentKHR);
int32_t Wrap_QueuePresentKHR(void* queue, const void* info) {
    const uint64_t start = Now();
    const int32_t result = TF3_VK_CALL(QueuePresentKHR, int32_t (*)(void*, const void*))(queue, info);
    const uint64_t end = Now();
    Add(g.ticksPresent, end - start);
    const uint64_t previous = g_lastPresentTicks.exchange(end, std::memory_order_relaxed);
    const uint64_t frame = g.frames.fetch_add(1, std::memory_order_relaxed);
    const float ms = previous != 0 ? static_cast<float>(1000.0 * static_cast<double>(end - previous) /
                                                         static_cast<double>(g_qpcFreq.QuadPart))
                                   : 0.0f;
    g_frameMs[frame & (kFrameRing - 1)].store(ms, std::memory_order_relaxed);
    return result;
}

TF3_VK_REAL(QueueSubmit);
int32_t Wrap_QueueSubmit(void* queue, uint32_t count, const void* submits, uint64_t fence) {
    Timed timed(g.ticksSubmit);
    Add(g.submits);
    return TF3_VK_CALL(QueueSubmit, int32_t (*)(void*, uint32_t, const void*, uint64_t))(queue, count, submits, fence);
}

TF3_VK_REAL(QueueSubmit2);
int32_t Wrap_QueueSubmit2(void* queue, uint32_t count, const void* submits, uint64_t fence) {
    Timed timed(g.ticksSubmit);
    Add(g.submits);
    return TF3_VK_CALL(QueueSubmit2, int32_t (*)(void*, uint32_t, const void*, uint64_t))(queue, count, submits, fence);
}

TF3_VK_REAL(QueueSubmit2KHR);
int32_t Wrap_QueueSubmit2KHR(void* queue, uint32_t count, const void* submits, uint64_t fence) {
    Timed timed(g.ticksSubmit);
    Add(g.submits);
    return TF3_VK_CALL(QueueSubmit2KHR, int32_t (*)(void*, uint32_t, const void*, uint64_t))(queue, count, submits, fence);
}

TF3_VK_REAL(WaitForFences);
int32_t Wrap_WaitForFences(void* device, uint32_t count, const uint64_t* fences, uint32_t waitAll, uint64_t timeout) {
    Timed timed(g.ticksWaitFences);
    Add(g.fenceWaits);
    return TF3_VK_CALL(WaitForFences, int32_t (*)(void*, uint32_t, const uint64_t*, uint32_t, uint64_t))(device, count, fences,
                                                                                                    waitAll, timeout);
}

TF3_VK_REAL(QueueWaitIdle);
int32_t Wrap_QueueWaitIdle(void* queue) {
    Timed timed(g.ticksWaitIdle);
    return TF3_VK_CALL(QueueWaitIdle, int32_t (*)(void*))(queue);
}

TF3_VK_REAL(DeviceWaitIdle);
int32_t Wrap_DeviceWaitIdle(void* device) {
    Timed timed(g.ticksWaitIdle);
    return TF3_VK_CALL(DeviceWaitIdle, int32_t (*)(void*))(device);
}

TF3_VK_REAL(CmdDraw);
void Wrap_CmdDraw(void* cb, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) {
    Add(g.draws);
    Add(g.instances, instanceCount);
    Add(g.indices, static_cast<uint64_t>(vertexCount) * instanceCount);
    CountDrawInPass(cb, static_cast<uint64_t>(vertexCount) * instanceCount);
    TF3_VK_CALL(CmdDraw, void (*)(void*, uint32_t, uint32_t, uint32_t, uint32_t))(cb, vertexCount, instanceCount, firstVertex,
                                                                                 firstInstance);
}

TF3_VK_REAL(CmdDrawIndexed);
void Wrap_CmdDrawIndexed(void* cb, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t vertexOffset,
                         uint32_t firstInstance) {
    Add(g.draws);
    Add(g.instances, instanceCount);
    Add(g.indices, static_cast<uint64_t>(indexCount) * instanceCount);
    CountDrawInPass(cb, static_cast<uint64_t>(indexCount) * instanceCount);
    TF3_VK_CALL(CmdDrawIndexed, void (*)(void*, uint32_t, uint32_t, uint32_t, int32_t, uint32_t))(
        cb, indexCount, instanceCount, firstIndex, vertexOffset, firstInstance);
}

TF3_VK_REAL(CmdDrawIndirect);
void Wrap_CmdDrawIndirect(void* cb, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    Add(g.indirectCalls);
    Add(g.indirectDraws, drawCount);
    TF3_VK_CALL(CmdDrawIndirect, void (*)(void*, uint64_t, uint64_t, uint32_t, uint32_t))(cb, buffer, offset, drawCount, stride);
}

TF3_VK_REAL(CmdDrawIndexedIndirect);
void Wrap_CmdDrawIndexedIndirect(void* cb, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    Add(g.indirectCalls);
    Add(g.indirectDraws, drawCount);
    TF3_VK_CALL(CmdDrawIndexedIndirect, void (*)(void*, uint64_t, uint64_t, uint32_t, uint32_t))(cb, buffer, offset, drawCount,
                                                                                                stride);
}

using IndirectCountFn = void (*)(void*, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t);

TF3_VK_REAL(CmdDrawIndirectCount);
void Wrap_CmdDrawIndirectCount(void* cb, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countOffset,
                               uint32_t maxDrawCount, uint32_t stride) {
    Add(g.indirectCalls);
    Add(g.indirectDraws, maxDrawCount);
    TF3_VK_CALL(CmdDrawIndirectCount, IndirectCountFn)(cb, buffer, offset, countBuffer, countOffset, maxDrawCount, stride);
}

TF3_VK_REAL(CmdDrawIndexedIndirectCount);
void Wrap_CmdDrawIndexedIndirectCount(void* cb, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countOffset,
                                      uint32_t maxDrawCount, uint32_t stride) {
    Add(g.indirectCalls);
    Add(g.indirectDraws, maxDrawCount);
    TF3_VK_CALL(CmdDrawIndexedIndirectCount, IndirectCountFn)(cb, buffer, offset, countBuffer, countOffset, maxDrawCount,
                                                              stride);
}

TF3_VK_REAL(CmdBindPipeline);
void Wrap_CmdBindPipeline(void* cb, uint32_t bindPoint, uint64_t pipeline) {
    Add(g.pipelineBinds);
    TF3_VK_CALL(CmdBindPipeline, void (*)(void*, uint32_t, uint64_t))(cb, bindPoint, pipeline);
}

TF3_VK_REAL(CmdBindDescriptorSets);
void Wrap_CmdBindDescriptorSets(void* cb, uint32_t bindPoint, uint64_t layout, uint32_t firstSet, uint32_t setCount,
                                const uint64_t* sets, uint32_t dynamicOffsetCount, const uint32_t* dynamicOffsets) {
    Add(g.descriptorSetBinds);
    TF3_VK_CALL(CmdBindDescriptorSets,
                void (*)(void*, uint32_t, uint64_t, uint32_t, uint32_t, const uint64_t*, uint32_t, const uint32_t*))(
        cb, bindPoint, layout, firstSet, setCount, sets, dynamicOffsetCount, dynamicOffsets);
}

TF3_VK_REAL(CmdBindVertexBuffers);
void Wrap_CmdBindVertexBuffers(void* cb, uint32_t firstBinding, uint32_t bindingCount, const uint64_t* buffers,
                               const uint64_t* offsets) {
    Add(g.vertexBufferBinds);
    TF3_VK_CALL(CmdBindVertexBuffers, void (*)(void*, uint32_t, uint32_t, const uint64_t*, const uint64_t*))(
        cb, firstBinding, bindingCount, buffers, offsets);
}

TF3_VK_REAL(UpdateDescriptorSets);
void Wrap_UpdateDescriptorSets(void* device, uint32_t writeCount, const void* writes, uint32_t copyCount, const void* copies) {
    Add(g.descriptorSetUpdates, static_cast<uint64_t>(writeCount) + copyCount);
    TF3_VK_CALL(UpdateDescriptorSets, void (*)(void*, uint32_t, const void*, uint32_t, const void*))(device, writeCount, writes,
                                                                                                    copyCount, copies);
}

TF3_VK_REAL(CmdBeginRenderPass);
void Wrap_CmdBeginRenderPass(void* cb, const RenderPassBeginInfo* info, uint32_t contents) {
    SetCbPass(cb, CountPass(info ? info->width : 0, info ? info->height : 0));
    TF3_VK_CALL(CmdBeginRenderPass, void (*)(void*, const RenderPassBeginInfo*, uint32_t))(cb, info, contents);
}

TF3_VK_REAL(CmdBeginRendering);
void Wrap_CmdBeginRendering(void* cb, const RenderingInfo* info) {
    SetCbPass(cb, CountPass(info ? info->width : 0, info ? info->height : 0));
    TF3_VK_CALL(CmdBeginRendering, void (*)(void*, const RenderingInfo*))(cb, info);
}

TF3_VK_REAL(CmdBeginRenderingKHR);
void Wrap_CmdBeginRenderingKHR(void* cb, const RenderingInfo* info) {
    SetCbPass(cb, CountPass(info ? info->width : 0, info ? info->height : 0));
    TF3_VK_CALL(CmdBeginRenderingKHR, void (*)(void*, const RenderingInfo*))(cb, info);
}

TF3_VK_REAL(CreateGraphicsPipelines);
int32_t Wrap_CreateGraphicsPipelines(void* device, uint64_t cache, uint32_t count, const void* infos, const void* allocator,
                                     uint64_t* pipelines) {
    Timed timed(g.ticksCreatePipelines);
    Add(g.pipelinesCreated, count);
    return TF3_VK_CALL(CreateGraphicsPipelines, int32_t (*)(void*, uint64_t, uint32_t, const void*, const void*, uint64_t*))(
        device, cache, count, infos, allocator, pipelines);
}

TF3_VK_REAL(CreateShaderModule);
int32_t Wrap_CreateShaderModule(void* device, const void* info, const void* allocator, uint64_t* module) {
    Add(g.shaderModulesCreated);
    return TF3_VK_CALL(CreateShaderModule, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator,
                                                                                                  module);
}

TF3_VK_REAL(CreateBuffer);
int32_t Wrap_CreateBuffer(void* device, const void* info, const void* allocator, uint64_t* buffer) {
    Add(g.buffersCreated);
    return TF3_VK_CALL(CreateBuffer, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, buffer);
}

TF3_VK_REAL(AllocateMemory);
int32_t Wrap_AllocateMemory(void* device, const void* info, const void* allocator, uint64_t* memory) {
    Add(g.memoryAllocations);
    return TF3_VK_CALL(AllocateMemory, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator,
                                                                                              memory);
}

TF3_VK_REAL(CreateImage);
int32_t Wrap_CreateImage(void* device, const void* info, const void* allocator, uint64_t* image) {
    Add(g.imagesCreated);
    return TF3_VK_CALL(CreateImage, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, image);
}

TF3_VK_REAL(DestroyImage);
void Wrap_DestroyImage(void* device, uint64_t image, const void* allocator) {
    if (image != 0) Add(g.imagesDestroyed);
    TF3_VK_CALL(DestroyImage, void (*)(void*, uint64_t, const void*))(device, image, allocator);
}

TF3_VK_REAL(CreateImageView);
int32_t Wrap_CreateImageView(void* device, const void* info, const void* allocator, uint64_t* view) {
    Add(g.imageViewsCreated);
    return TF3_VK_CALL(CreateImageView, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, view);
}

TF3_VK_REAL(CreateSampler);
int32_t Wrap_CreateSampler(void* device, const void* info, const void* allocator, uint64_t* sampler) {
    Add(g.samplersCreated);
    return TF3_VK_CALL(CreateSampler, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, sampler);
}

TF3_VK_REAL(CmdCopyBufferToImage);
void Wrap_CmdCopyBufferToImage(void* cb, uint64_t buffer, uint64_t image, uint32_t layout, uint32_t regionCount,
                               const void* regions) {
    Add(g.imageUploads);
    Add(g.imageUploadRegions, regionCount);
    TF3_VK_CALL(CmdCopyBufferToImage, void (*)(void*, uint64_t, uint64_t, uint32_t, uint32_t, const void*))(
        cb, buffer, image, layout, regionCount, regions);
}

TF3_VK_REAL(DestroyBuffer);
void Wrap_DestroyBuffer(void* device, uint64_t buffer, const void* allocator) {
    if (buffer != 0) Add(g.buffersDestroyed);
    TF3_VK_CALL(DestroyBuffer, void (*)(void*, uint64_t, const void*))(device, buffer, allocator);
}

TF3_VK_REAL(AllocateDescriptorSets);
int32_t Wrap_AllocateDescriptorSets(void* device, const void* info, uint64_t* sets) {
    Add(g.descriptorSetAllocations);
    return TF3_VK_CALL(AllocateDescriptorSets, int32_t (*)(void*, const void*, uint64_t*))(device, info, sets);
}

TF3_VK_REAL(CreateSwapchainKHR);
int32_t Wrap_CreateSwapchainKHR(void* device, const SwapchainCreateInfo* info, const void* allocator, uint64_t* swapchain) {
    if (info != nullptr) {
        static const char* const kModes[] = {"IMMEDIATE (no vsync)", "MAILBOX", "FIFO (vsync)", "FIFO_RELAXED"};
        TF3_LOG("vkstats: swapchain created - %ux%u, min images %u, present mode %u %s", info->width, info->height,
                info->minImageCount, info->presentMode, info->presentMode < 4 ? kModes[info->presentMode] : "");
    }
    return TF3_VK_CALL(CreateSwapchainKHR, int32_t (*)(void*, const SwapchainCreateInfo*, const void*, uint64_t*))(
        device, info, allocator, swapchain);
}

using GetProcAddrFn = VoidFn (*)(void* handle, const char* name);
GetProcAddrFn g_origGetDeviceProcAddr = nullptr;
GetProcAddrFn g_origGetInstanceProcAddr = nullptr;

TF3_VK_REAL(CreateDevice);
int32_t Wrap_CreateDevice(void* physicalDevice, const void* info, const void* allocator, void** device) {
    const int32_t result =
        TF3_VK_CALL(CreateDevice, int32_t (*)(void*, const void*, const void*, void**))(physicalDevice, info, allocator, device);
    void* instance = g_instance.load(std::memory_order_relaxed);
    if (result == 0 && instance != nullptr && g_origGetInstanceProcAddr != nullptr) {
        // VkPhysicalDeviceProperties: apiVersion, driverVersion, vendorID, deviceID, deviceType, deviceName[256], ...
        // (about 0.8 KB in all; the buffer is generously larger).
        alignas(8) static uint8_t properties[4096];
        const auto getProperties = reinterpret_cast<void (*)(void*, void*)>(
            g_origGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties"));
        if (getProperties != nullptr) {
            getProperties(physicalDevice, properties);
            uint32_t vendor = 0, type = 0;
            std::memcpy(&vendor, properties + 8, 4);
            std::memcpy(&type, properties + 16, 4);
            std::memcpy(g_deviceName, properties + 20, sizeof(g_deviceName) - 1);
            g_deviceName[sizeof(g_deviceName) - 1] = '\0';
            static const char* const kTypes[] = {"other", "integrated GPU", "discrete GPU", "virtual GPU", "CPU"};
            TF3_LOG("vkstats: the game created its Vulkan device on \"%.200s\" (vendor 0x%04x, %s)", g_deviceName, vendor,
                    type < 5 ? kTypes[type] : "?");
        }
    }
    return result;
}

struct Entry {
    const char* name;
    std::atomic<VoidFn>* real;
    VoidFn wrapper;
};

#define TF3_VK_ENTRY(name) {"vk" #name, &real_##name, reinterpret_cast<VoidFn>(&Wrap_##name)}

Entry g_entries[] = {
    TF3_VK_ENTRY(AcquireNextImageKHR),     TF3_VK_ENTRY(AcquireNextImage2KHR),
    TF3_VK_ENTRY(QueuePresentKHR),         TF3_VK_ENTRY(QueueSubmit),
    TF3_VK_ENTRY(QueueSubmit2),            TF3_VK_ENTRY(QueueSubmit2KHR),
    TF3_VK_ENTRY(WaitForFences),           TF3_VK_ENTRY(QueueWaitIdle),
    TF3_VK_ENTRY(DeviceWaitIdle),          TF3_VK_ENTRY(CmdDraw),
    TF3_VK_ENTRY(CmdDrawIndexed),          TF3_VK_ENTRY(CmdDrawIndirect),
    TF3_VK_ENTRY(CmdDrawIndexedIndirect),  TF3_VK_ENTRY(CmdDrawIndirectCount),
    TF3_VK_ENTRY(CmdDrawIndexedIndirectCount), TF3_VK_ENTRY(CmdBindPipeline),
    TF3_VK_ENTRY(CmdBindDescriptorSets),   TF3_VK_ENTRY(CmdBindVertexBuffers),
    TF3_VK_ENTRY(UpdateDescriptorSets),    TF3_VK_ENTRY(CmdBeginRenderPass),
    TF3_VK_ENTRY(CmdBeginRendering),       TF3_VK_ENTRY(CmdBeginRenderingKHR),
    TF3_VK_ENTRY(CreateGraphicsPipelines), TF3_VK_ENTRY(CreateShaderModule),
    TF3_VK_ENTRY(CreateBuffer),            TF3_VK_ENTRY(AllocateMemory),
    TF3_VK_ENTRY(CreateSwapchainKHR),      TF3_VK_ENTRY(CreateDevice),
    TF3_VK_ENTRY(CreateImage),             TF3_VK_ENTRY(DestroyImage),
    TF3_VK_ENTRY(CreateImageView),         TF3_VK_ENTRY(CreateSampler),
    TF3_VK_ENTRY(CmdCopyBufferToImage),    TF3_VK_ENTRY(DestroyBuffer),
    TF3_VK_ENTRY(AllocateDescriptorSets),
};

// ---- Lookup hooks ------------------------------------------------------------------------------------

void* g_hookedDevice = nullptr;
void* g_hookedInstance = nullptr;

VoidFn Substitute(const char* name, VoidFn real) {
    if (real == nullptr || name == nullptr) return real;
    for (Entry& entry : g_entries) {
        if (std::strcmp(entry.name, name) != 0) continue;
        if (real == entry.wrapper) return real;  // already ours
        entry.real->store(real, std::memory_order_relaxed);
        if (!g_wrapped.exchange(true)) TF3_LOG("vkstats: the game is fetching its Vulkan functions - wrappers handed out");
        return entry.wrapper;
    }
    return real;
}

VoidFn HookGetDeviceProcAddr(void* device, const char* name) { return Substitute(name, g_origGetDeviceProcAddr(device, name)); }

VoidFn HookGetInstanceProcAddr(void* instance, const char* name) {
    if (instance != nullptr) g_instance.store(instance, std::memory_order_relaxed);
    return Substitute(name, g_origGetInstanceProcAddr(instance, name));
}

} // namespace

void Install() {
    if (!config::GetBool("Profiler", "Enabled", true) || !config::GetBool("Profiler", "VulkanStats", true)) return;
    QueryPerformanceFrequency(&g_qpcFreq);
    // Loaded here so the lookups can be hooked before the game's renderer asks for its function pointers.
    const HMODULE vulkan = LoadLibraryW(L"vulkan-1.dll");
    if (vulkan == nullptr) {
        TF3_LOG("vkstats: vulkan-1.dll could not be loaded (error %lu) - Vulkan statistics unavailable", GetLastError());
        return;
    }
    g_hookedDevice = reinterpret_cast<void*>(GetProcAddress(vulkan, "vkGetDeviceProcAddr"));
    g_hookedInstance = reinterpret_cast<void*>(GetProcAddress(vulkan, "vkGetInstanceProcAddr"));
    if (g_hookedDevice == nullptr || g_hookedInstance == nullptr) {
        TF3_LOG("vkstats: vulkan-1.dll lacks vkGetDeviceProcAddr / vkGetInstanceProcAddr - Vulkan statistics unavailable");
        return;
    }
    MH_STATUS status = MH_CreateHook(g_hookedDevice, reinterpret_cast<void*>(&HookGetDeviceProcAddr),
                                     reinterpret_cast<void**>(&g_origGetDeviceProcAddr));
    if (status == MH_OK) {
        status = MH_CreateHook(g_hookedInstance, reinterpret_cast<void*>(&HookGetInstanceProcAddr),
                               reinterpret_cast<void**>(&g_origGetInstanceProcAddr));
    }
    if (status == MH_OK) status = MH_EnableHook(g_hookedDevice);
    if (status == MH_OK) status = MH_EnableHook(g_hookedInstance);
    if (status != MH_OK) {
        TF3_LOG("vkstats: hook install failed (%d) - Vulkan statistics unavailable", static_cast<int>(status));
        MH_RemoveHook(g_hookedDevice);
        MH_RemoveHook(g_hookedInstance);
        return;
    }
    g_installed = true;
    TF3_LOG("vkstats: Vulkan function lookups hooked (vkGetDeviceProcAddr, vkGetInstanceProcAddr)");
}

void Uninstall() {
    // The wrappers already handed to the game stay valid for as long as this DLL is loaded; only the
    // lookup hooks are removed.
    if (!g_installed) return;
    MH_DisableHook(g_hookedDevice);
    MH_DisableHook(g_hookedInstance);
    g_installed = false;
}

bool Active() { return g_installed && g_wrapped.load(std::memory_order_relaxed); }

Totals Snapshot() {
    Totals t;
    const auto get = [](const Counter& c) { return c.load(std::memory_order_relaxed); };
    t.frames = get(g.frames);
    t.ticksAcquire = get(g.ticksAcquire);
    t.ticksPresent = get(g.ticksPresent);
    t.ticksSubmit = get(g.ticksSubmit);
    t.ticksWaitFences = get(g.ticksWaitFences);
    t.ticksWaitIdle = get(g.ticksWaitIdle);
    t.ticksCreatePipelines = get(g.ticksCreatePipelines);
    t.submits = get(g.submits);
    t.fenceWaits = get(g.fenceWaits);
    t.draws = get(g.draws);
    t.indirectCalls = get(g.indirectCalls);
    t.indirectDraws = get(g.indirectDraws);
    t.instances = get(g.instances);
    t.indices = get(g.indices);
    t.pipelineBinds = get(g.pipelineBinds);
    t.descriptorSetBinds = get(g.descriptorSetBinds);
    t.descriptorSetUpdates = get(g.descriptorSetUpdates);
    t.vertexBufferBinds = get(g.vertexBufferBinds);
    t.renderPasses = get(g.renderPasses);
    t.pipelinesCreated = get(g.pipelinesCreated);
    t.shaderModulesCreated = get(g.shaderModulesCreated);
    t.buffersCreated = get(g.buffersCreated);
    t.memoryAllocations = get(g.memoryAllocations);
    t.imagesCreated = get(g.imagesCreated);
    t.imagesDestroyed = get(g.imagesDestroyed);
    t.imageViewsCreated = get(g.imageViewsCreated);
    t.samplersCreated = get(g.samplersCreated);
    t.imageUploads = get(g.imageUploads);
    t.imageUploadRegions = get(g.imageUploadRegions);
    t.buffersDestroyed = get(g.buffersDestroyed);
    t.descriptorSetAllocations = get(g.descriptorSetAllocations);
    return t;
}

PassSizes SnapshotPassSizes() {
    PassSizes sizes;
    for (int i = 0; i < kMaxPassSizes; ++i) {
        const uint64_t key = g_passKey[i].load(std::memory_order_relaxed);
        sizes.width[i] = static_cast<uint32_t>(key >> 32);
        sizes.height[i] = static_cast<uint32_t>(key);
        sizes.count[i] = g_passCount[i].load(std::memory_order_relaxed);
        sizes.draws[i] = g_passDraws[i].load(std::memory_order_relaxed);
        sizes.indices[i] = g_passIndices[i].load(std::memory_order_relaxed);
    }
    sizes.other = g_passOther.load(std::memory_order_relaxed);
    return sizes;
}

uint64_t LastAcquireTimeout() { return g_lastAcquireTimeout.load(std::memory_order_relaxed); }

const char* DeviceName() { return g_deviceName; }

double TicksToMs(uint64_t ticks) {
    return g_qpcFreq.QuadPart ? 1000.0 * static_cast<double>(ticks) / static_cast<double>(g_qpcFreq.QuadPart) : 0.0;
}

void FrameTimesMs(uint64_t firstFrame, uint64_t lastFrame, std::vector<float>* out) {
    out->clear();
    if (lastFrame - firstFrame > kFrameRing) firstFrame = lastFrame - kFrameRing;
    for (uint64_t frame = firstFrame; frame < lastFrame; ++frame) {
        const float ms = g_frameMs[frame & (kFrameRing - 1)].load(std::memory_order_relaxed);
        if (ms > 0.0f) out->push_back(ms);
    }
}

} // namespace tf3opt::vkstats
