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

// Bridge definitions and atomics
#define LSFG_BRIDGE_ACK_V1 0x4C534647 // 'LSFG'

#define LSFG_BRIDGE_ABI_VERSION_V2 2
#define LSFG_BRIDGE_MAX_SWAPCHAIN_IMAGES 16
#define LSFG_BRIDGE_MAX_PRESENT_MODES 16

typedef uint32_t (*PFN_lsfg_present_observer_v1)(
    uint64_t serial,
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo,
    void *user_data
);

struct LsfgBridgeSnapshotV2 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint64_t generation;

    VkInstance instance;
    VkPhysicalDevice physicalDevice;
    VkDevice device;

    VkQueue presentQueue;
    uint32_t queueFamilyIndex;
    uint32_t queueIndex;
    VkDeviceQueueCreateFlags queueFlags;

    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;

    VkFormat imageFormat;
    VkColorSpaceKHR imageColorSpace;
    VkExtent2D imageExtent;
    uint32_t imageArrayLayers;
    VkImageUsageFlags imageUsage;
    VkSharingMode imageSharingMode;
    VkSurfaceTransformFlagBitsKHR preTransform;
    VkCompositeAlphaFlagBitsKHR compositeAlpha;
    VkPresentModeKHR presentMode;
    VkBool32 clipped;
    VkSwapchainKHR oldSwapchain;

    uint32_t requestedMinImageCount;
    uint32_t actualImageCount;
    uint32_t imageCapacity;
    VkImage images[LSFG_BRIDGE_MAX_SWAPCHAIN_IMAGES];

    VkSurfaceCapabilitiesKHR surfaceCapabilities;

    uint32_t supportedPresentModeCount;
    uint32_t presentModeCapacity;
    VkPresentModeKHR supportedPresentModes[LSFG_BRIDGE_MAX_PRESENT_MODES];

    uint32_t validMask;
};

#define LSFG_BRIDGE_SNAPSHOT_V2_MIN_SIZE (static_cast<uint32_t>(offsetof(LsfgBridgeSnapshotV2, requestedMinImageCount)))

typedef uint32_t (*PFN_lsfg_interposer_bridge_get_version)(void);
typedef int32_t (*PFN_lsfg_interposer_register_present_observer_v1)(
    PFN_lsfg_present_observer_v1 callback,
    void *user_data
);
typedef int32_t (*PFN_lsfg_interposer_unregister_present_observer_v1)(
    PFN_lsfg_present_observer_v1 callback
);
typedef int32_t (*PFN_lsfg_interposer_bridge_get_snapshot_v2)(
    LsfgBridgeSnapshotV2 *outSnapshot
);

std::atomic<uint64_t> g_bridgeCallbackCount{0};
std::atomic<uint64_t> g_bridgeLastSerial{0};
std::atomic<bool> g_firstBridgeCallbackLogged{false};
std::atomic<PFN_lsfg_interposer_bridge_get_snapshot_v2> g_getSnapshotV2Fn{nullptr};
std::atomic<bool> g_v2aLogged{false};
std::atomic<bool> g_v1ProbeEnabled{false};
std::atomic<bool> g_v2ProbeEnabled{false};

