#include "mc_vk_passive_hook.hpp"

#include <dlfcn.h>
#include <android/log.h>
#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#define LOG_TAG "LSFG-PROBE"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// Function pointer typedefs
using PFN_vkCreateSwapchainKHR = VkResult(VKAPI_PTR *)(
    VkDevice device,
    const VkSwapchainCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkSwapchainKHR *pSwapchain);

using PFN_vkDestroySwapchainKHR = void(VKAPI_PTR *)(
    VkDevice device,
    VkSwapchainKHR swapchain,
    const VkAllocationCallbacks *pAllocator);

using PFN_vkGetSwapchainImagesKHR = VkResult(VKAPI_PTR *)(
    VkDevice device,
    VkSwapchainKHR swapchain,
    uint32_t *pSwapchainImageCount,
    VkImage *pSwapchainImages);

using PFN_vkAcquireNextImageKHR = VkResult(VKAPI_PTR *)(
    VkDevice device,
    VkSwapchainKHR swapchain,
    uint64_t timeout,
    VkSemaphore semaphore,
    VkFence fence,
    uint32_t *pImageIndex);

using PFN_vkAcquireNextImage2KHR = VkResult(VKAPI_PTR *)(
    VkDevice device,
    const VkAcquireNextImageInfoKHR *pAcquireInfo,
    uint32_t *pImageIndex);

using PFN_vkQueuePresentKHR = VkResult(VKAPI_PTR *)(
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo);

// Real Vulkan pointers
void *g_vulkanLibHandle = nullptr;
PFN_vkGetInstanceProcAddr g_realGipa = nullptr;
PFN_vkGetDeviceProcAddr g_realGdpa = nullptr;

PFN_vkCreateSwapchainKHR g_realCreateSwapchainKHR = nullptr;
PFN_vkDestroySwapchainKHR g_realDestroySwapchainKHR = nullptr;
PFN_vkGetSwapchainImagesKHR g_realGetSwapchainImagesKHR = nullptr;
PFN_vkAcquireNextImageKHR g_realAcquireNextImageKHR = nullptr;
PFN_vkAcquireNextImage2KHR g_realAcquireNextImage2KHR = nullptr;
PFN_vkQueuePresentKHR g_realQueuePresentKHR = nullptr;

// First-call logging flags
std::atomic<bool> g_vulkanObserved{false};
std::atomic<bool> g_firstGipaLogged{false};
std::atomic<bool> g_firstGdpaLogged{false};
std::atomic<bool> g_firstCreateSwapchainLogged{false};
std::atomic<bool> g_firstAcquireLogged{false};
std::atomic<bool> g_firstAcquire2Logged{false};
std::atomic<bool> g_firstPresentLogged{false};

// Authoritative native atomics
std::atomic<uint32_t> g_gipaCalls{0};
std::atomic<uint32_t> g_gdpaCalls{0};
std::atomic<uint32_t> g_createInstanceCalls{0};
std::atomic<uint32_t> g_createDeviceCalls{0};
std::atomic<uint32_t> g_createSwapchainCalls{0};
std::atomic<uint32_t> g_destroySwapchainCalls{0};
std::atomic<uint32_t> g_getSwapchainImagesCalls{0};
std::atomic<uint32_t> g_acquireNextImageCalls{0};
std::atomic<uint32_t> g_acquireNextImage2Calls{0};
std::atomic<uint32_t> g_queuePresentCalls{0};

std::atomic<uintptr_t> g_lastInstance{0};
std::atomic<uintptr_t> g_lastDevice{0};
std::atomic<uintptr_t> g_lastQueue{0};
std::atomic<uintptr_t> g_lastSwapchain{0};

std::atomic<uint32_t> g_swapchainWidth{0};
std::atomic<uint32_t> g_swapchainHeight{0};
std::atomic<int32_t> g_swapchainFormat{0};
std::atomic<uint32_t> g_swapchainImageCount{0};

