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

    public static native void shutdown();
}
