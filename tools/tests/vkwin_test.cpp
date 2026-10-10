// Test window for the overlay: a minimal Vulkan application that behaves like the game does where it
// matters - it loads vulkan-1.dll at runtime, fetches every function by name, renders a frame, and presents
// it waiting on a semaphore. The proxy winhttp.dll beside it (built from native/) hooks in exactly as it
// does in the game, so the overlay draws on this window. The Khronos validation layer is enabled when
// installed and every message it prints counts as a failure.
//
// It presents some frames, saves a screenshot of the window (overlay_shot.bmp), replaces the swapchain once
// (the path a resolution change takes), presents more frames and shuts down in order.
//
// Build: cl /EHsc /O2 /std:c++20 /I <VulkanSDK>\Include vkwin_test.cpp user32.lib gdi32.lib
#include <windows.h>
#include <winhttp.h>

#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#include <vulkan/vulkan.h>

#include <cstdio>
#include <cstring>
#include <vector>

#pragma comment(lib, "winhttp.lib")

static int g_validationMessages = 0;
static VKAPI_ATTR VkBool32 VKAPI_CALL OnDebug(VkDebugUtilsMessageSeverityFlagBitsEXT severity, VkDebugUtilsMessageTypeFlagsEXT,
                                              const VkDebugUtilsMessengerCallbackDataEXT* data, void*) {
    if (severity >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        ++g_validationMessages;
        printf("VALIDATION: %s\n", data->pMessage);
    }
    return VK_FALSE;
}

static PFN_vkGetInstanceProcAddr gipa;
static PFN_vkGetDeviceProcAddr gdpa;
static VkInstance instance;
static VkDevice device;
#define INST(name) auto name = (PFN_##name)gipa(instance, #name)
#define DEV(name) auto name = (PFN_##name)gdpa(device, #name)