void ensure_real_vulkan_loaded() {
    if (g_realGipa && g_realGdpa) return;

    // 1. Check if Amethyst exported VULKAN_PTR in environment
    const char *vulkanPtrEnv = std::getenv("VULKAN_PTR");
    if (vulkanPtrEnv != nullptr && *vulkanPtrEnv != '\0') {
        char *end = nullptr;
        unsigned long ptrVal = std::strtoul(vulkanPtrEnv, &end, 16);
        if (ptrVal != 0) {
            g_vulkanLibHandle = reinterpret_cast<void *>(ptrVal);
            LOGI("[LSFG-PROBE] Discovered Amethyst VULKAN_PTR: %p", g_vulkanLibHandle);
        }
    }

    // 2. If not found or null, open libvulkan.so directly
    if (g_vulkanLibHandle == nullptr) {
        g_vulkanLibHandle = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
        LOGI("[LSFG-PROBE] Opened libvulkan.so: %p", g_vulkanLibHandle);
    }

    if (g_vulkanLibHandle != nullptr) {
        g_realGipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
            dlsym(g_vulkanLibHandle, "vkGetInstanceProcAddr"));
        g_realGdpa = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
            dlsym(g_vulkanLibHandle, "vkGetDeviceProcAddr"));
    }

    // Fallback to RTLD_DEFAULT if still null
    if (g_realGipa == nullptr) {
        g_realGipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
            dlsym(RTLD_DEFAULT, "vkGetInstanceProcAddr"));
    }
    if (g_realGdpa == nullptr) {
        g_realGdpa = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
            dlsym(RTLD_DEFAULT, "vkGetDeviceProcAddr"));
    }

    LOGI("[LSFG-PROBE] Real GIPA=%p, Real GDPA=%p", g_realGipa, g_realGdpa);
}

// -----------------------------------------------------------------------------
// Passive Pass-Through Vulkan Wrappers
// -----------------------------------------------------------------------------

VKAPI_ATTR VkResult VKAPI_CALL lsfg_vkCreateSwapchainKHR(
    VkDevice device,
    const VkSwapchainCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkSwapchainKHR *pSwapchain)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_createSwapchainCalls.fetch_add(1, std::memory_order_relaxed);
    g_lastDevice.store(reinterpret_cast<uintptr_t>(device), std::memory_order_relaxed);

    if (!g_firstCreateSwapchainLogged.exchange(true)) {
        LOGI("[LSFG-PROBE] first vkCreateSwapchainKHR");
    }

    if (pCreateInfo != nullptr) {
        g_swapchainWidth.store(pCreateInfo->imageExtent.width, std::memory_order_relaxed);
        g_swapchainHeight.store(pCreateInfo->imageExtent.height, std::memory_order_relaxed);
        g_swapchainFormat.store(static_cast<int32_t>(pCreateInfo->imageFormat), std::memory_order_relaxed);
    }

    ensure_real_vulkan_loaded();
    PFN_vkCreateSwapchainKHR realFunc = g_realCreateSwapchainKHR;
    if (realFunc == nullptr && g_realGdpa != nullptr) {
        realFunc = reinterpret_cast<PFN_vkCreateSwapchainKHR>(
            g_realGdpa(device, "vkCreateSwapchainKHR"));
    }

    if (realFunc == nullptr) {
        LOGE("[LSFG-PROBE] Could not resolve real vkCreateSwapchainKHR!");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // STRICT PASS-THROUGH: Forward create info UNCHANGED
    VkResult res = realFunc(device, pCreateInfo, pAllocator, pSwapchain);

    if (res == VK_SUCCESS && pSwapchain != nullptr && *pSwapchain != VK_NULL_HANDLE) {
        g_lastSwapchain.store(reinterpret_cast<uintptr_t>(*pSwapchain), std::memory_order_relaxed);

        PFN_vkGetSwapchainImagesKHR getImages = g_realGetSwapchainImagesKHR;
        if (getImages == nullptr && g_realGdpa != nullptr) {
            getImages = reinterpret_cast<PFN_vkGetSwapchainImagesKHR>(
                g_realGdpa(device, "vkGetSwapchainImagesKHR"));
        }
        if (getImages != nullptr) {
            uint32_t actualCount = 0;
            if (getImages(device, *pSwapchain, &actualCount, nullptr) == VK_SUCCESS) {
                g_swapchainImageCount.store(actualCount, std::memory_order_relaxed);
            }
        }
    }

    return res;
}

VKAPI_ATTR void VKAPI_CALL lsfg_vkDestroySwapchainKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    const VkAllocationCallbacks *pAllocator)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_destroySwapchainCalls.fetch_add(1, std::memory_order_relaxed);

    ensure_real_vulkan_loaded();
    PFN_vkDestroySwapchainKHR realFunc = g_realDestroySwapchainKHR;
    if (realFunc == nullptr && g_realGdpa != nullptr) {
        realFunc = reinterpret_cast<PFN_vkDestroySwapchainKHR>(
            g_realGdpa(device, "vkDestroySwapchainKHR"));
    }

    if (realFunc != nullptr) {
        realFunc(device, swapchain, pAllocator);
    }
}

