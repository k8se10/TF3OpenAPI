#include "overlay.h"

#include "config.h"
#include "log.h"
#include "overlay_shaders.h"
#include "vkstats.h"

#include <windows.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace tf3api::overlay {
namespace {

// ---- Vulkan entry points (the real driver functions, fetched through vkstats) ---------------------------

#define TF3_OVERLAY_VK(X)                                                                                              \
    X(GetSwapchainImagesKHR) X(CreateImageView) X(DestroyImageView) X(CreateRenderPass) X(DestroyRenderPass)           \
    X(CreateFramebuffer) X(DestroyFramebuffer) X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers)    \
    X(BeginCommandBuffer) X(EndCommandBuffer) X(ResetCommandBuffer) X(CmdBeginRenderPass) X(CmdEndRenderPass)          \
    X(CmdBindPipeline) X(CmdBindDescriptorSets) X(CmdBindVertexBuffers) X(CmdPushConstants) X(CmdSetViewport)          \
    X(CmdSetScissor) X(CmdDraw) X(QueueSubmit) X(QueueWaitIdle) X(DeviceWaitIdle) X(CreateSemaphore)                   \
    X(DestroySemaphore) X(CreateShaderModule) X(DestroyShaderModule) X(CreatePipelineLayout) X(DestroyPipelineLayout)  \
    X(CreateGraphicsPipelines) X(DestroyPipeline) X(CreateDescriptorSetLayout) X(DestroyDescriptorSetLayout)           \
    X(CreateDescriptorPool) X(DestroyDescriptorPool) X(AllocateDescriptorSets) X(UpdateDescriptorSets)                 \
    X(CreateSampler) X(DestroySampler) X(CreateImage) X(DestroyImage) X(GetImageMemoryRequirements) X(AllocateMemory)  \
    X(FreeMemory) X(BindImageMemory) X(CreateBuffer) X(DestroyBuffer) X(GetBufferMemoryRequirements)                   \
    X(BindBufferMemory) X(MapMemory) X(UnmapMemory) X(CmdPipelineBarrier) X(CmdCopyBufferToImage)                    \
    X(CreateFence) X(DestroyFence) X(GetFenceStatus) X(ResetFences) X(WaitForFences)

struct VulkanFunctions {
#define X(name) PFN_vk##name name = nullptr;
    TF3_OVERLAY_VK(X)
#undef X
    PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties = nullptr;
};
VulkanFunctions vk;

bool LoadFunctions() {
    bool ok = true;
#define X(name)                                                                              \
    vk.name = reinterpret_cast<PFN_vk##name>(vkstats::DeviceProc("vk" #name));                \
    if (vk.name == nullptr) {                                                                \
        TF3_LOG("overlay: Vulkan function vk" #name " is not available");                    \
        ok = false;                                                                          \
    }
    TF3_OVERLAY_VK(X)
#undef X
    vk.GetPhysicalDeviceMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
        vkstats::InstanceProc("vkGetPhysicalDeviceMemoryProperties"));
    if (vk.GetPhysicalDeviceMemoryProperties == nullptr) {
        TF3_LOG("overlay: vkGetPhysicalDeviceMemoryProperties is not available");
        ok = false;
    }
    return ok;
}

// ---- Font atlas (CPU side, built once from a system font) ------------------------------------------------

constexpr int kAtlasWidth = 1024, kAtlasHeight = 256;
constexpr int kFontPixels = 40;      // glyphs are rasterised at this height and scaled when drawn
constexpr int kFirstChar = 32, kLastChar = 126;

struct Glyph {
    float u0, v0, u1, v1;  // atlas rectangle
    float width;           // rectangle width in pixels at kFontPixels
    float offsetX;         // from the pen position to the rectangle's left edge
    float advance;         // pen movement
};

std::vector<uint8_t> g_atlasPixels;  // one byte of coverage per texel
Glyph g_glyphs[kLastChar - kFirstChar + 1];
float g_lineHeight = static_cast<float>(kFontPixels);  // rectangle height in pixels at kFontPixels
float g_whiteU = 0.0f, g_whiteV = 0.0f;                // a texel that is fully covered, for rectangles

bool BuildAtlas(const wchar_t* fontName) {
    HDC dc = CreateCompatibleDC(nullptr);
    if (dc == nullptr) return false;
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = kAtlasWidth;
    info.bmiHeader.biHeight = -kAtlasHeight;  // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    HFONT font = CreateFontW(-kFontPixels, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_TT_PRECIS,
                             CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE, fontName);
    bool ok = bitmap != nullptr && bits != nullptr && font != nullptr;
    if (ok) {
        HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
        HGDIOBJ oldFont = SelectObject(dc, font);
        std::memset(bits, 0, static_cast<size_t>(kAtlasWidth) * kAtlasHeight * 4);
        SetTextColor(dc, RGB(255, 255, 255));
        SetBkMode(dc, TRANSPARENT);
        TEXTMETRICW metrics = {};
        GetTextMetricsW(dc, &metrics);
        const int rowHeight = metrics.tmHeight;
        g_lineHeight = static_cast<float>(rowHeight);

        constexpr int kPad = 2;
        int x = kPad, y = kPad;
        for (int c = kFirstChar; c <= kLastChar; ++c) {
            ABC abc = {};
            const wchar_t ch = static_cast<wchar_t>(c);
            if (!GetCharABCWidthsW(dc, ch, ch, &abc)) {
                int width = 0;
                GetCharWidth32W(dc, ch, ch, &width);
                abc.abcA = 0;
                abc.abcB = static_cast<UINT>(width);
                abc.abcC = 0;
            }
            const int boxWidth = static_cast<int>(abc.abcB) + 2;  // one spare column each side
            if (x + boxWidth + kPad > kAtlasWidth) {
                x = kPad;
                y += rowHeight + kPad;
            }
            if (y + rowHeight + kPad > kAtlasHeight) {
                ok = false;  // font too large for the atlas
                break;
            }
            TextOutW(dc, x + 1 - abc.abcA, y, &ch, 1);
            Glyph& g = g_glyphs[c - kFirstChar];
            g.u0 = static_cast<float>(x) / kAtlasWidth;
            g.u1 = static_cast<float>(x + boxWidth) / kAtlasWidth;
            g.v0 = static_cast<float>(y) / kAtlasHeight;
            g.v1 = static_cast<float>(y + rowHeight) / kAtlasHeight;
            g.width = static_cast<float>(boxWidth);
            g.offsetX = static_cast<float>(abc.abcA - 1);
            g.advance = static_cast<float>(abc.abcA + static_cast<int>(abc.abcB) + abc.abcC);
            x += boxWidth + kPad;
        }
        GdiFlush();
        if (ok) {
            g_atlasPixels.resize(static_cast<size_t>(kAtlasWidth) * kAtlasHeight);
            const auto* bgra = static_cast<const uint8_t*>(bits);
            for (size_t i = 0; i < g_atlasPixels.size(); ++i) g_atlasPixels[i] = bgra[i * 4 + 1];  // green = coverage
            // a fully covered 4x4 block in the bottom-right corner for solid rectangles
            for (int by = kAtlasHeight - 4; by < kAtlasHeight; ++by) {
                for (int bx = kAtlasWidth - 4; bx < kAtlasWidth; ++bx) {
                    g_atlasPixels[static_cast<size_t>(by) * kAtlasWidth + bx] = 255;
                }
            }
            g_whiteU = (kAtlasWidth - 2.0f) / kAtlasWidth;
            g_whiteV = (kAtlasHeight - 2.0f) / kAtlasHeight;
        }
        SelectObject(dc, oldFont);
        SelectObject(dc, oldBitmap);
    }
    if (font != nullptr) DeleteObject(font);
    if (bitmap != nullptr) DeleteObject(bitmap);
    DeleteDC(dc);
    return ok;
}