static void log_v2a_snapshot(const LsfgBridgeSnapshotV2 &snap) {
    if (g_v2aLogged.exchange(true)) return;

    LOGI("[LSFG-V2A] device=%p physDev=%p instance=%p", snap.device, snap.physicalDevice, snap.instance);
    LOGI("[LSFG-V2A] queueFamily=%u queueIndex=%u queue=%p", snap.queueFamilyIndex, snap.queueIndex, snap.presentQueue);
    LOGI("[LSFG-V2A] swapchain=%" PRIu64 " surface=%" PRIu64, (uint64_t)snap.swapchain, (uint64_t)snap.surface);
    LOGI("[LSFG-V2A] extent=%ux%u format=%d colorSpace=%d", snap.imageExtent.width, snap.imageExtent.height, (int)snap.imageFormat, (int)snap.imageColorSpace);
    LOGI("[LSFG-V2A] requestedImages=%u actualImages=%u", snap.requestedMinImageCount, snap.actualImageCount);
    LOGI("[LSFG-V2A] usage=0x%x sharingMode=%d", (uint32_t)snap.imageUsage, (int)snap.imageSharingMode);
    LOGI("[LSFG-V2A] presentMode=%d", (int)snap.presentMode);
    LOGI("[LSFG-V2A] surface minImages=%u maxImages=%u", snap.surfaceCapabilities.minImageCount, snap.surfaceCapabilities.maxImageCount);
    LOGI("[LSFG-V2A] supportedUsage=0x%x", (uint32_t)snap.surfaceCapabilities.supportedUsageFlags);
    LOGI("[LSFG-V2A] generation=%" PRIu64, snap.generation);

    printf("[LSFG-V2A] device=%p physDev=%p instance=%p\n", snap.device, snap.physicalDevice, snap.instance);
    printf("[LSFG-V2A] queueFamily=%u queueIndex=%u queue=%p\n", snap.queueFamilyIndex, snap.queueIndex, snap.presentQueue);
    printf("[LSFG-V2A] swapchain=%" PRIu64 " surface=%" PRIu64 "\n", (uint64_t)snap.swapchain, (uint64_t)snap.surface);
    printf("[LSFG-V2A] extent=%ux%u format=%d colorSpace=%d\n", snap.imageExtent.width, snap.imageExtent.height, (int)snap.imageFormat, (int)snap.imageColorSpace);
    printf("[LSFG-V2A] requestedImages=%u actualImages=%u\n", snap.requestedMinImageCount, snap.actualImageCount);
    printf("[LSFG-V2A] usage=0x%x sharingMode=%d\n", (uint32_t)snap.imageUsage, (int)snap.imageSharingMode);
    printf("[LSFG-V2A] presentMode=%d\n", (int)snap.presentMode);
    printf("[LSFG-V2A] surface minImages=%u maxImages=%u\n", snap.surfaceCapabilities.minImageCount, snap.surfaceCapabilities.maxImageCount);
    printf("[LSFG-V2A] supportedUsage=0x%x\n", (uint32_t)snap.surfaceCapabilities.supportedUsageFlags);
    printf("[LSFG-V2A] generation=%" PRIu64 "\n", snap.generation);
    fflush(stdout);
}

static void try_query_v2a_snapshot() {
    if (!g_v2ProbeEnabled.load(std::memory_order_relaxed)) return;

    auto fn = g_getSnapshotV2Fn.load(std::memory_order_relaxed);
    if (fn != nullptr && !g_v2aLogged.load(std::memory_order_relaxed)) {
        LsfgBridgeSnapshotV2 snap{};
        snap.abiVersion = LSFG_BRIDGE_ABI_VERSION_V2;
        snap.structSize = sizeof(LsfgBridgeSnapshotV2);
        int32_t res = fn(&snap);
        if (res == 0 && (snap.validMask & 0x04) != 0) { // swapchain valid
            log_v2a_snapshot(snap);
        }
    }
}

static uint32_t lsfg_present_observer_callback_v1(
    uint64_t serial,
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo,
    void *user_data
) {
    (void)user_data;
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_bridgeCallbackCount.fetch_add(1, std::memory_order_relaxed);
    g_bridgeLastSerial.store(serial, std::memory_order_relaxed);

    if (g_v2ProbeEnabled.load(std::memory_order_relaxed)) {
        try_query_v2a_snapshot();
    }

    if (g_v1ProbeEnabled.load(std::memory_order_relaxed) && !g_firstBridgeCallbackLogged.exchange(true)) {
        uint32_t scCount = (pPresentInfo != nullptr) ? pPresentInfo->swapchainCount : 0;
        LOGI("[LSFG-BRIDGE] first present callback serial=%" PRIu64 " swapchains=%u",
             serial, scCount);
        printf("[LSFG-BRIDGE] first present callback serial=%" PRIu64 " swapchains=%u\n",
             serial, scCount);
        fflush(stdout);
    }

    return LSFG_BRIDGE_ACK_V1;
}

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

