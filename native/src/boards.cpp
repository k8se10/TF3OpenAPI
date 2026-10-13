#include "boards.h"

#include "config.h"
#include "log.h"
#include "vkstats.h"

#include <windows.h>

#include <vulkan/vulkan_core.h>

#include <algorithm>
#include <atomic>
#include <chrono>
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

// what a screen shows that no script has set: the board is not connected to anything
const char* const kNotConnected[kTextLines] = {"TF3OpenAPI", "Departure information unavailable", "github.com/k8se10/TF3OpenAPI"};

// The refresh of a real board: a line whose text changes is cleared and the new text drawn in column by
// column from the left. Each line has the moment its refresh began; how far it has come is worked out from
// the time, in kRefreshSteps steps over g_refreshMs ([Boards] RefreshMs; 0 = the new text at once).
constexpr int kRefreshSteps = 40;
int g_refreshMs = 1600;

uint64_t NowMs() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

struct SlotText {
    std::string lines[kRowLines];
    uint64_t refreshFrom[kRowLines] = {};   // NowMs() when the line's refresh began; 0: none (shown whole)
    uint64_t scrollFrom[kRowLines] = {};    // NowMs() from which the line's scrolling field moves; 0: it does not scroll
    uint8_t colour[3] = {255, 150, 24};     // of its lit dots: amber unless a script says otherwise
    bool said = false;       // a script has set this screen's lines
    bool rows = false;       // laid out by the script in rows (SetSlotRows); else three centred lines and the clock
    bool clock = true;       // whether the clock is on it (always, unless rows without the clock's code)
    uint32_t version = 0;    // counts its changes
};
std::mutex g_textLock;
SlotText g_slotText[kSlots];
int g_clock = -1;
std::atomic<bool> g_said{false};   // a script has set something: until then the shipped pictures stay

// How many of a line's refresh steps are done (kRefreshSteps: the whole line is shown).
int RefreshStep(const SlotText& text, int line, uint64_t now) {
    const uint64_t from = text.refreshFrom[line];
    if (from == 0 || g_refreshMs <= 0 || now < from) return kRefreshSteps;
    const uint64_t step = (now - from) * kRefreshSteps / static_cast<uint64_t>(g_refreshMs);
    return step >= kRefreshSteps ? kRefreshSteps : static_cast<int>(step);
}

// Scrolling: kScrollStep columns every kScrollStepMs (25 columns, about four letters, a second), after
// kScrollHoldMs with the line standing still.
constexpr int kScrollStep = 2;
constexpr uint64_t kScrollStepMs = 80, kScrollHoldMs = 2500;
int ScrollColumns(const SlotText& text, int line, uint64_t now) {
    const uint64_t from = text.scrollFrom[line];
    if (from == 0 || now <= from) return 0;
    return static_cast<int>(((now - from) / kScrollStepMs) % 100000) * kScrollStep;
}

// What a screen should show now, as one number (g_textLock held): its text's version, how far its lines'
// refresh has come (a sum that only grows while the version stays; at most 5 x 40 < 2^8), how far its
// scrolling lines have moved (12 bits are enough: only a change matters) and the clock (below 86,400 < 2^20).
uint64_t KeyOf(int slot, uint64_t now) {
    const SlotText& text = g_slotText[slot];
    uint64_t steps = 0, scrolled = 0;
    for (int i = 0; i < kRowLines; ++i) {
        steps += static_cast<uint64_t>(RefreshStep(text, i, now));
        scrolled += static_cast<uint64_t>(ScrollColumns(text, i, now));
    }
    return (static_cast<uint64_t>(text.version) << 40) | (steps << 32) | ((scrolled & 0xfff) << 20) |
           (text.clock ? static_cast<uint64_t>(g_clock + 1) : 0);
}
// whether the screen changes on its own at the moment (a refresh under way, or a line scrolling)
bool Refreshing(int slot, uint64_t now) {
    for (int i = 0; i < kRowLines; ++i) {
        if (RefreshStep(g_slotText[slot], i, now) < kRefreshSteps) return true;
        if (g_slotText[slot].scrollFrom[i] != 0) return true;
    }
    return false;
}

// ---- The painter thread: makes the picture of one screen when asked -------------------------------------
// One request at a time: the presenting thread asks for the screen that is due, takes the finished picture a
// frame or two later and copies it into the game's images of that screen.