// ---- Draw list -----------------------------------------------------------------------------------------

struct Vertex {
    float x, y, u, v;
    uint32_t colour;
};
constexpr size_t kMaxVertices = 60000;  // 10,000 quads per frame

std::vector<Vertex> g_vertices;
FrameCallback g_frameCallback = nullptr;

void Quad(const float px[4], const float py[4], float u0, float v0, float u1, float v1, uint32_t colour) {
    if (g_vertices.size() + 6 > kMaxVertices) return;
    // corners: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left
    const Vertex corner[4] = {{px[0], py[0], u0, v0, colour},
                              {px[1], py[1], u1, v0, colour},
                              {px[2], py[2], u1, v1, colour},
                              {px[3], py[3], u0, v1, colour}};
    g_vertices.push_back(corner[0]);
    g_vertices.push_back(corner[1]);
    g_vertices.push_back(corner[2]);
    g_vertices.push_back(corner[0]);
    g_vertices.push_back(corner[2]);
    g_vertices.push_back(corner[3]);
}

const Glyph& GlyphFor(char c) {
    const int code = static_cast<unsigned char>(c);
    return g_glyphs[(code >= kFirstChar && code <= kLastChar ? code : '?') - kFirstChar];
}

// ---- Vulkan objects -------------------------------------------------------------------------------------

struct PerImage {
    VkImageView view = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    VkSemaphore done = VK_NULL_HANDLE;
    VkBuffer vertexBuffer = VK_NULL_HANDLE;
    VkDeviceMemory vertexMemory = VK_NULL_HANDLE;
    void* mapped = nullptr;
};

// Command buffers are taken from a small ring. Each submission carries a fence, and a command buffer is only
// recorded again once its fence shows the previous submission has finished.
constexpr int kCommandSlots = 8;
struct CommandSlot {
    VkCommandBuffer commands = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    bool submitted = false;
};

struct State {
    bool failed = false;
    bool deviceReady = false;
    VkDevice device = VK_NULL_HANDLE;
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    uint32_t queueFamily = 0;

    VkCommandPool commandPool = VK_NULL_HANDLE;
    CommandSlot slots[kCommandSlots];
    int nextSlot = 0;
    VkSampler sampler = VK_NULL_HANDLE;
    VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
    VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    VkShaderModule vertexShader = VK_NULL_HANDLE, fragmentShader = VK_NULL_HANDLE;
    VkImage atlas = VK_NULL_HANDLE;
    VkDeviceMemory atlasMemory = VK_NULL_HANDLE;
    VkImageView atlasView = VK_NULL_HANDLE;

    // depend on the swapchain's format
    VkFormat passFormat = VK_FORMAT_UNDEFINED;
    VkRenderPass renderPass = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    // the same pass for drawing in the middle of the game's frame: the image stays in the layout it is in
    VkRenderPass midPass = VK_NULL_HANDLE;
    VkImageLayout midLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    // the game's current swapchain, as reported by vkstats
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    uint32_t width = 0, height = 0;
    bool swapchainDirty = false;
    std::vector<PerImage> images;
};
State g;

std::atomic<bool> g_enabled{false};
int g_toggleKey = 0;

// ---- What the game draws onto the screen, followed for drawing under its interface ---------------------
// The game's own views and framebuffers of the swapchain's images, and what each of its render passes expects
// of its attachments. Told by vkstats as the game makes and destroys them.
struct GameFramebuffer {
    uint32_t imageIndex = 0;   // which swapchain image
    uint32_t attachment = 0;   // which attachment of the framebuffer it is
};
struct GamePass {
    std::vector<uint32_t> initialLayout, loadOp;   // per attachment
};
std::mutex g_gameMutex;
std::vector<uint64_t> g_swapImages;
std::unordered_map<uint64_t, uint32_t> g_swapViews;
std::unordered_map<uint64_t, GameFramebuffer> g_swapFramebuffers;
std::unordered_map<uint64_t, GamePass> g_gamePasses;

bool g_underInterface = true;
std::mutex g_drawMutex;          // the overlay's own state: one drawer at a time
int g_screenPasses = 0;          // the game's passes onto a swapchain image so far this frame
int g_drawBefore = 0;            // draw before the pass with this number (learned from the last frame); 0 = on top
bool g_ranThisFrame = false;     // the frame callback has run for this frame
int g_modeChanges = 0;
bool g_keyWasDown = false;
VkPresentInfoKHR g_presentCopy = {};

void Fail(const char* what, VkResult result) {
    g.failed = true;
    TF3_LOG("overlay: %s failed (VkResult %d) - overlay switched off for this session", what, static_cast<int>(result));
}

bool FindMemoryType(uint32_t allowedTypes, VkMemoryPropertyFlags wanted, uint32_t* index) {
    VkPhysicalDeviceMemoryProperties properties = {};
    vk.GetPhysicalDeviceMemoryProperties(g.physicalDevice, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        if ((allowedTypes & (1u << i)) != 0 && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) {
            *index = i;
            return true;
        }
    }
    return false;
}

