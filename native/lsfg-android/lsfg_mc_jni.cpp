#include <jni.h>
#include <string>
#include <vector>
#include <android/log.h>

#include "mc_shader_extractor.hpp"
#include "mc_vk_probe.hpp"
#include "mc_vk_passive_hook.hpp"

#define LOG_TAG "lsfg-mc-jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

constexpr const char *kVersion = "lsfg-minecraft 0.1.0-arm64";

std::string jstring_to_std(JNIEnv *env, jstring s) {
    if (s == nullptr) return {};
    const char *chars = env->GetStringUTFChars(s, nullptr);
    std::string out = chars ? chars : "";
    if (chars) env->ReleaseStringUTFChars(s, chars);
    return out;
}

} // namespace

extern "C" {

JNIEXPORT jstring JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_getNativeVersion(JNIEnv *env, jclass /*clazz*/) {
    return env->NewStringUTF(kVersion);
}

JNIEXPORT jint JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_initNativeBackend(JNIEnv * /*env*/, jclass /*clazz*/) {
    LOGI("LSFG Minecraft Native Backend initialized (build: %s)", kVersion);
    lsfg_mc::init_passive_vulkan_diagnostics();
    return 0;
}

JNIEXPORT jboolean JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_isPlatformSupported(JNIEnv * /*env*/, jclass /*clazz*/) {
#if defined(__aarch64__) || defined(__arm64__)
    return JNI_TRUE;
#else
    return JNI_FALSE;
#endif
}

JNIEXPORT jboolean JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_isVulkanObserved(JNIEnv * /*env*/, jclass /*clazz*/) {
    return lsfg_mc::is_vulkan_observed() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_getProbeSnapshot(JNIEnv *env, jclass /*clazz*/) {
    std::string snap = lsfg_mc::get_probe_snapshot_string();
    return env->NewStringUTF(snap.c_str());
}

JNIEXPORT jint JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_validateAndExtractShaders(
        JNIEnv *env, jclass /*clazz*/,
        jstring dllPath, jstring /*dllSha256*/, jstring cacheDir) {
    const std::string path = jstring_to_std(env, dllPath);
    const std::string cache = jstring_to_std(env, cacheDir);
    if (path.empty() || cache.empty()) {
        return -1;
    }
    LOGI("Extracting LSFG shaders from %s into %s", path.c_str(), cache.c_str());
    return lsfg_mc::extract_dll_to_spirv(path, cache);
}

JNIEXPORT jint JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_probeShaderCache(
        JNIEnv *env, jclass /*clazz*/, jstring cacheDir) {
    const std::string cache = jstring_to_std(env, cacheDir);
    if (cache.empty()) return -1;
    return lsfg_mc::probe_shaders_on_device(cache);
}

JNIEXPORT jint JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_getCapabilities(JNIEnv * /*env*/, jclass /*clazz*/) {
    // Bitmask: bit 0 = Vulkan available, bit 1 = Float16 supported, bit 2 = LSFG 3.1P available
    int caps = 0x01; // Vulkan base
    if (lsfg_mc::device_supports_float16()) {
        caps |= 0x02;
    }
    caps |= 0x04; // 3.1P
    return caps;
}

JNIEXPORT void JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_shutdown(JNIEnv * /*env*/, jclass /*clazz*/) {
    LOGI("LSFG Minecraft Native Backend shutting down.");
}

} // extern "C"