struct PaintJob {
    int slot = -1;
    uint64_t key = 0;
    std::string lines[kRowLines];
    bool rows = false;
    int clock = -1;
    int shownTo[kRowLines] = {kColumns, kColumns, kColumns, kColumns, kColumns};   // columns of each line drawn so far
    int scroll[kRowLines] = {};                                                      // how far each line's scrolling field has moved
    uint8_t colour[3] = {255, 150, 24};
};
enum class PaintState { Idle, Asked, Painting, Done };
std::mutex g_jobLock;
std::condition_variable g_wake;
PaintState g_paintState = PaintState::Idle;
PaintJob g_job;                           // the request (Asked, Painting) and what the picture is of (Done)
std::vector<uint8_t> g_picture;           // the finished picture, every level (Done)
std::vector<size_t> g_levelOffsets;

void PainterMain() {
    for (;;) {
        PaintJob job;
        {
            std::unique_lock<std::mutex> lock(g_jobLock);
            g_wake.wait(lock, [] { return g_paintState == PaintState::Asked; });
            g_paintState = PaintState::Painting;
            job = g_job;
        }
        char clockText[16] = "--:--:--";
        if (job.clock >= 0) {
            const int s = job.clock % 86400;
            snprintf(clockText, sizeof(clockText), "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60);
        }
        const char* texts[kRowLines];
        for (int i = 0; i < kRowLines; ++i) texts[i] = job.lines[i].c_str();
        std::vector<uint8_t> dots, pixels;
        std::vector<size_t> offsets;
        if (job.rows) ComposeRows(texts, kRowLines, clockText, job.scroll, &dots);
        else Compose(texts, kTextLines, clockText, &dots);
        for (int i = 0; i < kRowLines; ++i) {
            if (job.shownTo[i] < kColumns) HideFrom(job.rows, i, job.shownTo[i], &dots);
        }
        Paint(dots, SlotWidth(job.slot), SlotHeight(job.slot), job.colour, &pixels, &offsets);
        {
            std::lock_guard<std::mutex> lock(g_jobLock);
            g_picture.swap(pixels);
            g_levelOffsets.swap(offsets);
            g_paintState = PaintState::Done;
        }
    }
}

// ---- The game's images ------------------------------------------------------------------------------------

struct Image {
    uint64_t handle = 0;
    uint32_t format = 0, width = 0, height = 0, levels = 0;
    int slot = 0;                   // which screen it is (known by its size)
    int firstLevel = 0;             // which level of our picture its top level is (0: the full size)
    uint64_t quietSince = 0;        // frame of its creation or of the game's last copy into it
    uint64_t written = ~0ull;       // what the picture last copied into it shows (KeyOf); ~0: nothing of ours
    uint32_t uploads = 0;           // how many times the game copied data into it
};
std::mutex g_imagesLock;
std::vector<Image> g_images;
std::atomic<int> g_imageCount{0};
std::atomic<uint64_t> g_frame{0};
bool g_enabled = false;

// A fresh image is left alone for this many frames after the game last touched it, so that the game's own
// upload has been carried out and the image is in the state the game draws from.
constexpr uint64_t kQuietFrames = 90;
// At most one copy this often (frames): a clock that runs faster than that skips values on the board. While
// a line is being refreshed, more often, so that its new text comes in smoothly.
constexpr uint64_t kMinFramesBetweenCopies = 6;
constexpr uint64_t kMinFramesWhileRefreshing = 2;
std::atomic<bool> g_refreshing{false};

// The images named in the copy that was last submitted, while it may not have run yet (under g_imagesLock).
uint64_t g_pending[8] = {};
int g_pendingCount = 0;
void WaitForPendingCopy();   // defined with the copying code below

// The fields of VkImageCreateInfo this needs, read by their place in the structure.
void OnImageCreated(const void* createInfo, uint64_t image) {
    const auto* info = static_cast<const VkImageCreateInfo*>(createInfo);
    if (info->imageType != VK_IMAGE_TYPE_2D || info->extent.depth != 1 || info->arrayLayers != 1) return;
    // which screen, and which of its levels: the sizes of the screens' files differ by 16 points, so they
    // are still apart at a sixteenth of the size
    int first = -1, slot = -1;
    for (int s = 0; s < kSlots && first < 0; ++s) {
        for (int level = 0; level < 5; ++level) {
            if (info->extent.width == static_cast<uint32_t>(SlotWidth(s) >> level) &&
                info->extent.height == static_cast<uint32_t>(SlotHeight(s) >> level)) {
                first = level;
                slot = s;
                break;
            }
        }
    }
    if (first < 0) return;
    const bool plain = info->format == VK_FORMAT_B8G8R8A8_UNORM || info->format == VK_FORMAT_B8G8R8A8_SRGB ||
                       info->format == VK_FORMAT_R8G8B8A8_UNORM || info->format == VK_FORMAT_R8G8B8A8_SRGB;
    static int told = 0;
    if (told < 40) {   // enough to see what happens; boards come and go with the camera all session long
        ++told;
        TF3_LOG("boards: the game made an image of %u x %u (%u levels, format %d, usage 0x%x) - screen %d%s", info->extent.width,
                info->extent.height, info->mipLevels, static_cast<int>(info->format), static_cast<unsigned>(info->usage), slot,
                plain ? "" : ", not a format this can write, left alone");
    }
    if (!plain || (info->usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT) == 0) return;
    Image entry;
    entry.handle = image;
    entry.format = static_cast<uint32_t>(info->format);
    entry.width = info->extent.width;
    entry.height = info->extent.height;
    entry.levels = info->mipLevels;
    entry.firstLevel = first;
    entry.slot = slot;
    entry.quietSince = g_frame.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_imagesLock);
    g_images.push_back(entry);
    g_imageCount.store(static_cast<int>(g_images.size()), std::memory_order_relaxed);
}