bool CreateBuffer(VkDeviceSize size, VkBufferUsageFlags usage, VkBuffer* buffer, VkDeviceMemory* memory, void** mapped) {
    VkBufferCreateInfo info = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    info.size = size;
    info.usage = usage;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult r = vk.CreateBuffer(g.device, &info, nullptr, buffer);
    if (r != VK_SUCCESS) return Fail("creating a buffer", r), false;
    VkMemoryRequirements requirements = {};
    vk.GetBufferMemoryRequirements(g.device, *buffer, &requirements);
    VkMemoryAllocateInfo allocate = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocate.allocationSize = requirements.size;
    if (!FindMemoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                        &allocate.memoryTypeIndex)) {
        return Fail("finding host-visible memory", VK_ERROR_FEATURE_NOT_PRESENT), false;
    }
    r = vk.AllocateMemory(g.device, &allocate, nullptr, memory);
    if (r != VK_SUCCESS) return Fail("allocating buffer memory", r), false;
    r = vk.BindBufferMemory(g.device, *buffer, *memory, 0);
    if (r != VK_SUCCESS) return Fail("binding buffer memory", r), false;
    r = vk.MapMemory(g.device, *memory, 0, VK_WHOLE_SIZE, 0, mapped);
    if (r != VK_SUCCESS) return Fail("mapping buffer memory", r), false;
    return true;
}

// Uploads the font atlas. Runs once, on the present thread, and waits for the copy to finish.
bool CreateAtlas(VkQueue queue) {
    VkImageCreateInfo image = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    image.imageType = VK_IMAGE_TYPE_2D;
    image.format = VK_FORMAT_R8_UNORM;
    image.extent = {static_cast<uint32_t>(kAtlasWidth), static_cast<uint32_t>(kAtlasHeight), 1};
    image.mipLevels = 1;
    image.arrayLayers = 1;
    image.samples = VK_SAMPLE_COUNT_1_BIT;
    image.tiling = VK_IMAGE_TILING_OPTIMAL;
    image.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    image.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkResult r = vk.CreateImage(g.device, &image, nullptr, &g.atlas);
    if (r != VK_SUCCESS) return Fail("creating the font atlas image", r), false;
    VkMemoryRequirements requirements = {};
    vk.GetImageMemoryRequirements(g.device, g.atlas, &requirements);
    VkMemoryAllocateInfo allocate = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocate.allocationSize = requirements.size;
    if (!FindMemoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &allocate.memoryTypeIndex)) {
        return Fail("finding memory for the font atlas", VK_ERROR_FEATURE_NOT_PRESENT), false;
    }
    r = vk.AllocateMemory(g.device, &allocate, nullptr, &g.atlasMemory);
    if (r != VK_SUCCESS) return Fail("allocating font atlas memory", r), false;
    r = vk.BindImageMemory(g.device, g.atlas, g.atlasMemory, 0);
    if (r != VK_SUCCESS) return Fail("binding font atlas memory", r), false;

    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory stagingMemory = VK_NULL_HANDLE;
    void* mapped = nullptr;
    if (!CreateBuffer(g_atlasPixels.size(), VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &staging, &stagingMemory, &mapped)) return false;
    std::memcpy(mapped, g_atlasPixels.data(), g_atlasPixels.size());

    VkCommandBufferAllocateInfo allocateCommands = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocateCommands.commandPool = g.commandPool;
    allocateCommands.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocateCommands.commandBufferCount = 1;
    VkCommandBuffer commands = VK_NULL_HANDLE;
    r = vk.AllocateCommandBuffers(g.device, &allocateCommands, &commands);
    if (r != VK_SUCCESS) return Fail("allocating the upload command buffer", r), false;
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vk.BeginCommandBuffer(commands, &begin);
    VkImageMemoryBarrier barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = g.atlas;
    barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    vk.CmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr,
                          1, &barrier);
    VkBufferImageCopy region = {};
    region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    region.imageExtent = image.extent;
    vk.CmdCopyBufferToImage(commands, staging, g.atlas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vk.CmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0,
                          nullptr, 1, &barrier);
    vk.EndCommandBuffer(commands);
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &commands;
    r = vk.QueueSubmit(queue, 1, &submit, VK_NULL_HANDLE);
    if (r != VK_SUCCESS) return Fail("submitting the font atlas upload", r), false;
    vk.QueueWaitIdle(queue);
    vk.UnmapMemory(g.device, stagingMemory);
    vk.DestroyBuffer(g.device, staging, nullptr);
    vk.FreeMemory(g.device, stagingMemory, nullptr);

    VkImageViewCreateInfo view = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    view.image = g.atlas;
    view.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view.format = VK_FORMAT_R8_UNORM;
    view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    r = vk.CreateImageView(g.device, &view, nullptr, &g.atlasView);
    if (r != VK_SUCCESS) return Fail("creating the font atlas view", r), false;
    return true;
}

