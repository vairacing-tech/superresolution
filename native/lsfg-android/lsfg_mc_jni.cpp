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

static bool is_system_property_true(JNIEnv *env, const char *propName) {
    if (env == nullptr || propName == nullptr) return false;
    jclass sysClass = env->FindClass("java/lang/System");
    if (!sysClass) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return false;
    }
    jmethodID getProp = env->GetStaticMethodID(sysClass, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!getProp) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return false;
    }
    jstring jName = env->NewStringUTF(propName);
    jstring jVal = (jstring)env->CallStaticObjectMethod(sysClass, getProp, jName);
    env->DeleteLocalRef(jName);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return false;
    }
    if (!jVal) return false;
    const char *str = env->GetStringUTFChars(jVal, nullptr);
    bool result = false;
    if (str != nullptr) {
        if (strcasecmp(str, "true") == 0 || strcmp(str, "1") == 0) {
            result = true;
        }
        env->ReleaseStringUTFChars(jVal, str);
    }
    env->DeleteLocalRef(jVal);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_initNativeBackend(JNIEnv *env, jclass /*clazz*/) {
    LOGI("LSFG Minecraft Native Backend initialized (build: %s)", kVersion);
    bool v1_probe = is_system_property_true(env, "superresolution.lsfg_bridge_probe");
    bool v2_probe = is_system_property_true(env, "superresolution.lsfg_bridge_v2_probe");
    lsfg_mc::init_passive_vulkan_diagnostics(v1_probe, v2_probe);
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

JNIEXPORT jboolean JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_getRuntimeStatus(
        JNIEnv *env, jclass /*clazz*/, jobject statusObj) {
    if (statusObj == nullptr) return JNI_FALSE;

    lsfg_mc::LsfgRuntimeStatus s{};
    s.structSize = sizeof(lsfg_mc::LsfgRuntimeStatus);
    s.abiVersion = 3;

    int32_t res = lsfg_mc::get_runtime_status(&s);
    if (res != 0) {
        return JNI_FALSE;
    }

    jclass cls = env->GetObjectClass(statusObj);
    if (cls == nullptr) return JNI_FALSE;

    jfieldID fState = env->GetFieldID(cls, "state", "I");
    jfieldID fFactor = env->GetFieldID(cls, "factor", "I");
    jfieldID fNativePres = env->GetFieldID(cls, "nativePresented", "J");
    jfieldID fGenPres = env->GetFieldID(cls, "generatedPresented", "J");
    jfieldID fGenAttempts = env->GetFieldID(cls, "generationAttempts", "J");
    jfieldID fGenSuccess = env->GetFieldID(cls, "generationSuccess", "J");
    jfieldID fGenFallback = env->GetFieldID(cls, "generationFallback", "J");
    jfieldID fNativeFps = env->GetFieldID(cls, "nativeFps", "F");
    jfieldID fOutputFps = env->GetFieldID(cls, "outputFps", "F");
    jfieldID fComputeMs = env->GetFieldID(cls, "lastLsfgComputeMs", "F");

    if (fState) env->SetIntField(statusObj, fState, s.state);
    if (fFactor) env->SetIntField(statusObj, fFactor, s.factor);
    jfieldID fReqFactor = env->GetFieldID(cls, "requestedFactor", "I");
    if (fReqFactor) env->SetIntField(statusObj, fReqFactor, static_cast<jint>(s.reserved[0]));
    if (fNativePres) env->SetLongField(statusObj, fNativePres, static_cast<jlong>(s.nativePresented));
    if (fGenPres) env->SetLongField(statusObj, fGenPres, static_cast<jlong>(s.generatedPresented));
    if (fGenAttempts) env->SetLongField(statusObj, fGenAttempts, static_cast<jlong>(s.generationAttempts));
    if (fGenSuccess) env->SetLongField(statusObj, fGenSuccess, static_cast<jlong>(s.generationSuccess));
    if (fGenFallback) env->SetLongField(statusObj, fGenFallback, static_cast<jlong>(s.generationFallback));
    if (fNativeFps) env->SetFloatField(statusObj, fNativeFps, s.nativeFps);
    if (fOutputFps) env->SetFloatField(statusObj, fOutputFps, s.outputFps);
    if (fComputeMs) env->SetFloatField(statusObj, fComputeMs, s.lastLsfgComputeMs);

    return JNI_TRUE;
}

JNIEXPORT jint JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_setRuntimeConfig(
        JNIEnv * /*env*/, jclass /*clazz*/, jint enabled, jint factor, jint maxEvents, jint armDelayMs) {
    lsfg_mc::LsfgRuntimeConfig cfg{};
    cfg.structSize = sizeof(lsfg_mc::LsfgRuntimeConfig);
    cfg.abiVersion = 3;
    cfg.enabled = enabled;
    cfg.factor = factor;
    cfg.maxEvents = maxEvents;
    cfg.armDelayMs = armDelayMs;

    return lsfg_mc::set_runtime_config(&cfg);
}

JNIEXPORT jint JNICALL
Java_com_lsfg_minecraft_LsfgNativeBridge_notifyContentDiscontinuity(
        JNIEnv * /*env*/, jclass /*clazz*/) {
    return lsfg_mc::notify_content_discontinuity();
}

} // extern "C"
