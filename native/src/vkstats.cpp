#include "vkstats.h"

#include "config.h"
#include "log.h"

#include <windows.h>

#include <atomic>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "MinHook.h"

namespace tf3api::vkstats {
namespace {

using Counter = std::atomic<uint64_t>;

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
std::atomic<void*> g_device{nullptr}, g_physicalDevice{nullptr};
Listener g_listener;

// VkQueue -> queue family, as handed out by vkGetDeviceQueue.
constexpr int kMaxQueues = 16;
std::atomic<void*> g_queueHandle[kMaxQueues];
std::atomic<uint32_t> g_queueFamily[kMaxQueues];
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

// ---- Pass trace -----------------------------------------------------------------------------------------
// One frame's render passes in the order they were recorded, written to the log: which render pass and
// framebuffer each used, its size and how much it drew. Taken a few times per session on its own. It is the
// map needed to draw the overlay UNDER the game's interface instead of over it: the interface is one or
// more of the full-size passes near the end of the frame, and this shows which.
// Passes are recorded by several threads, so "order recorded" is close to, but not always, the order run.
struct TraceEntry {
    uintptr_t cb;
    uint64_t renderPass, framebuffer;
    uint32_t width, height;
    uint32_t draws;
    uint64_t indices;
    bool dynamic;  // vkCmdBeginRendering, no render pass object: renderPass holds the first colour
                   // attachment's image view and framebuffer the depth attachment's
    uint32_t colours, loadOp;  // dynamic only: colour attachment count, and the first one's load operation
    uint32_t firstDraws[12];   // index (or vertex) count of each of the first draws, in order
};
constexpr size_t kMaxTraceEntries = 600;
std::mutex g_traceMutex;
std::vector<TraceEntry> g_trace;
std::atomic<bool> g_traceRecording{false};
std::atomic<int> g_cbTrace[kCbSlots];
constexpr uint64_t kTraceFrames[] = {2400, 2401 + 2, 9000, 9003, 30000};  // frames at which a trace is taken (pairs: two frames running)

void TraceBegin(void* cb, uint64_t renderPass, uint64_t framebuffer, uint32_t width, uint32_t height, bool dynamic, uint32_t colours = 0,
                uint32_t loadOp = 0) {
    if (!g_traceRecording.load(std::memory_order_relaxed)) return;
    std::lock_guard<std::mutex> lock(g_traceMutex);
    if (g_trace.size() >= kMaxTraceEntries) return;
    g_trace.push_back({reinterpret_cast<uintptr_t>(cb), renderPass, framebuffer, width, height, 0, 0, dynamic, colours, loadOp, {}});
    g_cbTrace[CbSlot(cb)].store(static_cast<int>(g_trace.size()) - 1, std::memory_order_relaxed);
}

void TraceDraw(void* cb, uint64_t indices) {
    if (!g_traceRecording.load(std::memory_order_relaxed)) return;
    std::lock_guard<std::mutex> lock(g_traceMutex);
    const int index = g_cbTrace[CbSlot(cb)].load(std::memory_order_relaxed);
    if (index < 0 || static_cast<size_t>(index) >= g_trace.size() || g_trace[index].cb != reinterpret_cast<uintptr_t>(cb)) return;
    if (g_trace[index].draws < 12) g_trace[index].firstDraws[g_trace[index].draws] = static_cast<uint32_t>(indices);
    ++g_trace[index].draws;
    g_trace[index].indices += indices;
}

// Called at every present: starts a trace on the chosen frames and writes it out one frame later.
void TraceFrame(uint64_t frame) {
    if (g_traceRecording.load(std::memory_order_relaxed)) {
        g_traceRecording.store(false, std::memory_order_relaxed);
        std::vector<TraceEntry> trace;
        {
            std::lock_guard<std::mutex> lock(g_traceMutex);
            trace.swap(g_trace);
        }
        uint32_t fullWidth = 0;
        for (const TraceEntry& e : trace) fullWidth = e.width > fullWidth ? e.width : fullWidth;
        TF3_LOG("pass trace: frame %llu, %zu render passes recorded (those at least 1000 wide are listed; * = no render pass object)",
                static_cast<unsigned long long>(frame), trace.size());
        size_t listed = 0;
        for (size_t i = 0; i < trace.size(); ++i) {
            const TraceEntry& e = trace[i];
            if (e.width < 1000 || listed >= 80) continue;
            ++listed;
            if (e.dynamic) {
                TF3_LOG("  pass %3zu  %4ux%-4u  * colour view %012llx (%u colour, %s)  depth view %012llx  buffer %06llx  %5u draws %9llu indices",
                        i, e.width, e.height, static_cast<unsigned long long>(e.renderPass), e.colours,
                        e.loadOp == 0 ? "load" : (e.loadOp == 1 ? "clear" : "dont-care"), static_cast<unsigned long long>(e.framebuffer),
                        static_cast<unsigned long long>(e.cb & 0xFFFFFF), e.draws, static_cast<unsigned long long>(e.indices));
            } else {
                TF3_LOG("  pass %3zu  %4ux%-4u  pass %012llx  framebuffer %012llx  buffer %06llx  %5u draws %9llu indices", i, e.width, e.height,
                        static_cast<unsigned long long>(e.renderPass), static_cast<unsigned long long>(e.framebuffer),
                        static_cast<unsigned long long>(e.cb & 0xFFFFFF), e.draws, static_cast<unsigned long long>(e.indices));
            }
            if (e.draws > 0 && e.draws <= 12) {
                char text[160];
                int used = 0;
                for (uint32_t d = 0; d < e.draws && used < 140; ++d) used += snprintf(text + used, sizeof(text) - used, " %u", e.firstDraws[d]);
                TF3_LOG("            its draws, in order (indices each):%s", text);
            }
        }
        return;
    }
    for (const uint64_t at : kTraceFrames) {
        if (frame == at) {
            {
                std::lock_guard<std::mutex> lock(g_traceMutex);
                g_trace.clear();
                g_trace.reserve(kMaxTraceEntries);
            }
            g_traceRecording.store(true, std::memory_order_relaxed);
        }
    }
}

void CountDrawInPass(void* cb, uint64_t indices) {
    TraceDraw(cb, indices);
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
struct RenderingAttachmentInfo {
    uint32_t sType;
    const void* pNext;
    uint64_t imageView;
    uint32_t imageLayout;
    uint32_t resolveMode;
    uint64_t resolveImageView;
    uint32_t resolveImageLayout;
    uint32_t loadOp;   // 0 = load what is there, 1 = clear, 2 = don't care
    uint32_t storeOp;
    uint32_t clearValue[4];
};
struct RenderingInfo {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    int32_t x, y;
    uint32_t width, height;
    uint32_t layerCount;
    uint32_t viewMask;
    uint32_t colorAttachmentCount;
    const RenderingAttachmentInfo* colorAttachments;
    const RenderingAttachmentInfo* depthAttachment;
    const RenderingAttachmentInfo* stencilAttachment;
};
static_assert(offsetof(RenderingInfo, colorAttachments) == 0x30, "VkRenderingInfo layout");
static_assert(offsetof(RenderingAttachmentInfo, loadOp) == 0x2C, "VkRenderingAttachmentInfo layout");
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
    if (g_listener.beforePresent != nullptr) info = g_listener.beforePresent(queue, info);
    const uint64_t start = Now();
    const int32_t result = TF3_VK_CALL(QueuePresentKHR, int32_t (*)(void*, const void*))(queue, info);
    const uint64_t end = Now();
    Add(g.ticksPresent, end - start);
    const uint64_t previous = g_lastPresentTicks.exchange(end, std::memory_order_relaxed);
    const uint64_t frame = g.frames.fetch_add(1, std::memory_order_relaxed);
    TraceFrame(frame);
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

// Command buffers on which a listener waits for the game's first draw of the pass just begun (see
// Listener::afterFirstDraw). Checked on every draw, so the common case is one load of a counter.
std::atomic<int> g_waitingForDraw{0};
void AfterDraw(void* cb, uint64_t indices);

TF3_VK_REAL(CmdDraw);
void Wrap_CmdDraw(void* cb, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) {
    Add(g.draws);
    Add(g.instances, instanceCount);
    Add(g.indices, static_cast<uint64_t>(vertexCount) * instanceCount);
    CountDrawInPass(cb, static_cast<uint64_t>(vertexCount) * instanceCount);
    TF3_VK_CALL(CmdDraw, void (*)(void*, uint32_t, uint32_t, uint32_t, uint32_t))(cb, vertexCount, instanceCount, firstVertex,
                                                                                 firstInstance);
    if (g_waitingForDraw.load(std::memory_order_relaxed) > 0) AfterDraw(cb, static_cast<uint64_t>(vertexCount) * instanceCount);
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
    if (g_waitingForDraw.load(std::memory_order_relaxed) > 0) AfterDraw(cb, static_cast<uint64_t>(indexCount) * instanceCount);
}

TF3_VK_REAL(CmdDrawIndirect);
void Wrap_CmdDrawIndirect(void* cb, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    Add(g.indirectCalls);
    Add(g.indirectDraws, drawCount);
    TF3_VK_CALL(CmdDrawIndirect, void (*)(void*, uint64_t, uint64_t, uint32_t, uint32_t))(cb, buffer, offset, drawCount, stride);
    if (g_waitingForDraw.load(std::memory_order_relaxed) > 0) AfterDraw(cb, 0);
}

TF3_VK_REAL(CmdDrawIndexedIndirect);
void Wrap_CmdDrawIndexedIndirect(void* cb, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    Add(g.indirectCalls);
    Add(g.indirectDraws, drawCount);
    TF3_VK_CALL(CmdDrawIndexedIndirect, void (*)(void*, uint64_t, uint64_t, uint32_t, uint32_t))(cb, buffer, offset, drawCount,
                                                                                                stride);
    if (g_waitingForDraw.load(std::memory_order_relaxed) > 0) AfterDraw(cb, 0);
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

// ---- The game's drawing state per command buffer ----------------------------------------------------------
// Kept so that a listener can draw inside the game's command buffer (see Listener::beforeBeginRenderPass) and
// the game's state be put back afterwards: a command buffer's state carries on across render passes, and the
// game may rely on something it bound earlier. Only what is cheap to follow is followed, and only while a
// listener wants it. Graphics bind point only.
constexpr uint32_t kTrackedSets = 4, kTrackedOffsets = 8, kTrackedBindings = 8, kTrackedPush = 256;
struct CbState {
    bool waitingForDraw = false;   // a listener wants to be called after the next draw
    bool hasPipeline = false, hasViewport = false, hasScissor = false, hasIndex = false, hasPush = false;
    uint64_t pipeline = 0;
    float viewport[6] = {};
    int32_t scissor[4] = {};
    uint64_t indexBuffer = 0, indexOffset = 0;
    uint32_t indexType = 0;
    struct Binding {
        bool set = false;
        uint64_t buffer = 0, offset = 0;
    } bindings[kTrackedBindings];
    struct Set {
        bool set = false, restorable = false;
        uint64_t layout = 0, handle = 0;
        uint32_t offsetCount = 0;
        uint32_t offsets[kTrackedOffsets] = {};
    } sets[kTrackedSets];
    uint64_t pushLayout = 0;
    uint32_t pushStages = 0, pushOffset = 0, pushSize = 0;
    unsigned char push[kTrackedPush] = {};
};
std::atomic<bool> g_trackState{false};
std::mutex g_cbStateMutex;
std::unordered_map<void*, std::unique_ptr<CbState>> g_cbStates;

// The state record of a command buffer; one lookup per thread and command buffer, then a cached pointer.
CbState* StateOf(void* cb) {
    thread_local void* lastCb = nullptr;
    thread_local CbState* last = nullptr;
    if (cb == lastCb && last != nullptr) return last;
    std::lock_guard<std::mutex> lock(g_cbStateMutex);
    std::unique_ptr<CbState>& slot = g_cbStates[cb];
    if (!slot) slot = std::make_unique<CbState>();
    lastCb = cb;
    last = slot.get();
    return last;
}

TF3_VK_REAL(BeginCommandBuffer);
int32_t Wrap_BeginCommandBuffer(void* cb, const void* info) {
    // a command buffer begun anew has no state: what was followed belongs to its last recording
    if (g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        if (s->waitingForDraw) g_waitingForDraw.fetch_sub(1, std::memory_order_relaxed);
        *s = CbState{};
    }
    return TF3_VK_CALL(BeginCommandBuffer, int32_t (*)(void*, const void*))(cb, info);
}

TF3_VK_REAL(CmdBindPipeline);
void Wrap_CmdBindPipeline(void* cb, uint32_t bindPoint, uint64_t pipeline) {
    Add(g.pipelineBinds);
    if (bindPoint == 0 && g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        s->hasPipeline = true;
        s->pipeline = pipeline;
    }
    TF3_VK_CALL(CmdBindPipeline, void (*)(void*, uint32_t, uint64_t))(cb, bindPoint, pipeline);
}

TF3_VK_REAL(CmdBindDescriptorSets);
void Wrap_CmdBindDescriptorSets(void* cb, uint32_t bindPoint, uint64_t layout, uint32_t firstSet, uint32_t setCount,
                                const uint64_t* sets, uint32_t dynamicOffsetCount, const uint32_t* dynamicOffsets) {
    Add(g.descriptorSetBinds);
    if (bindPoint == 0 && sets != nullptr && g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        for (uint32_t i = 0; i < setCount && firstSet + i < kTrackedSets; ++i) {
            CbState::Set& slot = s->sets[firstSet + i];
            slot.set = true;
            slot.layout = layout;
            slot.handle = sets[i];
            // Dynamic offsets are handed out across the sets of one call in an order only the layouts know.
            // A single set bound alone can be bound again as it was; several with offsets cannot.
            slot.offsetCount = 0;
            slot.restorable = dynamicOffsetCount == 0 || (setCount == 1 && dynamicOffsetCount <= kTrackedOffsets && dynamicOffsets != nullptr);
            if (slot.restorable && dynamicOffsetCount > 0) {
                slot.offsetCount = dynamicOffsetCount;
                std::memcpy(slot.offsets, dynamicOffsets, dynamicOffsetCount * sizeof(uint32_t));
            }
        }
    }
    TF3_VK_CALL(CmdBindDescriptorSets,
                void (*)(void*, uint32_t, uint64_t, uint32_t, uint32_t, const uint64_t*, uint32_t, const uint32_t*))(
        cb, bindPoint, layout, firstSet, setCount, sets, dynamicOffsetCount, dynamicOffsets);
}

TF3_VK_REAL(CmdBindVertexBuffers);
void Wrap_CmdBindVertexBuffers(void* cb, uint32_t firstBinding, uint32_t bindingCount, const uint64_t* buffers,
                               const uint64_t* offsets) {
    Add(g.vertexBufferBinds);
    if (buffers != nullptr && offsets != nullptr && g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        for (uint32_t i = 0; i < bindingCount && firstBinding + i < kTrackedBindings; ++i) {
            s->bindings[firstBinding + i] = {true, buffers[i], offsets[i]};
        }
    }
    TF3_VK_CALL(CmdBindVertexBuffers, void (*)(void*, uint32_t, uint32_t, const uint64_t*, const uint64_t*))(
        cb, firstBinding, bindingCount, buffers, offsets);
}

TF3_VK_REAL(CmdBindIndexBuffer);
void Wrap_CmdBindIndexBuffer(void* cb, uint64_t buffer, uint64_t offset, uint32_t indexType) {
    if (g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        s->hasIndex = true;
        s->indexBuffer = buffer;
        s->indexOffset = offset;
        s->indexType = indexType;
    }
    TF3_VK_CALL(CmdBindIndexBuffer, void (*)(void*, uint64_t, uint64_t, uint32_t))(cb, buffer, offset, indexType);
}

TF3_VK_REAL(CmdSetViewport);
void Wrap_CmdSetViewport(void* cb, uint32_t first, uint32_t count, const float* viewports) {
    if (first == 0 && count > 0 && viewports != nullptr && g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        s->hasViewport = true;
        std::memcpy(s->viewport, viewports, sizeof(s->viewport));
    }
    TF3_VK_CALL(CmdSetViewport, void (*)(void*, uint32_t, uint32_t, const float*))(cb, first, count, viewports);
}

TF3_VK_REAL(CmdSetScissor);
void Wrap_CmdSetScissor(void* cb, uint32_t first, uint32_t count, const int32_t* scissors) {
    if (first == 0 && count > 0 && scissors != nullptr && g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        s->hasScissor = true;
        std::memcpy(s->scissor, scissors, sizeof(s->scissor));
    }
    TF3_VK_CALL(CmdSetScissor, void (*)(void*, uint32_t, uint32_t, const int32_t*))(cb, first, count, scissors);
}

TF3_VK_REAL(CmdPushConstants);
void Wrap_CmdPushConstants(void* cb, uint64_t layout, uint32_t stages, uint32_t offset, uint32_t size, const void* values) {
    if (values != nullptr && g_trackState.load(std::memory_order_relaxed)) {
        CbState* s = StateOf(cb);
        s->hasPush = size <= kTrackedPush;
        if (s->hasPush) {
            s->pushLayout = layout;
            s->pushStages = stages;
            s->pushOffset = offset;
            s->pushSize = size;
            std::memcpy(s->push, values, size);
        }
    }
    TF3_VK_CALL(CmdPushConstants, void (*)(void*, uint64_t, uint32_t, uint32_t, uint32_t, const void*))(cb, layout, stages, offset, size, values);
}

// Puts the game's state back on a command buffer after a listener drew into it.
void RestoreState(void* cb) {
    const CbState state = *StateOf(cb);
    if (state.hasPipeline && real_CmdBindPipeline.load() != nullptr) {
        TF3_VK_CALL(CmdBindPipeline, void (*)(void*, uint32_t, uint64_t))(cb, 0, state.pipeline);
    }
    if (state.hasViewport && real_CmdSetViewport.load() != nullptr) {
        TF3_VK_CALL(CmdSetViewport, void (*)(void*, uint32_t, uint32_t, const float*))(cb, 0, 1, state.viewport);
    }
    if (state.hasScissor && real_CmdSetScissor.load() != nullptr) {
        TF3_VK_CALL(CmdSetScissor, void (*)(void*, uint32_t, uint32_t, const int32_t*))(cb, 0, 1, state.scissor);
    }
    if (real_CmdBindVertexBuffers.load() != nullptr) {
        for (uint32_t i = 0; i < kTrackedBindings; ++i) {
            if (!state.bindings[i].set) continue;
            TF3_VK_CALL(CmdBindVertexBuffers, void (*)(void*, uint32_t, uint32_t, const uint64_t*, const uint64_t*))(
                cb, i, 1, &state.bindings[i].buffer, &state.bindings[i].offset);
        }
    }
    if (state.hasIndex && real_CmdBindIndexBuffer.load() != nullptr) {
        TF3_VK_CALL(CmdBindIndexBuffer, void (*)(void*, uint64_t, uint64_t, uint32_t))(cb, state.indexBuffer, state.indexOffset, state.indexType);
    }
    if (real_CmdBindDescriptorSets.load() != nullptr) {
        for (uint32_t i = 0; i < kTrackedSets; ++i) {
            const CbState::Set& set = state.sets[i];
            if (!set.set || !set.restorable) continue;
            TF3_VK_CALL(CmdBindDescriptorSets,
                        void (*)(void*, uint32_t, uint64_t, uint32_t, uint32_t, const uint64_t*, uint32_t, const uint32_t*))(
                cb, 0, set.layout, i, 1, &set.handle, set.offsetCount, set.offsetCount > 0 ? set.offsets : nullptr);
        }
    }
    if (state.hasPush && real_CmdPushConstants.load() != nullptr) {
        TF3_VK_CALL(CmdPushConstants, void (*)(void*, uint64_t, uint32_t, uint32_t, uint32_t, const void*))(
            cb, state.pushLayout, state.pushStages, state.pushOffset, state.pushSize, state.push);
    }
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
    if (info != nullptr) TraceBegin(cb, info->renderPass, info->framebuffer, info->width, info->height, false);
    if (info != nullptr && g_listener.beforeBeginRenderPass != nullptr) {
        // whoever waited for a draw in the pass before this one waits no longer: that pass had none
        CbState* s = StateOf(cb);
        if (s->waitingForDraw) {
            s->waitingForDraw = false;
            g_waitingForDraw.fetch_sub(1, std::memory_order_relaxed);
        }
        const int answer = g_listener.beforeBeginRenderPass(cb, info);
        if (answer == 1) {
            RestoreState(cb);
        } else if (answer == 2 && g_listener.afterFirstDraw != nullptr) {
            s->waitingForDraw = true;
            g_waitingForDraw.fetch_add(1, std::memory_order_relaxed);
        }
    }
    TF3_VK_CALL(CmdBeginRenderPass, void (*)(void*, const RenderPassBeginInfo*, uint32_t))(cb, info, contents);
}

void AfterDraw(void* cb, uint64_t indices) {
    CbState* s = StateOf(cb);
    if (!s->waitingForDraw) return;
    s->waitingForDraw = false;
    g_waitingForDraw.fetch_sub(1, std::memory_order_relaxed);
    if (g_listener.afterFirstDraw != nullptr && g_listener.afterFirstDraw(cb, indices)) RestoreState(cb);
}

TF3_VK_REAL(CreateFramebuffer);
int32_t Wrap_CreateFramebuffer(void* device, const void* info, const void* allocator, uint64_t* framebuffer) {
    const int32_t result = TF3_VK_CALL(CreateFramebuffer, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, framebuffer);
    if (result == 0 && info != nullptr && framebuffer != nullptr && g_listener.framebufferCreated != nullptr) g_listener.framebufferCreated(info, *framebuffer);
    return result;
}

TF3_VK_REAL(DestroyFramebuffer);
void Wrap_DestroyFramebuffer(void* device, uint64_t framebuffer, const void* allocator) {
    if (framebuffer != 0 && g_listener.framebufferDestroying != nullptr) g_listener.framebufferDestroying(framebuffer);
    TF3_VK_CALL(DestroyFramebuffer, void (*)(void*, uint64_t, const void*))(device, framebuffer, allocator);
}

TF3_VK_REAL(CreateRenderPass);
int32_t Wrap_CreateRenderPass(void* device, const void* info, const void* allocator, uint64_t* renderPass) {
    const int32_t result = TF3_VK_CALL(CreateRenderPass, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, renderPass);
    if (result == 0 && info != nullptr && renderPass != nullptr && g_listener.renderPassCreated != nullptr) g_listener.renderPassCreated(info, *renderPass, 1);
    return result;
}

TF3_VK_REAL(CreateRenderPass2);
int32_t Wrap_CreateRenderPass2(void* device, const void* info, const void* allocator, uint64_t* renderPass) {
    const int32_t result = TF3_VK_CALL(CreateRenderPass2, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, renderPass);
    if (result == 0 && info != nullptr && renderPass != nullptr && g_listener.renderPassCreated != nullptr) g_listener.renderPassCreated(info, *renderPass, 2);
    return result;
}

TF3_VK_REAL(CreateRenderPass2KHR);
int32_t Wrap_CreateRenderPass2KHR(void* device, const void* info, const void* allocator, uint64_t* renderPass) {
    const int32_t result = TF3_VK_CALL(CreateRenderPass2KHR, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, renderPass);
    if (result == 0 && info != nullptr && renderPass != nullptr && g_listener.renderPassCreated != nullptr) g_listener.renderPassCreated(info, *renderPass, 2);
    return result;
}

TF3_VK_REAL(DestroyRenderPass);
void Wrap_DestroyRenderPass(void* device, uint64_t renderPass, const void* allocator) {
    if (renderPass != 0 && g_listener.renderPassDestroying != nullptr) g_listener.renderPassDestroying(renderPass);
    TF3_VK_CALL(DestroyRenderPass, void (*)(void*, uint64_t, const void*))(device, renderPass, allocator);
}

TF3_VK_REAL(DestroyImageView);
void Wrap_DestroyImageView(void* device, uint64_t view, const void* allocator) {
    if (view != 0 && g_listener.imageViewDestroying != nullptr) g_listener.imageViewDestroying(view);
    TF3_VK_CALL(DestroyImageView, void (*)(void*, uint64_t, const void*))(device, view, allocator);
}

// A pass begun without a render pass object: note its first colour attachment and its depth attachment.
void TraceDynamic(void* cb, const RenderingInfo* info) {
    if (info == nullptr || !g_traceRecording.load(std::memory_order_relaxed)) return;
    const RenderingAttachmentInfo* colour = (info->colorAttachmentCount > 0) ? info->colorAttachments : nullptr;
    TraceBegin(cb, colour != nullptr ? colour->imageView : 0, info->depthAttachment != nullptr ? info->depthAttachment->imageView : 0, info->width,
               info->height, true, info->colorAttachmentCount, colour != nullptr ? colour->loadOp : 0);
}

TF3_VK_REAL(CmdBeginRendering);
void Wrap_CmdBeginRendering(void* cb, const RenderingInfo* info) {
    SetCbPass(cb, CountPass(info ? info->width : 0, info ? info->height : 0));
    TraceDynamic(cb, info);
    TF3_VK_CALL(CmdBeginRendering, void (*)(void*, const RenderingInfo*))(cb, info);
}

TF3_VK_REAL(CmdBeginRenderingKHR);
void Wrap_CmdBeginRenderingKHR(void* cb, const RenderingInfo* info) {
    SetCbPass(cb, CountPass(info ? info->width : 0, info ? info->height : 0));
    TraceDynamic(cb, info);
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
    const int32_t result = TF3_VK_CALL(CreateImageView, int32_t (*)(void*, const void*, const void*, uint64_t*))(device, info, allocator, view);
    if (result == 0 && info != nullptr && view != nullptr && g_listener.imageViewCreated != nullptr) g_listener.imageViewCreated(info, *view);
    return result;
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
    // Replacing a swapchain retires the old one: anything drawn into its images must be let go first.
    if (info != nullptr && info->oldSwapchain != 0 && g_listener.swapchainDestroying != nullptr) {
        g_listener.swapchainDestroying(info->oldSwapchain);
    }
    const int32_t result = TF3_VK_CALL(CreateSwapchainKHR, int32_t (*)(void*, const SwapchainCreateInfo*, const void*, uint64_t*))(
        device, info, allocator, swapchain);
    if (result == 0 && info != nullptr && swapchain != nullptr && g_listener.swapchainCreated != nullptr) {
        g_listener.swapchainCreated(*swapchain, info->imageFormat, info->width, info->height);
    }
    // the swapchain's images, told before the game makes its views and framebuffers of them
    if (result == 0 && swapchain != nullptr && g_listener.swapchainImages != nullptr) {
        using GetImagesFn = int32_t (*)(void*, uint64_t, uint32_t*, uint64_t*);
        const auto getImages = reinterpret_cast<GetImagesFn>(DeviceProc("vkGetSwapchainImagesKHR"));
        uint32_t count = 0;
        if (getImages != nullptr && getImages(device, *swapchain, &count, nullptr) == 0 && count > 0 && count <= 16) {
            uint64_t images[16] = {};
            if (getImages(device, *swapchain, &count, images) == 0) g_listener.swapchainImages(*swapchain, images, count);
        }
    }
    return result;
}

TF3_VK_REAL(DestroySwapchainKHR);
void Wrap_DestroySwapchainKHR(void* device, uint64_t swapchain, const void* allocator) {
    if (swapchain != 0 && g_listener.swapchainDestroying != nullptr) g_listener.swapchainDestroying(swapchain);
    TF3_VK_CALL(DestroySwapchainKHR, void (*)(void*, uint64_t, const void*))(device, swapchain, allocator);
}

TF3_VK_REAL(DestroyDevice);
void Wrap_DestroyDevice(void* device, const void* allocator) {
    if (device != nullptr && device == g_device.load(std::memory_order_relaxed)) {
        if (g_listener.deviceDestroying != nullptr) g_listener.deviceDestroying();
        g_device.store(nullptr, std::memory_order_relaxed);
    }
    TF3_VK_CALL(DestroyDevice, void (*)(void*, const void*))(device, allocator);
}

TF3_VK_REAL(GetDeviceQueue);
void Wrap_GetDeviceQueue(void* device, uint32_t family, uint32_t index, void** queue) {
    TF3_VK_CALL(GetDeviceQueue, void (*)(void*, uint32_t, uint32_t, void**))(device, family, index, queue);
    if (queue == nullptr || *queue == nullptr) return;
    for (int i = 0; i < kMaxQueues; ++i) {
        void* current = g_queueHandle[i].load(std::memory_order_relaxed);
        if (current == *queue) return;
        if (current == nullptr) {
            g_queueFamily[i].store(family, std::memory_order_relaxed);
            g_queueHandle[i].store(*queue, std::memory_order_relaxed);
            return;
        }
    }
}

using GetProcAddrFn = VoidFn (*)(void* handle, const char* name);
GetProcAddrFn g_origGetDeviceProcAddr = nullptr;
GetProcAddrFn g_origGetInstanceProcAddr = nullptr;

TF3_VK_REAL(CreateDevice);
int32_t Wrap_CreateDevice(void* physicalDevice, const void* info, const void* allocator, void** device) {
    const int32_t result =
        TF3_VK_CALL(CreateDevice, int32_t (*)(void*, const void*, const void*, void**))(physicalDevice, info, allocator, device);
    void* instance = g_instance.load(std::memory_order_relaxed);
    if (result == 0 && device != nullptr) {
        g_physicalDevice.store(physicalDevice, std::memory_order_relaxed);
        g_device.store(*device, std::memory_order_relaxed);
    }
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
    TF3_VK_ENTRY(BeginCommandBuffer),      TF3_VK_ENTRY(CmdBindIndexBuffer),
    TF3_VK_ENTRY(CmdSetViewport),          TF3_VK_ENTRY(CmdSetScissor),
    TF3_VK_ENTRY(CmdPushConstants),        TF3_VK_ENTRY(CreateFramebuffer),
    TF3_VK_ENTRY(DestroyFramebuffer),      TF3_VK_ENTRY(CreateRenderPass),
    TF3_VK_ENTRY(CreateRenderPass2),       TF3_VK_ENTRY(CreateRenderPass2KHR),
    TF3_VK_ENTRY(DestroyRenderPass),       TF3_VK_ENTRY(DestroyImageView),
    TF3_VK_ENTRY(CreateGraphicsPipelines), TF3_VK_ENTRY(CreateShaderModule),
    TF3_VK_ENTRY(CreateBuffer),            TF3_VK_ENTRY(AllocateMemory),
    TF3_VK_ENTRY(CreateSwapchainKHR),      TF3_VK_ENTRY(CreateDevice),
    TF3_VK_ENTRY(CreateImage),             TF3_VK_ENTRY(DestroyImage),
    TF3_VK_ENTRY(CreateImageView),         TF3_VK_ENTRY(CreateSampler),
    TF3_VK_ENTRY(CmdCopyBufferToImage),    TF3_VK_ENTRY(DestroyBuffer),
    TF3_VK_ENTRY(AllocateDescriptorSets),  TF3_VK_ENTRY(DestroySwapchainKHR),
    TF3_VK_ENTRY(DestroyDevice),           TF3_VK_ENTRY(GetDeviceQueue),
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
    // The lookup hooks serve the frame statistics and the overlay; one switch turns all Vulkan hooking off.
    if (!config::GetBool("Vulkan", "Hooks", true)) {
        TF3_LOG("vkstats: Vulkan hooks disabled in tf3api.ini ([Vulkan] Hooks=0) - no frame statistics, no overlay");
        return;
    }
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

void* Instance() { return g_instance.load(std::memory_order_relaxed); }
void* PhysicalDevice() { return g_physicalDevice.load(std::memory_order_relaxed); }
void* Device() { return g_device.load(std::memory_order_relaxed); }

VoidFn DeviceProc(const char* name) {
    void* device = Device();
    return (device != nullptr && g_origGetDeviceProcAddr != nullptr) ? g_origGetDeviceProcAddr(device, name) : nullptr;
}

VoidFn InstanceProc(const char* name) {
    void* instance = Instance();
    return (instance != nullptr && g_origGetInstanceProcAddr != nullptr) ? g_origGetInstanceProcAddr(instance, name) : nullptr;
}

uint32_t QueueFamilyOf(void* queue) {
    for (int i = 0; i < kMaxQueues; ++i) {
        if (g_queueHandle[i].load(std::memory_order_relaxed) == queue) return g_queueFamily[i].load(std::memory_order_relaxed);
    }
    return UINT32_MAX;
}

void SetListener(const Listener& listener) {
    g_listener = listener;
    // the game's drawing state is only followed when someone may draw inside its command buffers
    g_trackState.store(listener.beforeBeginRenderPass != nullptr, std::memory_order_relaxed);
}

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

} // namespace tf3api::vkstats