// Everything that depends only on the device. Runs once, at the first frame the overlay draws.
bool EnsureDevice(VkQueue queue) {
    if (g.deviceReady) return true;
    g.device = static_cast<VkDevice>(vkstats::Device());
    g.physicalDevice = static_cast<VkPhysicalDevice>(vkstats::PhysicalDevice());
    if (g.device == VK_NULL_HANDLE || g.physicalDevice == VK_NULL_HANDLE) {
        return Fail("getting the game's Vulkan device", VK_ERROR_INITIALIZATION_FAILED), false;
    }
    if (!LoadFunctions()) return Fail("loading Vulkan functions", VK_ERROR_INITIALIZATION_FAILED), false;
    g.queueFamily = vkstats::QueueFamilyOf(queue);
    if (g.queueFamily == UINT32_MAX) return Fail("identifying the present queue's family", VK_ERROR_INITIALIZATION_FAILED), false;

    VkCommandPoolCreateInfo pool = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = g.queueFamily;
    VkResult r = vk.CreateCommandPool(g.device, &pool, nullptr, &g.commandPool);
    if (r != VK_SUCCESS) return Fail("creating the command pool", r), false;

    VkCommandBuffer slotCommands[kCommandSlots] = {};
    VkCommandBufferAllocateInfo allocateSlots = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocateSlots.commandPool = g.commandPool;
    allocateSlots.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocateSlots.commandBufferCount = kCommandSlots;
    r = vk.AllocateCommandBuffers(g.device, &allocateSlots, slotCommands);
    if (r != VK_SUCCESS) return Fail("allocating command buffers", r), false;
    for (int i = 0; i < kCommandSlots; ++i) {
        g.slots[i].commands = slotCommands[i];
        VkFenceCreateInfo fence = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        r = vk.CreateFence(g.device, &fence, nullptr, &g.slots[i].fence);
        if (r != VK_SUCCESS) return Fail("creating a fence", r), false;
    }

    if (!CreateAtlas(queue)) return false;

    VkSamplerCreateInfo sampler = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    sampler.magFilter = sampler.minFilter = VK_FILTER_LINEAR;
    sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sampler.addressModeU = sampler.addressModeV = sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    r = vk.CreateSampler(g.device, &sampler, nullptr, &g.sampler);
    if (r != VK_SUCCESS) return Fail("creating the sampler", r), false;

    VkDescriptorSetLayoutBinding binding = {};
    binding.binding = 0;
    binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount = 1;
    binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo setLayout = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    setLayout.bindingCount = 1;
    setLayout.pBindings = &binding;
    r = vk.CreateDescriptorSetLayout(g.device, &setLayout, nullptr, &g.setLayout);
    if (r != VK_SUCCESS) return Fail("creating the descriptor set layout", r), false;
    VkDescriptorPoolSize poolSize = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1};
    VkDescriptorPoolCreateInfo descriptorPool = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    descriptorPool.maxSets = 1;
    descriptorPool.poolSizeCount = 1;
    descriptorPool.pPoolSizes = &poolSize;
    r = vk.CreateDescriptorPool(g.device, &descriptorPool, nullptr, &g.descriptorPool);
    if (r != VK_SUCCESS) return Fail("creating the descriptor pool", r), false;
    VkDescriptorSetAllocateInfo allocateSet = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    allocateSet.descriptorPool = g.descriptorPool;
    allocateSet.descriptorSetCount = 1;
    allocateSet.pSetLayouts = &g.setLayout;
    r = vk.AllocateDescriptorSets(g.device, &allocateSet, &g.descriptorSet);
    if (r != VK_SUCCESS) return Fail("allocating the descriptor set", r), false;
    VkDescriptorImageInfo imageInfo = {g.sampler, g.atlasView, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    write.dstSet = g.descriptorSet;
    write.dstBinding = 0;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &imageInfo;
    vk.UpdateDescriptorSets(g.device, 1, &write, 0, nullptr);

    VkPushConstantRange range = {VK_SHADER_STAGE_VERTEX_BIT, 0, 2 * sizeof(float)};
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.setLayoutCount = 1;
    layout.pSetLayouts = &g.setLayout;
    layout.pushConstantRangeCount = 1;
    layout.pPushConstantRanges = &range;
    r = vk.CreatePipelineLayout(g.device, &layout, nullptr, &g.pipelineLayout);
    if (r != VK_SUCCESS) return Fail("creating the pipeline layout", r), false;

    VkShaderModuleCreateInfo module = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    module.codeSize = sizeof(kOverlayVertSpv);
    module.pCode = kOverlayVertSpv;
    r = vk.CreateShaderModule(g.device, &module, nullptr, &g.vertexShader);
    if (r != VK_SUCCESS) return Fail("creating the vertex shader", r), false;
    module.codeSize = sizeof(kOverlayFragSpv);
    module.pCode = kOverlayFragSpv;
    r = vk.CreateShaderModule(g.device, &module, nullptr, &g.fragmentShader);
    if (r != VK_SUCCESS) return Fail("creating the fragment shader", r), false;

    g.deviceReady = true;
    TF3_LOG("overlay: device objects ready (queue family %u)", g.queueFamily);
    return true;
}

// Render pass and pipeline for one surface format.
bool EnsurePass(VkFormat format) {
    if (g.renderPass != VK_NULL_HANDLE && g.passFormat == format) return true;
    if (g.pipeline != VK_NULL_HANDLE) vk.DestroyPipeline(g.device, g.pipeline, nullptr);
    if (g.renderPass != VK_NULL_HANDLE) vk.DestroyRenderPass(g.device, g.renderPass, nullptr);
    if (g.midPass != VK_NULL_HANDLE) vk.DestroyRenderPass(g.device, g.midPass, nullptr);
    g.pipeline = VK_NULL_HANDLE;
    g.renderPass = VK_NULL_HANDLE;
    g.midPass = VK_NULL_HANDLE;
    g.midLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    // Draw on top of what the game rendered: load the image, leave it ready to present.
    VkAttachmentDescription attachment = {};
    attachment.format = format;
    attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    attachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &reference;
    VkSubpassDependency dependency = {};
    dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
    dependency.dstSubpass = 0;
    dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependency.srcAccessMask = 0;
    dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo pass = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    pass.attachmentCount = 1;
    pass.pAttachments = &attachment;
    pass.subpassCount = 1;
    pass.pSubpasses = &subpass;
    pass.dependencyCount = 1;
    pass.pDependencies = &dependency;
    VkResult r = vk.CreateRenderPass(g.device, &pass, nullptr, &g.renderPass);
    if (r != VK_SUCCESS) return Fail("creating the render pass", r), false;

    VkPipelineShaderStageCreateInfo stages[2] = {};
    stages[0].sType = stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = g.vertexShader;
    stages[0].pName = "main";
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = g.fragmentShader;
    stages[1].pName = "main";
    VkVertexInputBindingDescription vertexBinding = {0, sizeof(Vertex), VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attributes[3] = {{0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Vertex, x)},
                                                       {1, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Vertex, u)},
                                                       {2, 0, VK_FORMAT_R8G8B8A8_UNORM, offsetof(Vertex, colour)}};
    VkPipelineVertexInputStateCreateInfo vertexInput = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vertexInput.vertexBindingDescriptionCount = 1;
    vertexInput.pVertexBindingDescriptions = &vertexBinding;
    vertexInput.vertexAttributeDescriptionCount = 3;
    vertexInput.pVertexAttributeDescriptions = attributes;
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1;
    viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL;
    raster.cullMode = VK_CULL_MODE_NONE;
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE;
    raster.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blendAttachment = {};
    blendAttachment.blendEnable = VK_TRUE;
    blendAttachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    blendAttachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blendAttachment.colorBlendOp = VK_BLEND_OP_ADD;
    blendAttachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    blendAttachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blendAttachment.alphaBlendOp = VK_BLEND_OP_ADD;
    blendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo blend = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    blend.attachmentCount = 1;
    blend.pAttachments = &blendAttachment;
    VkDynamicState dynamicStates[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 2;
    dynamic.pDynamicStates = dynamicStates;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 2;
    pipeline.pStages = stages;
    pipeline.pVertexInputState = &vertexInput;
    pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport;
    pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample;
    pipeline.pColorBlendState = &blend;
    pipeline.pDynamicState = &dynamic;
    pipeline.layout = g.pipelineLayout;
    pipeline.renderPass = g.renderPass;
    r = vk.CreateGraphicsPipelines(g.device, VK_NULL_HANDLE, 1, &pipeline, nullptr, &g.pipeline);
    if (r != VK_SUCCESS) return Fail("creating the pipeline", r), false;
    g.passFormat = format;
    return true;
}

