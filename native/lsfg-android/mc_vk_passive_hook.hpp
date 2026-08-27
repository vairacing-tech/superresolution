#pragma once

#include <vulkan/vulkan.h>
#include <cstdint>
#include <string>

namespace lsfg_mc {

struct ProbeStats {
    uint32_t gipaCalls;
    uint32_t gdpaCalls;
    uint32_t createInstanceCalls;
    uint32_t createDeviceCalls;
    uint32_t createSwapchainCalls;
    uint32_t destroySwapchainCalls;
    uint32_t getSwapchainImagesCalls;
    uint32_t acquireNextImageCalls;
    uint32_t acquireNextImage2Calls;
    uint32_t queuePresentCalls;
    uintptr_t lastInstance;
    uintptr_t lastDevice;
    uintptr_t lastQueue;
    uintptr_t lastSwapchain;
    uint32_t swapchainWidth;
    uint32_t swapchainHeight;
    int32_t swapchainFormat;
    uint32_t swapchainImageCount;
    bool vulkanObserved;
};

/// Initializes the passive Vulkan diagnostic observation layer.
void init_passive_vulkan_diagnostics(bool enable_v1_probe = true, bool enable_v2_probe = true);

/// Returns whether any Vulkan activity (GIPA/GDPA/Swapchain/Present) has been observed by our hook.
bool is_vulkan_observed();

/// Retrieves current atomic snapshot of all Vulkan probe counters.
ProbeStats get_probe_stats();

/// Retrieves serialized string snapshot of all Vulkan probe counters.
std::string get_probe_snapshot_string();

} // namespace lsfg_mc
