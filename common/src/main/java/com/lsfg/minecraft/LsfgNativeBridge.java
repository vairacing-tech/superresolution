/*
 * Super Resolution - LSFG Android Integration
 * Copyright (c) 2026. vairacing-tech / FrankBarretta
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package com.lsfg.minecraft;

public final class LsfgNativeBridge {

    private static volatile boolean loaded = false;

    private LsfgNativeBridge() {}

    public static synchronized boolean isLoaded() {
        return loaded;
    }

    public static synchronized void setLoaded(boolean state) {
        loaded = state;
    }

    public static native String getNativeVersion();

    public static native int initNativeBackend();

    public static native boolean isPlatformSupported();

    public static native boolean isVulkanObserved();

    public static native String getProbeSnapshot();

    public static native int validateAndExtractShaders(String dllPath, String dllSha256, String cacheDir);

    public static native int probeShaderCache(String cacheDir);

    public static native int getCapabilities();

    public static class RuntimeStatus {
        public int state; // 0=OFF, 1=ARMING, 2=ACTIVE, 3=FALLBACK, 4=ERROR
        public int factor = 2; // Effective factor (2)
        public int requestedFactor = 2; // Requested factor from user configuration
        public long nativePresented;
        public long generatedPresented;
        public long generationAttempts;
        public long generationSuccess;
        public long generationFallback;
        public float nativeFps;
        public float outputFps;
        public float lastLsfgComputeMs;

        public String getStateString() {
            return switch (state) {
                case 1 -> "ARMING";
                case 2 -> "ACTIVE";
                case 3 -> "FALLBACK";
                case 4 -> "ERROR";
                default -> "OFF";
            };
        }

        public String getF3DisplayLine() {
            if (state == 0) {
                return "FG: OFF";
            }
            String st = getStateString();
            String factorStr = "x" + (factor == 3 ? 3 : 2);
            if (requestedFactor == 3 && factor != 3) {
                factorStr += " (Req x3 N/A)";
            }
            if (outputFps > 0.0f || nativeFps > 0.0f) {
                return String.format(java.util.Locale.ROOT,
                        "FG: %s %s | Native %.1f | Output %.1f FPS",
                        st, factorStr, nativeFps, outputFps);
            } else {
                return "FG: " + st + " " + factorStr;
            }
        }
    }

    public static native boolean getRuntimeStatus(RuntimeStatus outStatus);

    public static native int setRuntimeConfig(int enabled, int factor, int maxEvents, int armDelayMs);

    public static native void shutdown();
}