// The pass for drawing in the middle of the game's frame: like the other one, but the image is taken and left
// in the layout the game has it in at that moment. A pipeline made for one works with the other (same format
// and sample count), and so do the framebuffers.
bool EnsureMidPass(VkImageLayout layout) {
    if (g.midPass != VK_NULL_HANDLE && g.midLayout == layout) return true;
    if (g.renderPass == VK_NULL_HANDLE || g.pipeline == VK_NULL_HANDLE) return false;
    if (g.midPass != VK_NULL_HANDLE) {
        vk.DeviceWaitIdle(g.device);
        vk.DestroyRenderPass(g.device, g.midPass, nullptr);
        g.midPass = VK_NULL_HANDLE;
    }
    VkAttachmentDescription attachment = {};
    attachment.format = g.passFormat;
    attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = layout;
    attachment.finalLayout = layout;
    VkAttachmentReference reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &reference;
    VkSubpassDependency dependencies[2] = {};
    dependencies[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    dependencies[0].dstSubpass = 0;
    dependencies[0].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[0].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dependencies[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dependencies[1].srcSubpass = 0;
    dependencies[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    dependencies[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[1].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dependencies[1].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo pass = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    pass.attachmentCount = 1;
    pass.pAttachments = &attachment;
    pass.subpassCount = 1;
    pass.pSubpasses = &subpass;
    pass.dependencyCount = 2;
    pass.pDependencies = dependencies;
    const VkResult r = vk.CreateRenderPass(g.device, &pass, nullptr, &g.midPass);
    if (r != VK_SUCCESS) {
        TF3_LOG("overlay: could not make the pass for drawing under the interface (VkResult %d) - drawing on top instead", static_cast<int>(r));
        g.midPass = VK_NULL_HANDLE;
        g_underInterface = false;
        return false;
    }
    g.midLayout = layout;
    return true;
}

void DestroySwapchainObjects() {
    if (g.images.empty() || g.device == VK_NULL_HANDLE) return;
    vk.DeviceWaitIdle(g.device);  // nothing of ours may still be executing
    for (PerImage& image : g.images) {
        if (image.framebuffer != VK_NULL_HANDLE) vk.DestroyFramebuffer(g.device, image.framebuffer, nullptr);
        if (image.view != VK_NULL_HANDLE) vk.DestroyImageView(g.device, image.view, nullptr);
        if (image.done != VK_NULL_HANDLE) vk.DestroySemaphore(g.device, image.done, nullptr);
        if (image.vertexBuffer != VK_NULL_HANDLE) vk.DestroyBuffer(g.device, image.vertexBuffer, nullptr);
        if (image.vertexMemory != VK_NULL_HANDLE) vk.FreeMemory(g.device, image.vertexMemory, nullptr);
    }
    g.images.clear();
}

bool BuildSwapchainObjects() {
    DestroySwapchainObjects();
    if (!EnsurePass(g.format)) return false;
    uint32_t count = 0;
    VkResult r = vk.GetSwapchainImagesKHR(g.device, g.swapchain, &count, nullptr);
    if (r != VK_SUCCESS || count == 0) return Fail("listing swapchain images", r), false;
    std::vector<VkImage> swapImages(count);
    r = vk.GetSwapchainImagesKHR(g.device, g.swapchain, &count, swapImages.data());
    if (r != VK_SUCCESS) return Fail("getting swapchain images", r), false;

    g.images.resize(count);
    for (uint32_t i = 0; i < count; ++i) {
        PerImage& image = g.images[i];
        VkImageViewCreateInfo view = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        view.image = swapImages[i];
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = g.format;
        view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        r = vk.CreateImageView(g.device, &view, nullptr, &image.view);
        if (r != VK_SUCCESS) return Fail("creating a swapchain image view", r), false;
        VkFramebufferCreateInfo framebuffer = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        framebuffer.renderPass = g.renderPass;
        framebuffer.attachmentCount = 1;
        framebuffer.pAttachments = &image.view;
        framebuffer.width = g.width;
        framebuffer.height = g.height;
        framebuffer.layers = 1;
        r = vk.CreateFramebuffer(g.device, &framebuffer, nullptr, &image.framebuffer);
        if (r != VK_SUCCESS) return Fail("creating a framebuffer", r), false;
        VkSemaphoreCreateInfo semaphore = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        r = vk.CreateSemaphore(g.device, &semaphore, nullptr, &image.done);
        if (r != VK_SUCCESS) return Fail("creating a semaphore", r), false;
        if (!CreateBuffer(kMaxVertices * sizeof(Vertex), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &image.vertexBuffer, &image.vertexMemory,
                          &image.mapped)) {
            return false;
        }
    }
    g.swapchainDirty = false;
    TF3_LOG("overlay: drawing on a %ux%u swapchain (format %d, %u images)", g.width, g.height, static_cast<int>(g.format), count);
    return true;
}

// ---- Listener callbacks (called by vkstats on the game's thread) -----------------------------------------

void OnSwapchainCreated(uint64_t swapchain, uint32_t format, uint32_t width, uint32_t height) {
    g.swapchain = reinterpret_cast<VkSwapchainKHR>(swapchain);
    g.format = static_cast<VkFormat>(format);
    g.width = width;
    g.height = height;
    g.swapchainDirty = true;
}

void OnSwapchainDestroying(uint64_t swapchain) {
    if (reinterpret_cast<VkSwapchainKHR>(swapchain) != g.swapchain) return;
    DestroySwapchainObjects();
    g.swapchain = VK_NULL_HANDLE;
}

void OnDeviceDestroying() {
    if (!g.deviceReady) return;
    DestroySwapchainObjects();
    if (g.pipeline != VK_NULL_HANDLE) vk.DestroyPipeline(g.device, g.pipeline, nullptr);
    if (g.renderPass != VK_NULL_HANDLE) vk.DestroyRenderPass(g.device, g.renderPass, nullptr);
    if (g.midPass != VK_NULL_HANDLE) vk.DestroyRenderPass(g.device, g.midPass, nullptr);
    if (g.vertexShader != VK_NULL_HANDLE) vk.DestroyShaderModule(g.device, g.vertexShader, nullptr);
    if (g.fragmentShader != VK_NULL_HANDLE) vk.DestroyShaderModule(g.device, g.fragmentShader, nullptr);
    if (g.pipelineLayout != VK_NULL_HANDLE) vk.DestroyPipelineLayout(g.device, g.pipelineLayout, nullptr);
    if (g.descriptorPool != VK_NULL_HANDLE) vk.DestroyDescriptorPool(g.device, g.descriptorPool, nullptr);
    if (g.setLayout != VK_NULL_HANDLE) vk.DestroyDescriptorSetLayout(g.device, g.setLayout, nullptr);
    if (g.sampler != VK_NULL_HANDLE) vk.DestroySampler(g.device, g.sampler, nullptr);
    if (g.atlasView != VK_NULL_HANDLE) vk.DestroyImageView(g.device, g.atlasView, nullptr);
    if (g.atlas != VK_NULL_HANDLE) vk.DestroyImage(g.device, g.atlas, nullptr);
    if (g.atlasMemory != VK_NULL_HANDLE) vk.FreeMemory(g.device, g.atlasMemory, nullptr);
    for (CommandSlot& slot : g.slots) {
        if (slot.fence != VK_NULL_HANDLE) vk.DestroyFence(g.device, slot.fence, nullptr);
    }
    if (g.commandPool != VK_NULL_HANDLE) vk.DestroyCommandPool(g.device, g.commandPool, nullptr);
    const bool failed = g.failed;
    g = State{};
    g.failed = failed;
}

bool GameFocused() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

void DefaultFrame(float width, float height) {
    char line[96];
    snprintf(line, sizeof(line), "TF3OpenAPI overlay  %.0f x %.0f", width, height);
    const float size = 22.0f;
    const float textWidth = TextWidth(size, line);
    Rect(12.0f, 12.0f, textWidth + 20.0f, size + 12.0f, 0xB0000000u);
    Text(22.0f, 18.0f, size, kWhite, line);
}

// ---- Following what the game draws onto the screen -------------------------------------------------------

void OnSwapchainImages(uint64_t, const uint64_t* images, uint32_t count) {
    std::lock_guard<std::mutex> lock(g_gameMutex);
    g_swapImages.assign(images, images + count);
    g_swapViews.clear();
    g_swapFramebuffers.clear();
}

void OnImageViewCreated(const void* createInfo, uint64_t view) {
    const auto* info = static_cast<const VkImageViewCreateInfo*>(createInfo);
    const uint64_t image = reinterpret_cast<uint64_t>(info->image);
    std::lock_guard<std::mutex> lock(g_gameMutex);
    for (size_t i = 0; i < g_swapImages.size(); ++i) {
        if (g_swapImages[i] == image) g_swapViews[view] = static_cast<uint32_t>(i);
    }
}

void OnImageViewDestroying(uint64_t view) {
    std::lock_guard<std::mutex> lock(g_gameMutex);
    if (!g_swapViews.empty()) g_swapViews.erase(view);
}

void OnFramebufferCreated(const void* createInfo, uint64_t framebuffer) {
    const auto* info = static_cast<const VkFramebufferCreateInfo*>(createInfo);
    if ((info->flags & VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT) != 0 || info->pAttachments == nullptr) return;
    std::lock_guard<std::mutex> lock(g_gameMutex);
    if (g_swapViews.empty()) return;
    for (uint32_t i = 0; i < info->attachmentCount; ++i) {
        const auto found = g_swapViews.find(reinterpret_cast<uint64_t>(info->pAttachments[i]));
        if (found != g_swapViews.end()) g_swapFramebuffers[framebuffer] = {found->second, i};
    }
}

void OnFramebufferDestroying(uint64_t framebuffer) {
    std::lock_guard<std::mutex> lock(g_gameMutex);
    if (!g_swapFramebuffers.empty()) g_swapFramebuffers.erase(framebuffer);
}

void OnRenderPassCreated(const void* createInfo, uint64_t renderPass, int version) {
    GamePass pass;
    if (version == 1) {
        const auto* info = static_cast<const VkRenderPassCreateInfo*>(createInfo);
        for (uint32_t i = 0; i < info->attachmentCount; ++i) {
            pass.initialLayout.push_back(static_cast<uint32_t>(info->pAttachments[i].initialLayout));
            pass.loadOp.push_back(static_cast<uint32_t>(info->pAttachments[i].loadOp));
        }
    } else {
        const auto* info = static_cast<const VkRenderPassCreateInfo2*>(createInfo);
        for (uint32_t i = 0; i < info->attachmentCount; ++i) {
            pass.initialLayout.push_back(static_cast<uint32_t>(info->pAttachments[i].initialLayout));
            pass.loadOp.push_back(static_cast<uint32_t>(info->pAttachments[i].loadOp));
        }
    }
    std::lock_guard<std::mutex> lock(g_gameMutex);
    g_gamePasses[renderPass] = std::move(pass);
}

void OnRenderPassDestroying(uint64_t renderPass) {
    std::lock_guard<std::mutex> lock(g_gameMutex);
    g_gamePasses.erase(renderPass);
}

// Fills g_vertices with what this frame shows.
void BuildVertices() {
    g_vertices.clear();
    const float width = static_cast<float>(g.width), height = static_cast<float>(g.height);
    if (g_frameCallback != nullptr) {
        g_frameCallback(width, height);
    } else {
        DefaultFrame(width, height);
    }
}

// Records the drawing of g_vertices; inside a render pass on one of our framebuffers.
void RecordDraws(VkCommandBuffer commands, PerImage& image) {
    const float width = static_cast<float>(g.width), height = static_cast<float>(g.height);
    std::memcpy(image.mapped, g_vertices.data(), g_vertices.size() * sizeof(Vertex));
    vk.CmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, g.pipeline);
    const VkViewport viewport = {0.0f, 0.0f, width, height, 0.0f, 1.0f};
    const VkRect2D scissor = {{0, 0}, {g.width, g.height}};
    vk.CmdSetViewport(commands, 0, 1, &viewport);
    vk.CmdSetScissor(commands, 0, 1, &scissor);
    const float scale[2] = {2.0f / width, 2.0f / height};
    vk.CmdPushConstants(commands, g.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(scale), scale);
    vk.CmdBindDescriptorSets(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, g.pipelineLayout, 0, 1, &g.descriptorSet, 0, nullptr);
    const VkDeviceSize offset = 0;
    vk.CmdBindVertexBuffers(commands, 0, 1, &image.vertexBuffer, &offset);
    vk.CmdDraw(commands, static_cast<uint32_t>(g_vertices.size()), 1, 0, 0);
}

// The game is about to begin a render pass. If it is the pass that lays the game's windows over the screen
// image, the overlay is drawn first, into the same command buffer. Returns true if anything was recorded.
bool BeforeGamePass(void* commandBuffer, const void* beginInfo) {
    if (!g_underInterface || !g_enabled.load(std::memory_order_relaxed)) return false;
    const auto* info = static_cast<const VkRenderPassBeginInfo*>(beginInfo);
    GameFramebuffer target;
    uint32_t layout = 0, loadOp = 0;
    {
        std::lock_guard<std::mutex> lock(g_gameMutex);
        const auto framebuffer = g_swapFramebuffers.find(reinterpret_cast<uint64_t>(info->framebuffer));
        if (framebuffer == g_swapFramebuffers.end()) return false;
        target = framebuffer->second;
        const auto pass = g_gamePasses.find(reinterpret_cast<uint64_t>(info->renderPass));
        if (pass != g_gamePasses.end() && target.attachment < pass->second.initialLayout.size()) {
            layout = pass->second.initialLayout[target.attachment];
            loadOp = pass->second.loadOp[target.attachment];
        }
    }
    std::lock_guard<std::mutex> lock(g_drawMutex);
    const int number = ++g_screenPasses;
    if (number != g_drawBefore || g_ranThisFrame || g.failed) return false;
    // the pass must keep what is on the image, and we must know which layout the image is in
    if (loadOp != static_cast<uint32_t>(VK_ATTACHMENT_LOAD_OP_LOAD) || layout == static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED)) return false;
    if (!g.deviceReady || g.swapchainDirty || target.imageIndex >= g.images.size()) return false;
    if (!EnsureMidPass(static_cast<VkImageLayout>(layout))) return false;
    BuildVertices();
    g_ranThisFrame = true;
    if (g_vertices.empty()) return false;
    PerImage& image = g.images[target.imageIndex];
    const VkCommandBuffer commands = static_cast<VkCommandBuffer>(commandBuffer);
    VkRenderPassBeginInfo pass = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
    pass.renderPass = g.midPass;
    pass.framebuffer = image.framebuffer;
    pass.renderArea = {{0, 0}, {g.width, g.height}};
    vk.CmdBeginRenderPass(commands, &pass, VK_SUBPASS_CONTENTS_INLINE);
    RecordDraws(commands, image);
    vk.CmdEndRenderPass(commands);
    return true;
}

const void* BeforePresent(void* queueHandle, const void* presentInfo) {
    std::lock_guard<std::mutex> drawLock(g_drawMutex);
    // What this frame showed about the game's passes decides where the next frame's overlay goes: before the
    // last of the game's passes onto the screen when there are at least two (a clear or the world first, the
    // interface last), on top of the finished frame otherwise.
    const int screenPasses = g_screenPasses;
    const bool ranThisFrame = g_ranThisFrame;
    g_screenPasses = 0;
    g_ranThisFrame = false;
    const int drawBefore = (g_underInterface && screenPasses >= 2) ? screenPasses : 0;
    if (drawBefore != g_drawBefore) {
        g_drawBefore = drawBefore;
        if (g_enabled.load(std::memory_order_relaxed) && ++g_modeChanges <= 12) {
            if (drawBefore > 0) {
                TF3_LOG("overlay: drawn under the game's interface (before pass %d of %d onto the screen)", drawBefore, screenPasses);
            } else {
                TF3_LOG("overlay: drawn on top of the finished frame (%d pass(es) onto the screen)", screenPasses);
            }
        }
    }
    if (g_toggleKey > 0) {
        const bool down = (GetAsyncKeyState(g_toggleKey) & 0x8000) != 0;
        if (down && !g_keyWasDown && GameFocused()) {
            const bool now = !g_enabled.load(std::memory_order_relaxed);
            g_enabled.store(now, std::memory_order_relaxed);
            TF3_LOG("overlay: %s", now ? "ON" : "OFF");
        }
        g_keyWasDown = down;
    }
    if (!g_enabled.load(std::memory_order_relaxed) || g.failed || presentInfo == nullptr) return presentInfo;
    if (ranThisFrame) return presentInfo;   // already drawn inside the game's frame

    const auto* info = static_cast<const VkPresentInfoKHR*>(presentInfo);
    constexpr uint32_t kMaxWaits = 8;
    if (info->swapchainCount != 1 || info->waitSemaphoreCount > kMaxWaits) return presentInfo;
    if (g.swapchain == VK_NULL_HANDLE || info->pSwapchains[0] != g.swapchain) return presentInfo;  // not one we were told about
    const VkQueue queue = static_cast<VkQueue>(queueHandle);
    if (!EnsureDevice(queue)) return presentInfo;
    if ((g.swapchainDirty || g.images.empty()) && !BuildSwapchainObjects()) return presentInfo;
    const uint32_t index = info->pImageIndices[0];
    if (index >= g.images.size()) return presentInfo;
    PerImage& image = g.images[index];

    BuildVertices();
    if (g_vertices.empty()) return presentInfo;

    // A command buffer whose last submission has finished. Normally the next one in the ring is free; if the
    // GPU is far behind, wait briefly for it, and skip the overlay for this frame rather than stall the game.
    CommandSlot& slot = g.slots[g.nextSlot];
    if (slot.submitted) {
        if (vk.GetFenceStatus(g.device, slot.fence) != VK_SUCCESS &&
            vk.WaitForFences(g.device, 1, &slot.fence, VK_TRUE, 50ull * 1000 * 1000) != VK_SUCCESS) {
            return presentInfo;
        }
        vk.ResetFences(g.device, 1, &slot.fence);
        slot.submitted = false;
    }
    g.nextSlot = (g.nextSlot + 1) % kCommandSlots;
    const VkCommandBuffer commands = slot.commands;

    vk.ResetCommandBuffer(commands, 0);
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    VkResult r = vk.BeginCommandBuffer(commands, &begin);
    if (r != VK_SUCCESS) return Fail("beginning the command buffer", r), presentInfo;
    VkRenderPassBeginInfo pass = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
    pass.renderPass = g.renderPass;
    pass.framebuffer = image.framebuffer;
    pass.renderArea = {{0, 0}, {g.width, g.height}};
    vk.CmdBeginRenderPass(commands, &pass, VK_SUBPASS_CONTENTS_INLINE);
    RecordDraws(commands, image);
    vk.CmdEndRenderPass(commands);
    r = vk.EndCommandBuffer(commands);
    if (r != VK_SUCCESS) return Fail("ending the command buffer", r), presentInfo;

    // Run after whatever the present was waiting for; the present then waits for us instead.
    VkPipelineStageFlags waitStages[kMaxWaits];
    for (uint32_t i = 0; i < kMaxWaits; ++i) waitStages[i] = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = info->waitSemaphoreCount;
    submit.pWaitSemaphores = info->pWaitSemaphores;
    submit.pWaitDstStageMask = waitStages;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &commands;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &image.done;
    r = vk.QueueSubmit(queue, 1, &submit, slot.fence);
    if (r != VK_SUCCESS) return Fail("submitting the overlay", r), presentInfo;
    slot.submitted = true;

    g_presentCopy = *info;
    g_presentCopy.waitSemaphoreCount = 1;
    g_presentCopy.pWaitSemaphores = &image.done;
    return &g_presentCopy;
}

} // namespace

// ---- Drawing API ----------------------------------------------------------------------------------------

void Rect(float x, float y, float width, float height, uint32_t colour) {
    const float px[4] = {x, x + width, x + width, x};
    const float py[4] = {y, y, y + height, y + height};
    Quad(px, py, g_whiteU, g_whiteV, g_whiteU, g_whiteV, colour);
}

float TextWidth(float size, const char* text) {
    const float scale = size / g_lineHeight;
    float width = 0.0f;
    for (const char* c = text; *c != '\0'; ++c) width += GlyphFor(*c).advance * scale;
    return width;
}

float Text(float x, float y, float size, uint32_t colour, const char* text) {
    const float scale = size / g_lineHeight;
    float pen = x;
    for (const char* c = text; *c != '\0'; ++c) {
        const Glyph& glyph = GlyphFor(*c);
        if (*c != ' ') {
            const float left = pen + glyph.offsetX * scale, right = left + glyph.width * scale;
            const float px[4] = {left, right, right, left};
            const float py[4] = {y, y, y + size, y + size};
            Quad(px, py, glyph.u0, glyph.v0, glyph.u1, glyph.v1, colour);
        }
        pen += glyph.advance * scale;
    }
    return pen - x;
}

void TextRotated(float x, float y, float size, float angle, uint32_t colour, const char* text) {
    const float scale = size / g_lineHeight;
    const float cosA = std::cos(angle), sinA = std::sin(angle);
    float pen = 0.0f;
    for (const char* c = text; *c != '\0'; ++c) {
        const Glyph& glyph = GlyphFor(*c);
        if (*c != ' ') {
            // the line of text is centred on the baseline given: half the height above it, half below
            const float left = pen + glyph.offsetX * scale, right = left + glyph.width * scale;
            const float top = -size * 0.5f, bottom = size * 0.5f;
            const float lx[4] = {left, right, right, left};
            const float ly[4] = {top, top, bottom, bottom};
            float px[4], py[4];
            for (int i = 0; i < 4; ++i) {
                px[i] = x + lx[i] * cosA - ly[i] * sinA;
                py[i] = y + lx[i] * sinA + ly[i] * cosA;
            }
            Quad(px, py, glyph.u0, glyph.v0, glyph.u1, glyph.v1, colour);
        }
        pen += glyph.advance * scale;
    }
}

void SetFrameCallback(FrameCallback callback) { g_frameCallback = callback; }

void Install() {
    g_enabled.store(config::GetBool("Overlay", "Enabled", false));
    g_toggleKey = config::GetInt("Overlay", "ToggleKey", 0);
    g_underInterface = config::GetBool("Overlay", "UnderInterface", true);
    if (!g_enabled.load() && g_toggleKey <= 0) {
        TF3_LOG("overlay: off ([Overlay] Enabled=0 and no ToggleKey)");
        return;
    }
    if (!BuildAtlas(L"Segoe UI")) {
        TF3_LOG("overlay: could not build the font atlas - overlay unavailable");
        g_enabled.store(false);
        return;
    }
    g_vertices.reserve(kMaxVertices);
    vkstats::Listener listener;
    listener.swapchainCreated = &OnSwapchainCreated;
    listener.swapchainDestroying = &OnSwapchainDestroying;
    listener.deviceDestroying = &OnDeviceDestroying;
    listener.beforePresent = &BeforePresent;
    if (g_underInterface) {
        listener.swapchainImages = &OnSwapchainImages;
        listener.imageViewCreated = &OnImageViewCreated;
        listener.imageViewDestroying = &OnImageViewDestroying;
        listener.framebufferCreated = &OnFramebufferCreated;
        listener.framebufferDestroying = &OnFramebufferDestroying;
        listener.renderPassCreated = &OnRenderPassCreated;
        listener.renderPassDestroying = &OnRenderPassDestroying;
        listener.beforeBeginRenderPass = &BeforeGamePass;
    }
    vkstats::SetListener(listener);
    TF3_LOG("overlay: ready (%s at start, toggle key %d, %s)", g_enabled.load() ? "on" : "off", g_toggleKey,
            g_underInterface ? "under the game's interface where possible" : "on top of the frame");
}

void Uninstall() {
    // Vulkan objects are released when the game destroys its device (OnDeviceDestroying); at process exit
    // the driver reclaims whatever is left.
    g_enabled.store(false);
}

} // namespace tf3api::overlay