VKAPI_ATTR VkResult VKAPI_CALL lsfg_vkGetSwapchainImagesKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    uint32_t *pSwapchainImageCount,
    VkImage *pSwapchainImages)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_getSwapchainImagesCalls.fetch_add(1, std::memory_order_relaxed);

    ensure_real_vulkan_loaded();
    PFN_vkGetSwapchainImagesKHR realFunc = g_realGetSwapchainImagesKHR;
    if (realFunc == nullptr && g_realGdpa != nullptr) {
        realFunc = reinterpret_cast<PFN_vkGetSwapchainImagesKHR>(
            g_realGdpa(device, "vkGetSwapchainImagesKHR"));
    }

    if (realFunc == nullptr) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    return realFunc(device, swapchain, pSwapchainImageCount, pSwapchainImages);
}

VKAPI_ATTR VkResult VKAPI_CALL lsfg_vkAcquireNextImageKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    uint64_t timeout,
    VkSemaphore semaphore,
    VkFence fence,
    uint32_t *pImageIndex)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_acquireNextImageCalls.fetch_add(1, std::memory_order_relaxed);
    g_lastDevice.store(reinterpret_cast<uintptr_t>(device), std::memory_order_relaxed);
    g_lastSwapchain.store(reinterpret_cast<uintptr_t>(swapchain), std::memory_order_relaxed);

    if (!g_firstAcquireLogged.exchange(true)) {
        LOGI("[LSFG-PROBE] first vkAcquireNextImageKHR");
    }

    ensure_real_vulkan_loaded();
    PFN_vkAcquireNextImageKHR realFunc = g_realAcquireNextImageKHR;
    if (realFunc == nullptr && g_realGdpa != nullptr) {
        realFunc = reinterpret_cast<PFN_vkAcquireNextImageKHR>(
            g_realGdpa(device, "vkAcquireNextImageKHR"));
    }

    if (realFunc == nullptr) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // STRICT PASS-THROUGH: Call real function unchanged
    return realFunc(device, swapchain, timeout, semaphore, fence, pImageIndex);
}

VKAPI_ATTR VkResult VKAPI_CALL lsfg_vkAcquireNextImage2KHR(
    VkDevice device,
    const VkAcquireNextImageInfoKHR *pAcquireInfo,
    uint32_t *pImageIndex)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_acquireNextImage2Calls.fetch_add(1, std::memory_order_relaxed);
    g_lastDevice.store(reinterpret_cast<uintptr_t>(device), std::memory_order_relaxed);
    if (pAcquireInfo != nullptr) {
        g_lastSwapchain.store(reinterpret_cast<uintptr_t>(pAcquireInfo->swapchain), std::memory_order_relaxed);
    }

    if (!g_firstAcquire2Logged.exchange(true)) {
        LOGI("[LSFG-PROBE] first vkAcquireNextImage2KHR");
    }

    ensure_real_vulkan_loaded();
    PFN_vkAcquireNextImage2KHR realFunc = g_realAcquireNextImage2KHR;
    if (realFunc == nullptr && g_realGdpa != nullptr) {
        realFunc = reinterpret_cast<PFN_vkAcquireNextImage2KHR>(
            g_realGdpa(device, "vkAcquireNextImage2KHR"));
    }

    if (realFunc == nullptr) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    return realFunc(device, pAcquireInfo, pImageIndex);
}

VKAPI_ATTR VkResult VKAPI_CALL lsfg_vkQueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_queuePresentCalls.fetch_add(1, std::memory_order_relaxed);
    g_lastQueue.store(reinterpret_cast<uintptr_t>(queue), std::memory_order_relaxed);

    if (!g_firstPresentLogged.exchange(true)) {
        LOGI("[LSFG-PROBE] first vkQueuePresentKHR");
    }

    ensure_real_vulkan_loaded();
    PFN_vkQueuePresentKHR realFunc = g_realQueuePresentKHR;
    if (realFunc == nullptr && g_realGipa != nullptr) {
        realFunc = reinterpret_cast<PFN_vkQueuePresentKHR>(
            g_realGipa(VK_NULL_HANDLE, "vkQueuePresentKHR"));
    }

    if (realFunc == nullptr) {
        LOGE("[LSFG-PROBE] Could not resolve real vkQueuePresentKHR!");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // STRICT PASS-THROUGH: Forward present info UNCHANGED
    return realFunc(queue, pPresentInfo);
}

} // namespace