static void SaveWindowBmp(HWND window, const char* path) {
    RECT rc;
    GetClientRect(window, &rc);
    POINT origin = {0, 0};
    ClientToScreen(window, &origin);
    const int w = rc.right, h = rc.bottom;
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    void* bits = nullptr;
    HBITMAP bitmap = CreateDIBSection(memory, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ old = SelectObject(memory, bitmap);
    BitBlt(memory, 0, 0, w, h, screen, origin.x, origin.y, SRCCOPY);
    GdiFlush();
    BITMAPFILEHEADER file = {};
    file.bfType = 0x4D42;
    file.bfOffBits = sizeof(file) + sizeof(info.bmiHeader);
    file.bfSize = file.bfOffBits + static_cast<DWORD>(w) * h * 4;
    FILE* f = nullptr;
    if (fopen_s(&f, path, "wb") == 0 && f) {
        fwrite(&file, sizeof(file), 1, f);
        fwrite(&info.bmiHeader, sizeof(info.bmiHeader), 1, f);
        fwrite(bits, 4, static_cast<size_t>(w) * h, f);
        fclose(f);
    }
    SelectObject(memory, old);
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
}

int main() {
    WinHttpCloseHandle(WinHttpOpen(L"t", WINHTTP_ACCESS_TYPE_NO_PROXY, nullptr, nullptr, 0));  // pulls in the proxy DLL
    Sleep(500);                                                                                 // let it install its hooks

    WNDCLASSW wc = {};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"tf3api_vkwin";
    RegisterClassW(&wc);
    RECT rect = {0, 0, 1100, 620};
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    HWND window = CreateWindowW(wc.lpszClassName, L"tf3api overlay test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 60, 60,
                                rect.right - rect.left, rect.bottom - rect.top, nullptr, nullptr, wc.hInstance, nullptr);
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
    SetForegroundWindow(window);

    HMODULE loader = LoadLibraryW(L"vulkan-1.dll");
    gipa = (PFN_vkGetInstanceProcAddr)GetProcAddress(loader, "vkGetInstanceProcAddr");
    auto vkEnumerateInstanceLayerProperties = (PFN_vkEnumerateInstanceLayerProperties)gipa(nullptr, "vkEnumerateInstanceLayerProperties");
    auto vkCreateInstance = (PFN_vkCreateInstance)gipa(nullptr, "vkCreateInstance");
    uint32_t layerCount = 0;
    vkEnumerateInstanceLayerProperties(&layerCount, nullptr);
    std::vector<VkLayerProperties> layers(layerCount);
    vkEnumerateInstanceLayerProperties(&layerCount, layers.data());
    bool haveValidation = false;
    for (const auto& l : layers) haveValidation |= strcmp(l.layerName, "VK_LAYER_KHRONOS_validation") == 0;
    printf("validation layer: %s\n", haveValidation ? "on" : "NOT INSTALLED");

    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_1;
    const char* instanceExtensions[] = {"VK_KHR_surface", "VK_KHR_win32_surface", "VK_EXT_debug_utils"};
    const char* validation = "VK_LAYER_KHRONOS_validation";
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 3;
    ici.ppEnabledExtensionNames = instanceExtensions;
    ici.enabledLayerCount = haveValidation ? 1 : 0;
    ici.ppEnabledLayerNames = &validation;
    if (vkCreateInstance(&ici, nullptr, &instance) != VK_SUCCESS) return printf("createInstance failed\n"), 2;

    INST(vkCreateDebugUtilsMessengerEXT);
    INST(vkDestroyDebugUtilsMessengerEXT);
    VkDebugUtilsMessengerCreateInfoEXT dci = {VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT};
    dci.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    dci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT;
    dci.pfnUserCallback = OnDebug;
    VkDebugUtilsMessengerEXT messenger = VK_NULL_HANDLE;
    vkCreateDebugUtilsMessengerEXT(instance, &dci, nullptr, &messenger);

    INST(vkCreateWin32SurfaceKHR);
    INST(vkDestroySurfaceKHR);
    INST(vkEnumeratePhysicalDevices);
    INST(vkGetPhysicalDeviceProperties);
    INST(vkGetPhysicalDeviceQueueFamilyProperties);
    INST(vkGetPhysicalDeviceSurfaceSupportKHR);
    INST(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    INST(vkGetPhysicalDeviceSurfaceFormatsKHR);
    INST(vkCreateDevice);
    INST(vkDestroyInstance);
    VkWin32SurfaceCreateInfoKHR sci = {VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
    sci.hinstance = wc.hInstance;
    sci.hwnd = window;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    vkCreateWin32SurfaceKHR(instance, &sci, nullptr, &surface);

    uint32_t physCount = 8;
    VkPhysicalDevice phys[8];
    vkEnumeratePhysicalDevices(instance, &physCount, phys);
    VkPhysicalDevice chosen = phys[0];
    for (uint32_t i = 0; i < physCount; ++i) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(phys[i], &p);
        if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) chosen = phys[i];
    }
    uint32_t familyCount = 16;
    VkQueueFamilyProperties families[16];
    vkGetPhysicalDeviceQueueFamilyProperties(chosen, &familyCount, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < familyCount; ++i) {
        VkBool32 present = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(chosen, i, surface, &present);
        if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
            family = i;
            break;
        }
    }
    if (family == UINT32_MAX) return printf("no queue family\n"), 3;

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;
    const char* deviceExtensions[] = {"VK_KHR_swapchain"};
    VkDeviceCreateInfo devInfo = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    devInfo.queueCreateInfoCount = 1;
    devInfo.pQueueCreateInfos = &qci;
    devInfo.enabledExtensionCount = 1;
    devInfo.ppEnabledExtensionNames = deviceExtensions;
    if (vkCreateDevice(chosen, &devInfo, nullptr, &device) != VK_SUCCESS) return printf("createDevice failed\n"), 4;
    gdpa = (PFN_vkGetDeviceProcAddr)gipa(instance, "vkGetDeviceProcAddr");

    DEV(vkGetDeviceQueue);
    DEV(vkCreateSwapchainKHR);
    DEV(vkDestroySwapchainKHR);
    DEV(vkGetSwapchainImagesKHR);
    DEV(vkAcquireNextImageKHR);
    DEV(vkQueuePresentKHR);
    DEV(vkQueueSubmit);
    DEV(vkCreateCommandPool);
    DEV(vkDestroyCommandPool);
    DEV(vkAllocateCommandBuffers);
    DEV(vkBeginCommandBuffer);
    DEV(vkEndCommandBuffer);
    DEV(vkResetCommandBuffer);
    DEV(vkCmdPipelineBarrier);
    DEV(vkCmdClearColorImage);
    DEV(vkCreateSemaphore);
    DEV(vkDestroySemaphore);
    DEV(vkCreateFence);
    DEV(vkDestroyFence);
    DEV(vkWaitForFences);
    DEV(vkResetFences);
    DEV(vkDeviceWaitIdle);
    DEV(vkDestroyDevice);

    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, family, 0, &queue);
    uint32_t formatCount = 32;
    VkSurfaceFormatKHR formats[32];
    vkGetPhysicalDeviceSurfaceFormatsKHR(chosen, surface, &formatCount, formats);
    VkSurfaceFormatKHR format = formats[0];
    for (uint32_t i = 0; i < formatCount; ++i) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) format = formats[i];
    }

    VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pci.queueFamilyIndex = family;
    VkCommandPool pool = VK_NULL_HANDLE;
    vkCreateCommandPool(device, &pci, nullptr, &pool);
    VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cai.commandPool = pool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    VkCommandBuffer cb = VK_NULL_HANDLE;
    vkAllocateCommandBuffers(device, &cai, &cb);
    VkSemaphoreCreateInfo semInfo = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkSemaphore acquired = VK_NULL_HANDLE;
    vkCreateSemaphore(device, &semInfo, nullptr, &acquired);
    // one "rendered" semaphore per swapchain image: a semaphore a present waited on may only be reused once
    // that image has been acquired again
    VkSemaphore rendered[8] = {};
    for (VkSemaphore& s : rendered) vkCreateSemaphore(device, &semInfo, nullptr, &s);
    VkFenceCreateInfo fenceInfo = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence frameDone = VK_NULL_HANDLE;
    vkCreateFence(device, &fenceInfo, nullptr, &frameDone);

    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    std::vector<VkImage> images;
    VkExtent2D extent = {};
    auto makeSwapchain = [&]() {
        VkSurfaceCapabilitiesKHR caps;
        vkGetPhysicalDeviceSurfaceCapabilitiesKHR(chosen, surface, &caps);
        extent = caps.currentExtent;
        VkSwapchainCreateInfoKHR info = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
        info.surface = surface;
        info.minImageCount = caps.minImageCount + 1;
        info.imageFormat = format.format;
        info.imageColorSpace = format.colorSpace;
        info.imageExtent = extent;
        info.imageArrayLayers = 1;
        info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.preTransform = caps.currentTransform;
        info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
        info.clipped = VK_TRUE;
        info.oldSwapchain = swapchain;
        VkSwapchainKHR created = VK_NULL_HANDLE;
        vkCreateSwapchainKHR(device, &info, nullptr, &created);
        if (swapchain != VK_NULL_HANDLE) vkDestroySwapchainKHR(device, swapchain, nullptr);
        swapchain = created;
        uint32_t count = 0;
        vkGetSwapchainImagesKHR(device, swapchain, &count, nullptr);
        images.resize(count);
        vkGetSwapchainImagesKHR(device, swapchain, &count, images.data());
    };

    auto frame = [&](float shade) -> bool {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        uint32_t index = 0;
        if (vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &index) != VK_SUCCESS) return false;
        vkResetCommandBuffer(cb, 0);
        VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        vkBeginCommandBuffer(cb, &begin);
        VkImageMemoryBarrier barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = images[index];
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        const VkClearColorValue colour = {{0.30f * shade, 0.42f * shade, 0.28f * shade, 1.0f}};  // a "terrain" green
        vkCmdClearColorImage(cb, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &colour, 1, &barrier.subresourceRange);
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = 0;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        vkEndCommandBuffer(cb);
        const VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &acquired;
        submit.pWaitDstStageMask = &waitStage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cb;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &rendered[index];
        vkQueueSubmit(queue, 1, &submit, frameDone);
        VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &rendered[index];
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &index;
        const VkResult r = vkQueuePresentKHR(queue, &present);
        vkWaitForFences(device, 1, &frameDone, VK_TRUE, UINT64_MAX);
        vkResetFences(device, 1, &frameDone);
        return r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR;
    };

    makeSwapchain();
    printf("swapchain %ux%u, %zu images, format %d\n", extent.width, extent.height, images.size(), (int)format.format);
    int presented = 0;
    for (int i = 0; i < 60; ++i) presented += frame(1.0f);
    Sleep(150);
    SaveWindowBmp(window, "overlay_shot.bmp");
    vkDeviceWaitIdle(device);
    makeSwapchain();  // what a resolution change does: new swapchain, old one retired
    for (int i = 0; i < 30; ++i) presented += frame(0.8f);
    printf("frames presented: %d of 90\n", presented);

    vkDeviceWaitIdle(device);
    vkDestroyFence(device, frameDone, nullptr);
    vkDestroySemaphore(device, acquired, nullptr);
    for (VkSemaphore s : rendered) vkDestroySemaphore(device, s, nullptr);
    vkDestroyCommandPool(device, pool, nullptr);
    vkDestroySwapchainKHR(device, swapchain, nullptr);
    vkDestroyDevice(device, nullptr);
    vkDestroySurfaceKHR(instance, surface, nullptr);
    if (messenger != VK_NULL_HANDLE) vkDestroyDebugUtilsMessengerEXT(instance, messenger, nullptr);
    vkDestroyInstance(instance, nullptr);
    DestroyWindow(window);
    printf("validation messages: %d\n", g_validationMessages);
    printf("%s\n", (presented == 90 && g_validationMessages == 0) ? "ALL OK" : "FAILED");
    return (presented == 90 && g_validationMessages == 0) ? 0 : 1;
}
