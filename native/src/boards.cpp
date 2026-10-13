#include "boards.h"

#include "config.h"
#include "log.h"
#include "vkstats.h"

#include <windows.h>

#include <vulkan/vulkan_core.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace tf3api::boards {

namespace {

// ---- What to show (set by script, any thread) -----------------------------------------------------------

std::mutex g_textLock;
std::string g_lines[kTextLines];
int g_clock = -1;
bool g_said = false;              // a script has set something: until then the shipped picture stays
uint64_t g_wanted = 0;            // counts changes of the text

// ---- The painter thread: turns the text into a picture when it changes ----------------------------------

std::mutex g_pictureLock;
std::vector<uint8_t> g_picture;           // the newest finished picture, every level
std::vector<size_t> g_levelOffsets;
uint64_t g_pictureVersion = 0;            // the g_wanted it was made for
std::atomic<uint64_t> g_pictureReady{0};  // same, readable without the lock

std::mutex g_wakeLock;
std::condition_variable g_wake;
bool g_stop = false;
uint64_t g_wakeFor = 0;

void PainterMain() {
    uint64_t done = 0;
    for (;;) {
        uint64_t target = 0;
        {
            std::unique_lock<std::mutex> lock(g_wakeLock);
            g_wake.wait(lock, [&] { return g_stop || g_wakeFor != done; });
            if (g_stop) return;
            target = g_wakeFor;
        }
        std::string lines[kTextLines];
        int clock = -1;
        {
            std::lock_guard<std::mutex> lock(g_textLock);
            for (int i = 0; i < kTextLines; ++i) lines[i] = g_lines[i];
            clock = g_clock;
        }
        char clockText[16] = "--:--:--";
        if (clock >= 0) {
            const int s = clock % 86400;
            snprintf(clockText, sizeof(clockText), "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60);
        }
        const char* texts[kTextLines] = {lines[0].c_str(), lines[1].c_str(), lines[2].c_str()};
        std::vector<uint8_t> dots, pixels;
        std::vector<size_t> offsets;
        Compose(texts, kTextLines, clockText, &dots);
        Paint(dots, &pixels, &offsets);
        {
            std::lock_guard<std::mutex> lock(g_pictureLock);
            g_picture.swap(pixels);
            g_levelOffsets.swap(offsets);
            g_pictureVersion = target;
        }
        g_pictureReady.store(target, std::memory_order_release);
        done = target;
    }
}

void Changed() {   // g_textLock held
    g_said = true;
    const uint64_t now = ++g_wanted;
    {
        std::lock_guard<std::mutex> lock(g_wakeLock);
        g_wakeFor = now;
    }
    g_wake.notify_one();
}

// ---- The game's images ------------------------------------------------------------------------------------

struct Image {
    uint64_t handle = 0;
    uint32_t format = 0, width = 0, height = 0, levels = 0;
    int firstLevel = 0;             // which level of our picture its top level is (0: 1920 x 400)
    uint64_t quietSince = 0;        // frame of its creation or of the game's last copy into it
    uint64_t written = 0;           // version of the picture last copied into it
};
std::mutex g_imagesLock;
std::vector<Image> g_images;
std::atomic<int> g_imageCount{0};
std::atomic<uint64_t> g_frame{0};
bool g_enabled = false;

// A fresh image is left alone for this many frames after the game last touched it, so that the game's own
// upload has been carried out and the image is in the state the game draws from.
constexpr uint64_t kQuietFrames = 90;
// At most one copy this often (frames): a clock that runs faster than that skips values on the board.
constexpr uint64_t kMinFramesBetweenCopies = 6;

// The fields of VkImageCreateInfo this needs, read by their place in the structure.
void OnImageCreated(const void* createInfo, uint64_t image) {
    const auto* info = static_cast<const VkImageCreateInfo*>(createInfo);
    if (info->imageType != VK_IMAGE_TYPE_2D || info->extent.depth != 1 || info->arrayLayers != 1) return;
    int first = -1;
    for (int level = 0; level < 5; ++level) {
        if (info->extent.width == static_cast<uint32_t>(kWidth >> level) && info->extent.height == static_cast<uint32_t>(kHeight >> level)) first = level;
    }
    if (first < 0) return;
    const bool plain = info->format == VK_FORMAT_B8G8R8A8_UNORM || info->format == VK_FORMAT_B8G8R8A8_SRGB ||
                       info->format == VK_FORMAT_R8G8B8A8_UNORM || info->format == VK_FORMAT_R8G8B8A8_SRGB;
    TF3_LOG("boards: the game made an image of %u x %u (%u levels, format %d, usage 0x%x)%s", info->extent.width, info->extent.height,
            info->mipLevels, static_cast<int>(info->format), static_cast<unsigned>(info->usage),
            plain ? " - taken as a board's screen" : " - not a format this can write, left alone");
    if (!plain || (info->usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT) == 0) return;
    Image entry;
    entry.handle = image;
    entry.format = static_cast<uint32_t>(info->format);
    entry.width = info->extent.width;
    entry.height = info->extent.height;
    entry.levels = info->mipLevels;
    entry.firstLevel = first;
    entry.quietSince = g_frame.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_imagesLock);
    g_images.push_back(entry);
    g_imageCount.store(static_cast<int>(g_images.size()), std::memory_order_relaxed);
}

void OnImageDestroying(uint64_t image) {
    if (g_imageCount.load(std::memory_order_relaxed) == 0) return;
    std::lock_guard<std::mutex> lock(g_imagesLock);
    for (size_t i = 0; i < g_images.size(); ++i) {
        if (g_images[i].handle == image) {
            g_images.erase(g_images.begin() + static_cast<ptrdiff_t>(i));
            break;
        }
    }
    g_imageCount.store(static_cast<int>(g_images.size()), std::memory_order_relaxed);
}

void OnImageUploaded(uint64_t image) {
    if (g_imageCount.load(std::memory_order_relaxed) == 0) return;
    std::lock_guard<std::mutex> lock(g_imagesLock);
    for (Image& entry : g_images) {
        if (entry.handle == image) {
            entry.quietSince = g_frame.load(std::memory_order_relaxed);
            entry.written = 0;   // the game put the file's picture back: ours has to go in again
        }
    }
}

// ---- Copying a picture into the game's images (the thread that presents) ----------------------------------

#define TF3_BOARDS_VK(X)                                                                                         \
    X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers) X(BeginCommandBuffer) X(EndCommandBuffer) \
    X(ResetCommandBuffer) X(QueueSubmit) X(CreateBuffer) X(DestroyBuffer) X(GetBufferMemoryRequirements)          \
    X(AllocateMemory) X(FreeMemory) X(BindBufferMemory) X(MapMemory) X(CmdPipelineBarrier) X(CmdCopyBufferToImage) \
    X(CreateFence) X(DestroyFence) X(GetFenceStatus) X(ResetFences) X(DeviceWaitIdle)