namespace lsfg_mc {

void init_passive_vulkan_diagnostics() {
    ensure_real_vulkan_loaded();
    LOGI("[LSFG-PROBE] Passive Vulkan diagnostics layer armed. Interception mechanism: GIPA/GDPA export & VULKAN_PTR discovery.");
}

bool is_vulkan_observed() {
    return g_vulkanObserved.load(std::memory_order_relaxed);
}

ProbeStats get_probe_stats() {
    ProbeStats s;
    s.gipaCalls = g_gipaCalls.load(std::memory_order_relaxed);
    s.gdpaCalls = g_gdpaCalls.load(std::memory_order_relaxed);
    s.createInstanceCalls = g_createInstanceCalls.load(std::memory_order_relaxed);
    s.createDeviceCalls = g_createDeviceCalls.load(std::memory_order_relaxed);
    s.createSwapchainCalls = g_createSwapchainCalls.load(std::memory_order_relaxed);
    s.destroySwapchainCalls = g_destroySwapchainCalls.load(std::memory_order_relaxed);
    s.getSwapchainImagesCalls = g_getSwapchainImagesCalls.load(std::memory_order_relaxed);
    s.acquireNextImageCalls = g_acquireNextImageCalls.load(std::memory_order_relaxed);
    s.acquireNextImage2Calls = g_acquireNextImage2Calls.load(std::memory_order_relaxed);
    s.queuePresentCalls = g_queuePresentCalls.load(std::memory_order_relaxed);
    s.lastInstance = g_lastInstance.load(std::memory_order_relaxed);
    s.lastDevice = g_lastDevice.load(std::memory_order_relaxed);
    s.lastQueue = g_lastQueue.load(std::memory_order_relaxed);
    s.lastSwapchain = g_lastSwapchain.load(std::memory_order_relaxed);
    s.swapchainWidth = g_swapchainWidth.load(std::memory_order_relaxed);
    s.swapchainHeight = g_swapchainHeight.load(std::memory_order_relaxed);
    s.swapchainFormat = g_swapchainFormat.load(std::memory_order_relaxed);
    s.swapchainImageCount = g_swapchainImageCount.load(std::memory_order_relaxed);
    s.vulkanObserved = g_vulkanObserved.load(std::memory_order_relaxed);
    return s;
}

std::string get_probe_snapshot_string() {
    ProbeStats s = get_probe_stats();
    char buf[1024];
    std::snprintf(buf, sizeof(buf),
        "gipa=%u gdpa=%u createSwapchain=%u destroySwapchain=%u getSwapchainImages=%u acquire=%u acquire2=%u present=%u size=%ux%u format=%d images=%u",
        s.gipaCalls, s.gdpaCalls,
        s.createSwapchainCalls, s.destroySwapchainCalls, s.getSwapchainImagesCalls,
        s.acquireNextImageCalls, s.acquireNextImage2Calls, s.queuePresentCalls,
        s.swapchainWidth, s.swapchainHeight, s.swapchainFormat, s.swapchainImageCount);
    return std::string(buf);
}

} // namespace lsfg_mc

// Forward declarations for entry points
extern "C" {
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL lsfg_vkGetInstanceProcAddr(VkInstance instance, const char *pName);
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL lsfg_vkGetDeviceProcAddr(VkDevice device, const char *pName);
}

// -----------------------------------------------------------------------------
// Exported Vulkan Interception Entry Points
// -----------------------------------------------------------------------------