void OnImageDestroying(uint64_t image) {
    if (g_imageCount.load(std::memory_order_relaxed) == 0 && g_pendingCount == 0) return;
    std::lock_guard<std::mutex> lock(g_imagesLock);
    // The game knows nothing of our copy: if this image is named in one that has not run yet, the image must
    // outlive it. Destroying an image a pending command still writes to loses the device.
    for (int i = 0; i < g_pendingCount; ++i) {
        if (g_pending[i] == image) {
            WaitForPendingCopy();
            break;
        }
    }
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
            entry.written = ~0ull;   // the game put the file's picture back: ours has to go in again
            if (entry.uploads < 0xffffffffu) ++entry.uploads;
        }
    }
}

// ---- Copying a picture into the game's images (the thread that presents) ----------------------------------

#define TF3_BOARDS_VK(X)                                                                                         \
    X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers) X(BeginCommandBuffer) X(EndCommandBuffer) \
    X(ResetCommandBuffer) X(QueueSubmit) X(CreateBuffer) X(DestroyBuffer) X(GetBufferMemoryRequirements)          \
    X(AllocateMemory) X(FreeMemory) X(BindBufferMemory) X(MapMemory) X(CmdPipelineBarrier) X(CmdCopyBufferToImage) \
    X(CreateFence) X(DestroyFence) X(GetFenceStatus) X(ResetFences) X(WaitForFences) X(DeviceWaitIdle)

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
    uint64_t lastCopyFrame = 0;
    int nextSlot = 0;               // where the search for a screen that is due starts (so that all get a turn)
};
Vk vk;