struct Vk {
#define X(name) PFN_vk##name name = nullptr;
    TF3_BOARDS_VK(X)
#undef X
    PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties = nullptr;
    VkDevice device = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer commands = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory stagingMemory = VK_NULL_HANDLE;
    uint8_t* mapped = nullptr;
    size_t stagingSize = 0;
    bool ready = false, failed = false, busy = false;   // busy: a copy was submitted and its fence not yet seen
    uint64_t staged = 0;            // version of the picture in the staging buffer
    bool stagedSwapped = false;     // whether red and blue are exchanged in it
    uint64_t lastCopyFrame = 0;
};
Vk vk;

void Fail(const char* what, VkResult result) {
    vk.failed = true;
    TF3_LOG("boards: %s failed (VkResult %d) - boards keep their shipped picture for this session", what, static_cast<int>(result));
}

bool EnsureDevice(VkQueue queue) {
    if (vk.ready) return true;
    if (vk.failed) return false;
    vk.device = static_cast<VkDevice>(vkstats::Device());
    const auto physical = static_cast<VkPhysicalDevice>(vkstats::PhysicalDevice());
    if (vk.device == VK_NULL_HANDLE || physical == VK_NULL_HANDLE) return false;   // not yet
    bool ok = true;
#define X(name)                                                                \
    vk.name = reinterpret_cast<PFN_vk##name>(vkstats::DeviceProc("vk" #name)); \
    if (vk.name == nullptr) ok = false;
    TF3_BOARDS_VK(X)
#undef X
    vk.GetPhysicalDeviceMemoryProperties =
        reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(vkstats::InstanceProc("vkGetPhysicalDeviceMemoryProperties"));
    if (!ok || vk.GetPhysicalDeviceMemoryProperties == nullptr) return Fail("loading Vulkan functions", VK_ERROR_INITIALIZATION_FAILED), false;
    const uint32_t family = vkstats::QueueFamilyOf(queue);
    if (family == UINT32_MAX) return Fail("identifying the present queue's family", VK_ERROR_INITIALIZATION_FAILED), false;

    VkCommandPoolCreateInfo pool = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = family;
    VkResult r = vk.CreateCommandPool(vk.device, &pool, nullptr, &vk.pool);
    if (r != VK_SUCCESS) return Fail("creating the command pool", r), false;
    VkCommandBufferAllocateInfo allocate = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocate.commandPool = vk.pool;
    allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate.commandBufferCount = 1;
    r = vk.AllocateCommandBuffers(vk.device, &allocate, &vk.commands);
    if (r != VK_SUCCESS) return Fail("allocating the command buffer", r), false;
    VkFenceCreateInfo fence = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    r = vk.CreateFence(vk.device, &fence, nullptr, &vk.fence);
    if (r != VK_SUCCESS) return Fail("creating the fence", r), false;

    // room for every level of the picture
    size_t size = 0;
    for (int w = kWidth, h = kHeight;; w = (std::max)(1, w / 2), h = (std::max)(1, h / 2)) {
        size += static_cast<size_t>(w) * h * 4;
        if (w == 1 && h == 1) break;
    }
    VkBufferCreateInfo buffer = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    buffer.size = size;
    buffer.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    buffer.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    r = vk.CreateBuffer(vk.device, &buffer, nullptr, &vk.staging);
    if (r != VK_SUCCESS) return Fail("creating the staging buffer", r), false;
    VkMemoryRequirements requirements = {};
    vk.GetBufferMemoryRequirements(vk.device, vk.staging, &requirements);
    VkPhysicalDeviceMemoryProperties properties = {};
    vk.GetPhysicalDeviceMemoryProperties(physical, &properties);
    const VkMemoryPropertyFlags wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint32_t type = UINT32_MAX;
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        if ((requirements.memoryTypeBits & (1u << i)) != 0 && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) {
            type = i;
            break;
        }
    }
    if (type == UINT32_MAX) return Fail("finding host-visible memory", VK_ERROR_FEATURE_NOT_PRESENT), false;
    VkMemoryAllocateInfo memory = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    memory.allocationSize = requirements.size;
    memory.memoryTypeIndex = type;
    r = vk.AllocateMemory(vk.device, &memory, nullptr, &vk.stagingMemory);
    if (r != VK_SUCCESS) return Fail("allocating the staging memory", r), false;
    r = vk.BindBufferMemory(vk.device, vk.staging, vk.stagingMemory, 0);
    if (r != VK_SUCCESS) return Fail("binding the staging memory", r), false;
    void* mapped = nullptr;
    r = vk.MapMemory(vk.device, vk.stagingMemory, 0, VK_WHOLE_SIZE, 0, &mapped);
    if (r != VK_SUCCESS) return Fail("mapping the staging memory", r), false;
    vk.mapped = static_cast<uint8_t*>(mapped);
    vk.stagingSize = size;
    vk.ready = true;
    TF3_LOG("boards: ready to write board screens (staging buffer of %zu bytes)", size);
    return true;
}