extern "C" {

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL lsfg_vkGetInstanceProcAddr(
    VkInstance instance,
    const char *pName)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_gipaCalls.fetch_add(1, std::memory_order_relaxed);
    if (instance != VK_NULL_HANDLE) {
        g_lastInstance.store(reinterpret_cast<uintptr_t>(instance), std::memory_order_relaxed);
    }

    if (!g_firstGipaLogged.exchange(true)) {
        LOGI("[LSFG-PROBE] first vkGetInstanceProcAddr");
    }

    ensure_real_vulkan_loaded();

    if (pName == nullptr) return nullptr;

    if (std::strcmp(pName, "vkGetInstanceProcAddr") == 0 ||
        std::strcmp(pName, "lsfg_vkGetInstanceProcAddr") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkGetInstanceProcAddr);
    }
    if (std::strcmp(pName, "vkGetDeviceProcAddr") == 0 ||
        std::strcmp(pName, "lsfg_vkGetDeviceProcAddr") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkGetDeviceProcAddr);
    }
    if (std::strcmp(pName, "vkCreateSwapchainKHR") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkCreateSwapchainKHR);
    }
    if (std::strcmp(pName, "vkDestroySwapchainKHR") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkDestroySwapchainKHR);
    }
    if (std::strcmp(pName, "vkGetSwapchainImagesKHR") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkGetSwapchainImagesKHR);
    }
    if (std::strcmp(pName, "vkAcquireNextImageKHR") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkAcquireNextImageKHR);
    }
    if (std::strcmp(pName, "vkAcquireNextImage2KHR") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkAcquireNextImage2KHR);
    }
    if (std::strcmp(pName, "vkQueuePresentKHR") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkQueuePresentKHR);
    }

    if (g_realGipa != nullptr) {
        return g_realGipa(instance, pName);
    }
    return nullptr;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL lsfg_vkGetDeviceProcAddr(
    VkDevice device,
    const char *pName)
{
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_gdpaCalls.fetch_add(1, std::memory_order_relaxed);
    if (device != VK_NULL_HANDLE) {
        g_lastDevice.store(reinterpret_cast<uintptr_t>(device), std::memory_order_relaxed);
    }

    if (!g_firstGdpaLogged.exchange(true)) {
        LOGI("[LSFG-PROBE] first vkGetDeviceProcAddr");
    }

    ensure_real_vulkan_loaded();

    if (pName == nullptr) return nullptr;

    if (std::strcmp(pName, "vkGetDeviceProcAddr") == 0 ||
        std::strcmp(pName, "lsfg_vkGetDeviceProcAddr") == 0) {
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkGetDeviceProcAddr);
    }
    if (std::strcmp(pName, "vkCreateSwapchainKHR") == 0) {
        if (g_realGdpa != nullptr && g_realCreateSwapchainKHR == nullptr) {
            g_realCreateSwapchainKHR = reinterpret_cast<PFN_vkCreateSwapchainKHR>(
                g_realGdpa(device, "vkCreateSwapchainKHR"));
        }
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkCreateSwapchainKHR);
    }
    if (std::strcmp(pName, "vkDestroySwapchainKHR") == 0) {
        if (g_realGdpa != nullptr && g_realDestroySwapchainKHR == nullptr) {
            g_realDestroySwapchainKHR = reinterpret_cast<PFN_vkDestroySwapchainKHR>(
                g_realGdpa(device, "vkDestroySwapchainKHR"));
        }
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkDestroySwapchainKHR);
    }
    if (std::strcmp(pName, "vkGetSwapchainImagesKHR") == 0) {
        if (g_realGdpa != nullptr && g_realGetSwapchainImagesKHR == nullptr) {
            g_realGetSwapchainImagesKHR = reinterpret_cast<PFN_vkGetSwapchainImagesKHR>(
                g_realGdpa(device, "vkGetSwapchainImagesKHR"));
        }
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkGetSwapchainImagesKHR);
    }
    if (std::strcmp(pName, "vkAcquireNextImageKHR") == 0) {
        if (g_realGdpa != nullptr && g_realAcquireNextImageKHR == nullptr) {
            g_realAcquireNextImageKHR = reinterpret_cast<PFN_vkAcquireNextImageKHR>(
                g_realGdpa(device, "vkAcquireNextImageKHR"));
        }
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkAcquireNextImageKHR);
    }
    if (std::strcmp(pName, "vkAcquireNextImage2KHR") == 0) {
        if (g_realGdpa != nullptr && g_realAcquireNextImage2KHR == nullptr) {
            g_realAcquireNextImage2KHR = reinterpret_cast<PFN_vkAcquireNextImage2KHR>(
                g_realGdpa(device, "vkAcquireNextImage2KHR"));
        }
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkAcquireNextImage2KHR);
    }
    if (std::strcmp(pName, "vkQueuePresentKHR") == 0) {
        if (g_realGdpa != nullptr && g_realQueuePresentKHR == nullptr) {
            g_realQueuePresentKHR = reinterpret_cast<PFN_vkQueuePresentKHR>(
                g_realGdpa(device, "vkQueuePresentKHR"));
        }
        return reinterpret_cast<PFN_vkVoidFunction>(lsfg_vkQueuePresentKHR);
    }

    if (g_realGdpa != nullptr) {
        return g_realGdpa(device, pName);
    }
    return nullptr;
}

} // extern "C"