void init_passive_vulkan_diagnostics(bool enable_v1_probe, bool enable_v2_probe) {
    g_v1ProbeEnabled.store(enable_v1_probe, std::memory_order_relaxed);
    g_v2ProbeEnabled.store(enable_v2_probe, std::memory_order_relaxed);

    ensure_real_vulkan_loaded();

    // Discover and register with Amethyst Vulkan Interposer Bridge V1 / V2
    const char *vulkanPtrEnv = std::getenv("VULKAN_PTR");
    if (vulkanPtrEnv != nullptr && *vulkanPtrEnv != '\0') {
        char *end = nullptr;
        unsigned long ptrVal = std::strtoul(vulkanPtrEnv, &end, 16);
        if (ptrVal != 0) {
            void *interposer_handle = reinterpret_cast<void *>(ptrVal);
            PFN_lsfg_interposer_bridge_get_version get_ver =
                reinterpret_cast<PFN_lsfg_interposer_bridge_get_version>(
                    dlsym(interposer_handle, "lsfg_interposer_bridge_get_version"));
            if (get_ver != nullptr) {
                uint32_t ver = get_ver();
                if (ver == 1) {
                    if (enable_v1_probe) {
                        LOGI("[LSFG-BRIDGE] interposer bridge v1 discovered");
                        printf("[LSFG-BRIDGE] interposer bridge v1 discovered\n");
                        fflush(stdout);
                    }

                    if (enable_v1_probe || enable_v2_probe) {
                        PFN_lsfg_interposer_register_present_observer_v1 reg_fn =
                            reinterpret_cast<PFN_lsfg_interposer_register_present_observer_v1>(
                                dlsym(interposer_handle, "lsfg_interposer_register_present_observer_v1"));
                        if (reg_fn != nullptr) {
                            int32_t reg_res = reg_fn(lsfg_present_observer_callback_v1, nullptr);
                            if (reg_res == 0) {
                                if (enable_v1_probe) {
                                    LOGI("[LSFG-BRIDGE] passive present observer registered");
                                    printf("[LSFG-BRIDGE] passive present observer registered\n");
                                    fflush(stdout);
                                }
                            } else {
                                LOGW("[LSFG-BRIDGE] observer registration returned %d", reg_res);
                            }
                        } else {
                            LOGE("[LSFG-BRIDGE] Failed to dlsym lsfg_interposer_register_present_observer_v1");
                        }
                    }

                    if (enable_v2_probe) {
                        // Discover V2 snapshot export
                        PFN_lsfg_interposer_bridge_get_snapshot_v2 snap_fn =
                            reinterpret_cast<PFN_lsfg_interposer_bridge_get_snapshot_v2>(
                                dlsym(interposer_handle, "lsfg_interposer_bridge_get_snapshot_v2"));
                        if (snap_fn != nullptr) {
                            g_getSnapshotV2Fn.store(snap_fn, std::memory_order_release);
                            LOGI("[LSFG-BRIDGE] interposer bridge v2 snapshot export discovered");
                            printf("[LSFG-BRIDGE] interposer bridge v2 snapshot export discovered\n");
                            fflush(stdout);
                            try_query_v2a_snapshot();
                        }
                    }
                } else {
                    LOGW("[LSFG-BRIDGE] Incompatible bridge version %u (expected 1)", ver);
                }
            } else {
                LOGI("[LSFG-BRIDGE] Interposer handle %p does not export bridge API", interposer_handle);
            }
        }
    }

    LOGI("[LSFG-PROBE] Passive Vulkan diagnostics layer armed. Interception mechanism: GIPA/GDPA export & VULKAN_PTR discovery.");
}

bool is_vulkan_observed() {
    return g_vulkanObserved.load(std::memory_order_relaxed) || (g_bridgeCallbackCount.load(std::memory_order_relaxed) > 0);
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
