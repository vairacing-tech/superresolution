#include "mc_vk_passive_hook.hpp"

#include <dlfcn.h>
#include <android/log.h>
#include <atomic>
#include <cinttypes>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

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

    // V2A.1 append-only queue-family capability fields
    VkQueueFlags queueFamilyFlags;
    uint32_t queueFamilyQueueCount;
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
typedef int32_t (*PFN_lsfg_interposer_bridge_get_swapchain_images_v2)(
    uint64_t expectedGeneration,
    VkSwapchainKHR swapchain,
    uint32_t *pCount,
    VkImage *pImages
);
typedef int32_t (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(
    uint64_t expectedGeneration,
    VkSwapchainKHR swapchain,
    uint32_t *pCount,
    VkPresentModeKHR *pModes
);

std::atomic<uint64_t> g_bridgeCallbackCount{0};
std::atomic<uint64_t> g_bridgeLastSerial{0};
std::atomic<bool> g_firstBridgeCallbackLogged{false};
std::atomic<PFN_lsfg_interposer_bridge_get_snapshot_v2> g_getSnapshotV2Fn{nullptr};
std::atomic<PFN_lsfg_interposer_bridge_get_swapchain_images_v2> g_getSwapchainImagesV2Fn{nullptr};
std::atomic<PFN_lsfg_interposer_bridge_get_present_modes_v2> g_getPresentModesV2Fn{nullptr};
std::atomic<bool> g_v2a1Logged{false};
std::atomic<bool> g_v2a1WorkerStarted{false};
std::atomic<bool> g_v2a1Ready{false};
std::mutex g_v2a1ReadyMutex;
std::condition_variable g_v2a1ReadyCv;
std::atomic<bool> g_v1ProbeEnabled{false};
std::atomic<bool> g_v2ProbeEnabled{false};

template <typename T>
static uint64_t bridge_handle_to_u64(T handle) {
    if constexpr (std::is_pointer_v<T>) {
        return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
    } else {
        return static_cast<uint64_t>(handle);
    }
}

static const char *present_mode_name(VkPresentModeKHR mode) {
    switch (mode) {
        case VK_PRESENT_MODE_IMMEDIATE_KHR: return "VK_PRESENT_MODE_IMMEDIATE_KHR";
        case VK_PRESENT_MODE_MAILBOX_KHR: return "VK_PRESENT_MODE_MAILBOX_KHR";
        case VK_PRESENT_MODE_FIFO_KHR: return "VK_PRESENT_MODE_FIFO_KHR";
        case VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "VK_PRESENT_MODE_FIFO_RELAXED_KHR";
        default: return nullptr;
    }
}

static void log_v2a1_diagnostic(
    const LsfgBridgeSnapshotV2 &snap,
    const std::vector<VkImage> &images,
    const std::vector<VkPresentModeKHR> &presentModes,
    int32_t imageCountStatus,
    int32_t imageCopyOutStatus,
    int32_t presentModeCountStatus,
    int32_t presentModeCopyOutStatus,
    uint32_t attempt,
    uint32_t staleRetries) {
    if (g_v2a1Logged.exchange(true)) return;

    const uint32_t queueFamilyFlags = static_cast<uint32_t>(snap.queueFamilyFlags);
    const uint32_t knownQueueFlags =
        VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT | VK_QUEUE_SPARSE_BINDING_BIT;
    const uint32_t additionalQueueFlags = queueFamilyFlags & ~knownQueueFlags;
    const uint32_t imageCount = static_cast<uint32_t>(images.size());
    const uint32_t presentModeCount = static_cast<uint32_t>(presentModes.size());

    LOGI("[LSFG-V2A1] generation=%" PRIu64
         " currentExtent=%ux%u minImageExtent=%ux%u maxImageExtent=%ux%u"
         " maxImageArrayLayers=%u supportedTransforms=0x%x currentTransform=0x%x"
         " supportedCompositeAlpha=0x%x supportedUsageFlags=0x%x"
         " queueFamilyFlags=0x%x graphics=%u compute=%u transfer=%u sparse=%u"
         " additionalQueueFlags=0x%x queueFamilyQueueCount=%u"
         " supportedPresentModeCount=%u supportedPresentModes=%u"
         " swapchainImageCount=%u swapchainImageCopyOutStatus=%d"
         " presentModeCountStatus=%d presentModeCopyOutStatus=%d"
         " attempt=%u retryCount=%u staleRetries=%u",
         snap.generation,
         snap.imageExtent.width, snap.imageExtent.height,
         snap.surfaceCapabilities.minImageExtent.width, snap.surfaceCapabilities.minImageExtent.height,
         snap.surfaceCapabilities.maxImageExtent.width, snap.surfaceCapabilities.maxImageExtent.height,
         snap.surfaceCapabilities.maxImageArrayLayers,
         static_cast<uint32_t>(snap.surfaceCapabilities.supportedTransforms),
         static_cast<uint32_t>(snap.surfaceCapabilities.currentTransform),
         static_cast<uint32_t>(snap.surfaceCapabilities.supportedCompositeAlpha),
         static_cast<uint32_t>(snap.surfaceCapabilities.supportedUsageFlags),
         queueFamilyFlags,
         (queueFamilyFlags & VK_QUEUE_GRAPHICS_BIT) != 0,
         (queueFamilyFlags & VK_QUEUE_COMPUTE_BIT) != 0,
         (queueFamilyFlags & VK_QUEUE_TRANSFER_BIT) != 0,
         (queueFamilyFlags & VK_QUEUE_SPARSE_BINDING_BIT) != 0,
         additionalQueueFlags,
         snap.queueFamilyQueueCount,
         snap.supportedPresentModeCount,
         presentModeCount,
         imageCount,
         imageCopyOutStatus,
         presentModeCountStatus,
         presentModeCopyOutStatus,
         attempt,
         attempt > 0 ? attempt - 1 : 0,
         staleRetries);

    LOGI("[LSFG-V2A1] handles instance=%p physicalDevice=%p device=%p queue=%p swapchain=%" PRIu64 " surface=%" PRIu64
         " imageCountStatus=%d",
         snap.instance, snap.physicalDevice, snap.device, snap.presentQueue,
         bridge_handle_to_u64(snap.swapchain), bridge_handle_to_u64(snap.surface), imageCountStatus);

    for (const VkPresentModeKHR mode : presentModes) {
        const char *name = present_mode_name(mode);
        if (name != nullptr) {
            LOGI("[LSFG-V2A1] supportedPresentModes=%s numeric=%u", name, static_cast<uint32_t>(mode));
        } else {
            LOGI("[LSFG-V2A1] supportedPresentModes=UNKNOWN numeric=%u", static_cast<uint32_t>(mode));
        }
    }
}

static void v2a1_metadata_worker() {
    std::unique_lock<std::mutex> readyLock(g_v2a1ReadyMutex);
    g_v2a1ReadyCv.wait(readyLock, [] {
        return g_v2a1Ready.load(std::memory_order_acquire);
    });
    readyLock.unlock();

    PFN_lsfg_interposer_bridge_get_snapshot_v2 snapshotFn =
        g_getSnapshotV2Fn.load(std::memory_order_acquire);
    PFN_lsfg_interposer_bridge_get_swapchain_images_v2 imageFn =
        g_getSwapchainImagesV2Fn.load(std::memory_order_acquire);
    PFN_lsfg_interposer_bridge_get_present_modes_v2 presentModeFn =
        g_getPresentModesV2Fn.load(std::memory_order_acquire);
    if (snapshotFn == nullptr || imageFn == nullptr || presentModeFn == nullptr) {
        return;
    }

    uint32_t staleRetries = 0;
    for (uint32_t attempt = 0; attempt < 3; ++attempt) {
        LsfgBridgeSnapshotV2 snap{};
        snap.abiVersion = LSFG_BRIDGE_ABI_VERSION_V2;
        snap.structSize = sizeof(LsfgBridgeSnapshotV2);
        int32_t snapshotStatus = snapshotFn(&snap);
        if (snapshotStatus != 0 || (snap.validMask & 0x04) == 0 ||
            (snap.validMask & 0x10) == 0 || (snap.validMask & 0x40) == 0) {
            continue;
        }
        if ((snap.validMask & 0x40) != 0) {
            const VkQueueFlags observedQueueFlags = snap.queueFamilyFlags;
            const uint32_t observedQueueCount = snap.queueFamilyQueueCount;
            if (observedQueueFlags == 0 && observedQueueCount == 0) {
                continue;
            }
        }

        const uint64_t generation = snap.generation;
        uint32_t imageCount = 0;
        int32_t imageCountStatus = imageFn(generation, snap.swapchain, &imageCount, nullptr);
        if (imageCountStatus == -4) {
            ++staleRetries;
            continue;
        }
        if (imageCountStatus != 0 || imageCount == 0 || snap.actualImageCount != imageCount) {
            continue;
        }

        std::vector<VkImage> images(imageCount);
        uint32_t imageCopyOutCount = imageCount;
        int32_t imageCopyOutStatus = imageFn(
            generation, snap.swapchain, &imageCopyOutCount, images.data());
        if (imageCopyOutStatus == -4) {
            ++staleRetries;
            continue;
        }
        if (imageCopyOutStatus != 0 || imageCopyOutCount != imageCount) {
            continue;
        }
        bool allImagesNonNull = true;
        for (const VkImage image : images) {
            if (image == VK_NULL_HANDLE) {
                allImagesNonNull = false;
                break;
            }
        }
        if (!allImagesNonNull) {
            continue;
        }

        uint32_t presentModeCount = 0;
        int32_t presentModeCountStatus = presentModeFn(
            generation, snap.swapchain, &presentModeCount, nullptr);
        if (presentModeCountStatus == -4) {
            ++staleRetries;
            continue;
        }
        if (presentModeCountStatus != 0) {
            continue;
        }

        std::vector<VkPresentModeKHR> presentModes(presentModeCount);
        uint32_t presentModeCopyOutCount = presentModeCount;
        VkPresentModeKHR emptyMode = VK_PRESENT_MODE_FIFO_KHR;
        VkPresentModeKHR *presentModeOutput = presentModes.empty() ? &emptyMode : presentModes.data();
        int32_t presentModeCopyOutStatus = presentModeFn(
            generation, snap.swapchain, &presentModeCopyOutCount, presentModeOutput);
        if (presentModeCopyOutStatus == -4) {
            ++staleRetries;
            continue;
        }
        if (presentModeCopyOutStatus != 0 || presentModeCopyOutCount != presentModeCount) {
            continue;
        }

        LsfgBridgeSnapshotV2 verify{};
        verify.abiVersion = LSFG_BRIDGE_ABI_VERSION_V2;
        verify.structSize = sizeof(LsfgBridgeSnapshotV2);
        int32_t verifyStatus = snapshotFn(&verify);
        if (verifyStatus == -4 || (verifyStatus == 0 && verify.generation != generation)) {
            ++staleRetries;
            continue;
        }
        if (verifyStatus != 0) {
            continue;
        }

        log_v2a1_diagnostic(
            snap, images, presentModes,
            imageCountStatus, imageCopyOutStatus,
            presentModeCountStatus, presentModeCopyOutStatus,
            attempt + 1, staleRetries);
        return;
    }
}

static uint32_t lsfg_present_observer_callback_v1(
    uint64_t serial,
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo,
    void *user_data
) {
    (void)queue;
    (void)pPresentInfo;
    (void)user_data;
    g_vulkanObserved.store(true, std::memory_order_relaxed);
    g_bridgeCallbackCount.fetch_add(1, std::memory_order_relaxed);
    g_bridgeLastSerial.store(serial, std::memory_order_relaxed);
    g_v2a1Ready.store(true, std::memory_order_release);
    g_v2a1ReadyCv.notify_one();
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
                        PFN_lsfg_interposer_bridge_get_snapshot_v2 snap_fn =
                            reinterpret_cast<PFN_lsfg_interposer_bridge_get_snapshot_v2>(
                                dlsym(interposer_handle, "lsfg_interposer_bridge_get_snapshot_v2"));
                        PFN_lsfg_interposer_bridge_get_swapchain_images_v2 image_fn =
                            reinterpret_cast<PFN_lsfg_interposer_bridge_get_swapchain_images_v2>(
                                dlsym(interposer_handle, "lsfg_interposer_bridge_get_swapchain_images_v2"));
                        PFN_lsfg_interposer_bridge_get_present_modes_v2 present_mode_fn =
                            reinterpret_cast<PFN_lsfg_interposer_bridge_get_present_modes_v2>(
                                dlsym(interposer_handle, "lsfg_interposer_bridge_get_present_modes_v2"));

                        if (snap_fn != nullptr) {
                            g_getSnapshotV2Fn.store(snap_fn, std::memory_order_release);
                            LOGI("[LSFG-BRIDGE] interposer bridge v2 snapshot export discovered");
                            printf("[LSFG-BRIDGE] interposer bridge v2 snapshot export discovered\n");
                            fflush(stdout);
                        }
                        if (image_fn != nullptr) {
                            g_getSwapchainImagesV2Fn.store(image_fn, std::memory_order_release);
                            LOGI("[LSFG-BRIDGE] interposer bridge v2 image copy-out export discovered");
                        }
                        if (present_mode_fn != nullptr) {
                            g_getPresentModesV2Fn.store(present_mode_fn, std::memory_order_release);
                            LOGI("[LSFG-BRIDGE] interposer bridge v2 present-mode copy-out export discovered");
                        }
                        if (snap_fn != nullptr && image_fn != nullptr && present_mode_fn != nullptr &&
                            !g_v2a1WorkerStarted.exchange(true)) {
                            std::thread(v2a1_metadata_worker).detach();
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