// Under g_imagesLock. Waits (at most a second) for the copy last submitted to have run.
void WaitForPendingCopy() {
    if (vk.ready && vk.busy) {
        const VkResult r = vk.WaitForFences(vk.device, 1, &vk.fence, VK_TRUE, 1000000000ull);
        if (r == VK_SUCCESS) vk.busy = false;
        static bool told = false;
        if (!told) {
            told = true;
            TF3_LOG("boards: the game released a screen image while a copy into it was still to run - waited for the copy (%s)",
                    r == VK_SUCCESS ? "done" : "it did not finish within a second");
        }
    }
    g_pendingCount = 0;
}

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

    // room for every level of the largest screen's picture
    size_t size = 0;
    for (int w = SlotWidth(7), h = SlotHeight(kSlots - 1);; w = (std::max)(1, w / 2), h = (std::max)(1, h / 2)) {
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
    const auto queue = static_cast<VkQueue>(queueHandle);
    if (!EnsureDevice(queue)) return;
    if (frame - vk.lastCopyFrame < (g_refreshing.load(std::memory_order_relaxed) ? kMinFramesWhileRefreshing : kMinFramesBetweenCopies)) return;

    // From here to the submit the list of images is held: the game cannot destroy one of them in between
    // (its vkDestroyImage waits in OnImageDestroying), and once submitted, a destroy waits for the copy.
    std::lock_guard<std::mutex> imagesLock(g_imagesLock);
    if (vk.busy) {
        if (vk.GetFenceStatus(vk.device, vk.fence) != VK_SUCCESS) return;   // the last copy has not run yet
        vk.busy = false;
        g_pendingCount = 0;
    }

    if (!g_said.load(std::memory_order_relaxed)) return;   // no script has said anything: the shipped pictures stay

    // what each screen should show now
    uint64_t keys[kSlots];
    const uint64_t now = NowMs();
    {
        std::lock_guard<std::mutex> lock(g_textLock);
        bool refreshing = false;
        for (int s = 0; s < kSlots; ++s) {
            keys[s] = KeyOf(s, now);
            if (Refreshing(s, now)) refreshing = true;
        }
        g_refreshing.store(refreshing, std::memory_order_relaxed);
    }
    const auto isDue = [&](const Image& entry, uint64_t key) {
        return entry.uploads != 0 && entry.written != key && frame - entry.quietSince >= kQuietFrames;
    };

    // Only an image the game has itself copied data into is written to (uploads): that is a texture in use,
    // with memory behind it. The game also makes images of a screen's size that it never fills.
    struct Due {
        uint64_t handle;
        uint32_t width, height, levels;
        int firstLevel;
    };
    Due due[8];
    int count = 0;
    bool swapped = false;
    std::vector<size_t> offsets;
    {
        std::lock_guard<std::mutex> lock(g_jobLock);
        if (g_paintState == PaintState::Done) {
            // a picture is finished: into every image of its screen that does not show it yet
            for (Image& entry : g_images) {
                if (entry.slot != g_job.slot || !isDue(entry, g_job.key)) continue;
                const bool wantsSwap = entry.format == VK_FORMAT_R8G8B8A8_UNORM || entry.format == VK_FORMAT_R8G8B8A8_SRGB;
                if (count > 0 && wantsSwap != swapped) continue;   // the other order of red and blue: a later copy
                swapped = wantsSwap;
                if (count < 8) {
                    due[count++] = {entry.handle, entry.width, entry.height, entry.levels, entry.firstLevel};
                    entry.written = g_job.key;
                }
            }
            if (count > 0 && g_picture.size() <= vk.stagingSize) {
                std::memcpy(vk.mapped, g_picture.data(), g_picture.size());
                if (swapped) {
                    for (size_t i = 0; i + 3 < g_picture.size(); i += 4) std::swap(vk.mapped[i], vk.mapped[i + 2]);
                }
                offsets = g_levelOffsets;
            } else {
                count = 0;
            }
            g_paintState = PaintState::Idle;
        }
        // (also right after a copy: the finished picture is already in the staging buffer)
        if (g_paintState == PaintState::Idle) {
            // ask for the picture of the next screen that is due
            for (int step = 0; step < kSlots; ++step) {
                const int s = (vk.nextSlot + step) % kSlots;
                bool wanted = false;
                for (const Image& entry : g_images) {
                    if (entry.slot == s && isDue(entry, keys[s])) wanted = true;
                }
                if (!wanted) continue;
                g_job.slot = s;
                g_job.key = keys[s];
                {
                    std::lock_guard<std::mutex> text(g_textLock);
                    g_job.key = KeyOf(s, now);
                    g_job.clock = g_clock;
                    for (int i = 0; i < kRowLines; ++i) {
                        const int done = g_slotText[s].said ? RefreshStep(g_slotText[s], i, now) : kRefreshSteps;
                        g_job.shownTo[i] = done >= kRefreshSteps ? kColumns : done * kColumns / kRefreshSteps;
                        g_job.scroll[i] = g_slotText[s].said ? ScrollColumns(g_slotText[s], i, now) : 0;
                    }
                    std::memcpy(g_job.colour, g_slotText[s].colour, sizeof(g_job.colour));
                    g_job.rows = g_slotText[s].said && g_slotText[s].rows;
                    for (int i = 0; i < kRowLines; ++i) {
                        if (g_slotText[s].said) g_job.lines[i] = g_slotText[s].lines[i];
                        else g_job.lines[i] = i < kTextLines ? std::string(kNotConnected[i]) : std::string();
                    }
                }
                g_paintState = PaintState::Asked;
                vk.nextSlot = (s + 1) % kSlots;
                break;
            }
            if (g_paintState == PaintState::Asked) g_wake.notify_one();
        }
    }
    if (count == 0) return;

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
    vkstats::LockQueues();   // one thread at a time on a queue: the game's own submits hold the same lock
    r = vk.QueueSubmit(queue, 1, &submit, vk.fence);
    vkstats::UnlockQueues();
    if (r != VK_SUCCESS) return Fail("submitting the copy", r);
    vk.busy = true;
    vk.lastCopyFrame = frame;
    g_pendingCount = count;
    for (int i = 0; i < count; ++i) g_pending[i] = due[i].handle;
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
        g_pendingCount = 0;
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

namespace {
// g_textLock is taken here. rows: the script's own layout (kRowLines rows) or the three centred lines.
bool SetSlot(int slot, const char* const* lines, int count, bool rows) {
    if (slot < 0 || slot >= kSlots) return false;
    std::lock_guard<std::mutex> lock(g_textLock);
    SlotText& text = g_slotText[slot];
    bool changed = !text.said || text.rows != rows;
    bool clock = !rows;
    for (int i = 0; i < kRowLines; ++i) {
        const char* line = (i < count && i < (rows ? kRowLines : kTextLines) && lines[i] != nullptr) ? lines[i] : "";
        std::string cut(line, strnlen(line, 600));   // a calling-points row may be long: it scrolls
        if (rows && cut.find('\x01') != std::string::npos) clock = true;
        if (cut != text.lines[i]) {
            // the new text is drawn in from the left (an emptied line just goes dark)
            const uint64_t now = (std::max)(NowMs(), uint64_t{1});
            text.refreshFrom[i] = g_refreshMs > 0 && !cut.empty() ? now : 0;
            // a line too long for its room starts to move once it has been drawn in and read for a moment
            text.scrollFrom[i] = rows && RowScrolls(cut.c_str()) ? now + static_cast<uint64_t>((std::max)(0, g_refreshMs)) + kScrollHoldMs : 0;
            text.lines[i].swap(cut);
            changed = true;
        }
    }
    if (changed) {
        text.rows = rows;
        text.clock = clock;
        text.said = true;
        ++text.version;
        g_said.store(true, std::memory_order_relaxed);
    }
    return changed;
}
} // namespace

bool SetSlotLines(int slot, const char* const* lines, int count) { return SetSlot(slot, lines, count, false); }
bool SetSlotRows(int slot, const char* const* rows, int count) { return SetSlot(slot, rows, count, true); }
bool SetLines(const char* const* lines, int count) { return SetSlotLines(0, lines, count); }

bool SetSlotColour(int slot, uint8_t red, uint8_t green, uint8_t blue) {
    if (slot < 0 || slot >= kSlots) return false;
    std::lock_guard<std::mutex> lock(g_textLock);
    SlotText& text = g_slotText[slot];
    if (text.colour[0] == red && text.colour[1] == green && text.colour[2] == blue) return false;
    text.colour[0] = red;
    text.colour[1] = green;
    text.colour[2] = blue;
    ++text.version;
    return true;
}

bool SetClock(int secondsOfDay) {
    std::lock_guard<std::mutex> lock(g_textLock);
    const int value = secondsOfDay < 0 ? -1 : secondsOfDay % 86400;
    if (g_said.load(std::memory_order_relaxed) && value == g_clock) return false;
    g_clock = value;
    g_said.store(true, std::memory_order_relaxed);
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
    g_refreshMs = (std::max)(0, (std::min)(10000, config::GetInt("Boards", "RefreshMs", 1600)));
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
    TF3_LOG("boards: watching for board screens (%d screens, images from %d x %d); a changed line is redrawn over %d ms", kSlots, kWidth, kHeight,
            g_refreshMs);
}

void Uninstall() {
    if (!g_enabled) return;
    vkstats::SetImageObserver(vkstats::ImageObserver());
}

} // namespace tf3api::boards
