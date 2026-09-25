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

struct LsfgRuntimeStatus {
    uint32_t structSize;
    uint32_t abiVersion;      // 3
    int32_t  state;           // 0=OFF, 1=ARMING, 2=ACTIVE, 3=FALLBACK, 4=ERROR
    int32_t  factor;          // 2 or 3
    uint64_t nativePresented;
    uint64_t generatedPresented;
    uint64_t generationAttempts;
    uint64_t generationSuccess;
    uint64_t generationFallback;
    float    nativeFps;
    float    outputFps;
    float    lastLsfgComputeMs;
    uint32_t reserved[4];
};

struct LsfgRuntimeConfig {
    uint32_t structSize;
    uint32_t abiVersion;      // 3
    int32_t  enabled;         // -1=no change, 0=OFF, 1=ON
    int32_t  factor;          // -1=no change, 2=x2, 3=x3
    int32_t  maxEvents;       // -1=no change, <=0=continuous
    int32_t  armDelayMs;      // -1=no change, 0=immediate
    uint32_t reserved[4];
};

/// Retrieves current runtime status from interposer bridge.
int32_t get_runtime_status(LsfgRuntimeStatus *outStatus);

/// Sends runtime configuration to interposer bridge.
int32_t set_runtime_config(const LsfgRuntimeConfig *inConfig);

/// Requests fresh history at the next presentation boundary without changing FG settings.
int32_t notify_content_discontinuity();

} // namespace lsfg_mc