// Called before every present, on the thread that presents, with the queue it presents on.
void OnPresenting(void* queueHandle) {
    const uint64_t frame = g_frame.fetch_add(1, std::memory_order_relaxed) + 1;
    if (!g_enabled || vk.failed) return;
    if (g_imageCount.load(std::memory_order_relaxed) == 0) return;
    const uint64_t ready = g_pictureReady.load(std::memory_order_acquire);
    if (ready == 0) return;   // no script has said anything: the shipped picture stays
    const auto queue = static_cast<VkQueue>(queueHandle);
    if (!EnsureDevice(queue)) return;
    if (vk.busy) {
        if (vk.GetFenceStatus(vk.device, vk.fence) != VK_SUCCESS) return;   // the last copy has not run yet
        vk.busy = false;
    }
    if (frame - vk.lastCopyFrame < kMinFramesBetweenCopies) return;

    // which images are due, and in which order of red and blue
    struct Due {
        uint64_t handle;
        uint32_t width, height, levels;
        int firstLevel;
    };
    Due due[8];
    int count = 0;
    bool swapped = false;
    {
        std::lock_guard<std::mutex> lock(g_imagesLock);
        for (Image& entry : g_images) {
            if (entry.written == ready || frame - entry.quietSince < kQuietFrames) continue;
            const bool wantsSwap = entry.format == VK_FORMAT_R8G8B8A8_UNORM || entry.format == VK_FORMAT_R8G8B8A8_SRGB;
            if (count > 0 && wantsSwap != swapped) continue;   // the other order goes in a later copy
            swapped = wantsSwap;
            if (count < 8) {
                due[count++] = {entry.handle, entry.width, entry.height, entry.levels, entry.firstLevel};
                entry.written = ready;
            }
        }
    }
    if (count == 0) return;

    std::vector<size_t> offsets;
    {
        std::lock_guard<std::mutex> lock(g_pictureLock);
        if (g_picture.size() != vk.stagingSize) return;
        offsets = g_levelOffsets;
        if (vk.staged != g_pictureVersion || vk.stagedSwapped != swapped) {
            std::memcpy(vk.mapped, g_picture.data(), vk.stagingSize);
            if (swapped) {
                for (size_t i = 0; i + 3 < vk.stagingSize; i += 4) std::swap(vk.mapped[i], vk.mapped[i + 2]);
            }
            vk.staged = g_pictureVersion;
            vk.stagedSwapped = swapped;
        }
    }

    vk.ResetCommandBuffer(vk.commands, 0);
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    VkResult r = vk.BeginCommandBuffer(vk.commands, &begin);
    if (r != VK_SUCCESS) return Fail("beginning the copy", r);
    for (int i = 0; i < count; ++i) {
        const auto image = reinterpret_cast<VkImage>(due[i].handle);
        const uint32_t levels = (std::min)(due[i].levels, static_cast<uint32_t>(offsets.size() - static_cast<size_t>(due[i].firstLevel)));
        VkImageMemoryBarrier barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, levels, 0, 1};
        barrier.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vk.CmdPipelineBarrier(vk.commands, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
                              nullptr, 1, &barrier);
        VkBufferImageCopy regions[16] = {};
        uint32_t w = due[i].width, h = due[i].height;
        for (uint32_t level = 0; level < levels && level < 16; ++level) {
            regions[level].bufferOffset = offsets[static_cast<size_t>(due[i].firstLevel) + level];
            regions[level].imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, level, 0, 1};
            regions[level].imageExtent = {w, h, 1};
            w = (std::max)(1u, w / 2);
            h = (std::max)(1u, h / 2);
        }
        vk.CmdCopyBufferToImage(vk.commands, vk.staging, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, (std::min)(levels, 16u), regions);
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        vk.CmdPipelineBarrier(vk.commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0,
                              nullptr, 1, &barrier);
    }
    r = vk.EndCommandBuffer(vk.commands);
    if (r != VK_SUCCESS) return Fail("ending the copy", r);
    vk.ResetFences(vk.device, 1, &vk.fence);
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &vk.commands;
    r = vk.QueueSubmit(queue, 1, &submit, vk.fence);
    if (r != VK_SUCCESS) return Fail("submitting the copy", r);
    vk.busy = true;
    vk.lastCopyFrame = frame;
    static bool told = false;
    if (!told) {
        told = true;
        TF3_LOG("boards: first picture written into %d image(s) of the game (%u x %u, %u levels)", count, due[0].width, due[0].height,
                due[0].levels);
    }
}

