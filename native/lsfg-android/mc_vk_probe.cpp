#include "mc_vk_probe.hpp"

#include <volk.h>
#include <android/log.h>

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#define LOG_TAG "lsfg-mc-vk-probe"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)

namespace {

constexpr uint32_t kAllResourceIds[] = {
    255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266,
    267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279,
    280, 281, 282, 283, 284, 285, 286, 287, 288, 289,
    290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302,
};

bool read_file(const std::string &path, std::vector<uint8_t> &out) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return false;
    const std::streamsize size = f.tellg();
    if (size <= 0) return false;
    f.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(size));
    f.read(reinterpret_cast<char *>(out.data()), size);
    return f.good();
}

} // namespace

namespace lsfg_mc {

bool device_supports_float16() {
    if (volkInitialize() != VK_SUCCESS) return false;

    VkApplicationInfo appInfo{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "lsfg-mc",
        .apiVersion = VK_API_VERSION_1_1,
    };
    VkInstanceCreateInfo instInfo{
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &appInfo,
    };
    VkInstance inst = VK_NULL_HANDLE;
    if (vkCreateInstance(&instInfo, nullptr, &inst) != VK_SUCCESS) return false;
    volkLoadInstance(inst);

    uint32_t count = 0;
    vkEnumeratePhysicalDevices(inst, &count, nullptr);
    if (count == 0) {
        vkDestroyInstance(inst, nullptr);
        return false;
    }
    std::vector<VkPhysicalDevice> phys(count);
    vkEnumeratePhysicalDevices(inst, &count, phys.data());

    VkPhysicalDeviceShaderFloat16Int8Features f16Features{
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES,
    };
    VkPhysicalDeviceFeatures2 feat2{
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &f16Features,
    };
    vkGetPhysicalDeviceFeatures2(phys[0], &feat2);

    bool supported = (f16Features.shaderFloat16 == VK_TRUE);
    vkDestroyInstance(inst, nullptr);
    return supported;
}

int probe_shaders_on_device(const std::string &cacheDir) {
    if (volkInitialize() != VK_SUCCESS) {
        LOGE("volkInitialize failed");
        return -10;
    }

    VkApplicationInfo appInfo{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "lsfg-mc-probe",
        .apiVersion = VK_API_VERSION_1_1,
    };
    VkInstanceCreateInfo instInfo{
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &appInfo,
    };
    VkInstance inst = VK_NULL_HANDLE;
    if (vkCreateInstance(&instInfo, nullptr, &inst) != VK_SUCCESS) {
        LOGE("vkCreateInstance failed");
        return -10;
    }
    volkLoadInstance(inst);

    uint32_t count = 0;
    vkEnumeratePhysicalDevices(inst, &count, nullptr);
    if (count == 0) {
        vkDestroyInstance(inst, nullptr);
        return -10;
    }
    std::vector<VkPhysicalDevice> phys(count);
    vkEnumeratePhysicalDevices(inst, &count, phys.data());
    VkPhysicalDevice physDev = phys[0];

    uint32_t qCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physDev, &qCount, nullptr);
    std::vector<VkQueueFamilyProperties> qProps(qCount);
    vkGetPhysicalDeviceQueueFamilyProperties(physDev, &qCount, qProps.data());

    uint32_t computeIdx = UINT32_MAX;
    for (uint32_t i = 0; i < qCount; ++i) {
        if (qProps[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
            computeIdx = i;
            break;
        }
    }
    if (computeIdx == UINT32_MAX) {
        vkDestroyInstance(inst, nullptr);
        return -10;
    }

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = computeIdx,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkDeviceCreateInfo devInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qInfo,
    };
    VkDevice dev = VK_NULL_HANDLE;
    if (vkCreateDevice(physDev, &devInfo, nullptr, &dev) != VK_SUCCESS) {
        vkDestroyInstance(inst, nullptr);
        return -10;
    }

    int tested = 0;
    for (uint32_t id : kAllResourceIds) {
        char path[512];
        std::snprintf(path, sizeof(path), "%s/%u.spv", cacheDir.c_str(), id);
        std::vector<uint8_t> spirv;
        if (!read_file(path, spirv) || spirv.size() < 20 || (spirv.size() % 4) != 0) {
            LOGE("Cannot read SPIR-V blob %s", path);
            vkDestroyDevice(dev, nullptr);
            vkDestroyInstance(inst, nullptr);
            return -11;
        }

        VkShaderModuleCreateInfo smInfo{
            .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = spirv.size(),
            .pCode = reinterpret_cast<const uint32_t *>(spirv.data()),
        };
        VkShaderModule sm = VK_NULL_HANDLE;
        VkResult res = vkCreateShaderModule(dev, &smInfo, nullptr, &sm);
        if (res != VK_SUCCESS) {
            LOGE("Driver rejected shader %u (VkResult=%d)", id, res);
            vkDestroyDevice(dev, nullptr);
            vkDestroyInstance(inst, nullptr);
            return -12;
        }
        vkDestroyShaderModule(dev, sm, nullptr);
        ++tested;
    }

    LOGI("Vulkan probe passed: all %d shader modules successfully accepted by GPU driver.", tested);
    vkDestroyDevice(dev, nullptr);
    vkDestroyInstance(inst, nullptr);
    return 0;
}

} // namespace lsfg_mc