void OnDeviceDestroying() {
    {
        std::lock_guard<std::mutex> lock(g_imagesLock);
        g_images.clear();
        g_imageCount.store(0, std::memory_order_relaxed);
    }
    if (vk.ready) {
        vk.DeviceWaitIdle(vk.device);
        vk.DestroyFence(vk.device, vk.fence, nullptr);
        vk.DestroyBuffer(vk.device, vk.staging, nullptr);
        vk.FreeMemory(vk.device, vk.stagingMemory, nullptr);
        vk.DestroyCommandPool(vk.device, vk.pool, nullptr);
    }
    vk = Vk();
}

} // namespace

bool SetLines(const char* const* lines, int count) {
    std::lock_guard<std::mutex> lock(g_textLock);
    bool changed = !g_said;
    for (int i = 0; i < kTextLines; ++i) {
        const char* text = (i < count && lines[i] != nullptr) ? lines[i] : "";
        std::string cut(text, strnlen(text, 96));
        if (cut != g_lines[i]) {
            g_lines[i].swap(cut);
            changed = true;
        }
    }
    if (changed) Changed();
    return changed;
}

bool SetClock(int secondsOfDay) {
    std::lock_guard<std::mutex> lock(g_textLock);
    const int value = secondsOfDay < 0 ? -1 : secondsOfDay % 86400;
    if (g_said && value == g_clock) return false;
    g_clock = value;
    Changed();
    return true;
}

int ImagesSeen() { return g_imageCount.load(std::memory_order_relaxed); }

void Install() {
    g_enabled = config::GetBool("Boards", "Enabled", false);
    if (!g_enabled) {
        TF3_LOG("boards: off ([Boards] Enabled=0, the default until it has been seen working)");
        return;
    }
    if (!vkstats::Active() && !config::GetBool("Vulkan", "Hooks", true)) {
        TF3_LOG("boards: needs [Vulkan] Hooks=1 - boards keep their shipped picture");
        g_enabled = false;
        return;
    }
    // The painter lives as long as the process: it is not waited for at unload, where the loader may already
    // have ended it.
    std::thread(PainterMain).detach();
    vkstats::ImageObserver observer;
    observer.created = &OnImageCreated;
    observer.destroying = &OnImageDestroying;
    observer.uploaded = &OnImageUploaded;
    observer.presenting = &OnPresenting;
    observer.deviceDestroying = &OnDeviceDestroying;
    vkstats::SetImageObserver(observer);
    TF3_LOG("boards: watching for board screens (%d x %d images)", kWidth, kHeight);
}

void Uninstall() {
    if (!g_enabled) return;
    vkstats::SetImageObserver(vkstats::ImageObserver());
}

} // namespace tf3api::boards
