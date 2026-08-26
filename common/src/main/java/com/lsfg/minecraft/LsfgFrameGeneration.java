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

import io.homo.superresolution.common.framegeneration.FrameGenerationAlgorithm;
import io.homo.superresolution.common.framegeneration.FrameGenerationAlgorithmType;

import java.nio.file.Path;

public class LsfgFrameGeneration implements FrameGenerationAlgorithm {

    private final Path gameDir;
    private LsfgConfig config;
    private boolean initialized = false;
    private boolean available = false;
    private boolean enabled = false;
    private boolean nativeBackendArmed = false;
    private String statusMessage = "Uninitialized";
    private int capabilities = 0;

    public LsfgFrameGeneration(Path gameDir) {
        this.gameDir = gameDir;
    }

    @Override
    public FrameGenerationAlgorithmType getType() {
        return FrameGenerationAlgorithmType.LSFG;
    }

    @Override
    public String getId() {
        return FrameGenerationAlgorithmType.LSFG.getId();
    }

    @Override
    public String getDisplayName() {
        return FrameGenerationAlgorithmType.LSFG.getDisplayName();
    }

    @Override
    public boolean isAvailable() {
        return available;
    }

    public boolean isNativeBackendArmed() {
        return nativeBackendArmed;
    }

    @Override
    public synchronized void initialize() {
        if (initialized) {
            return;
        }
        initialized = true;

        config = LsfgConfig.load(gameDir);

        if (!LsfgPlatform.isSupportedPlatform()) {
            available = false;
            nativeBackendArmed = false;
            statusMessage = "Unsupported platform (" + LsfgPlatform.getOs() + "/" + LsfgPlatform.getArch() + ")";
            return;
        }

        // 1. Load Native ARM64 backend
        boolean nativeLoaded = LsfgNativeLoader.load();
        if (!nativeLoaded) {
            available = false;
            nativeBackendArmed = false;
            statusMessage = "Native library load failed: " + LsfgNativeLoader.getLastError();
            return;
        }

        // 2. Initialize native backend state & passive Vulkan observation
        try {
            int initCode = LsfgNativeBridge.initNativeBackend();
            if (initCode != 0) {
                available = false;
                nativeBackendArmed = false;
                statusMessage = "Native backend init returned error code " + initCode;
                return;
            }

            capabilities = LsfgNativeBridge.getCapabilities();
            nativeBackendArmed = true;
        } catch (Throwable t) {
            available = false;
            nativeBackendArmed = false;
            statusMessage = "Exception initializing LSFG backend: " + t.getMessage();
            return;
        }

        // 3. Locate and inspect mods/Lossless.dll
        LosslessDllResolver.ResolutionResult dllResult = LosslessDllResolver.resolve(gameDir);
        if (dllResult.getStatus() == LosslessDllResolver.DllStatus.ABSENT) {
            available = false; // Cannot interpolate without shader assets, but passive probe is armed
            statusMessage = "Lossless.dll not found in mods/ (passive Vulkan probe armed)";
            return;
        }

        if (!dllResult.isValid()) {
            available = false;
            statusMessage = "Invalid Lossless.dll: " + dllResult.getMessage();
            return;
        }

        // 4. Ensure Shader Cache
        ShaderCacheManager.CacheResult cacheResult = ShaderCacheManager.ensureShaderCache(
            gameDir,
            dllResult.getFile(),
            dllResult.getSha256()
        );

        if (!cacheResult.isReady()) {
            available = false;
            statusMessage = "Shader cache initialization failed: " + cacheResult.getMessage();
            return;
        }

        available = true;
        statusMessage = "Ready (Native build: " + LsfgNativeBridge.getNativeVersion() + ", Caps: 0x" + Integer.toHexString(capabilities) + ")";
    }

    @Override
    public synchronized boolean enable() {
        if (!available) {
            enabled = false;
            return false;
        }
        enabled = true;
        return true;
    }

    @Override
    public synchronized void disable() {
        enabled = false;
    }

    @Override
    public boolean isEnabled() {
        return enabled && available;
    }

    @Override
    public void onFrame(int frameIndex) {
        // Phase 2C: Passive observation only
    }

    @Override
    public void resize(int width, int height) {
        // Phase 2C: Passive observation only
    }

    @Override
    public synchronized void destroy() {
        if (initialized && nativeBackendArmed) {
            try {
                LsfgNativeBridge.shutdown();
            } catch (Throwable ignored) {}
        }
        enabled = false;
        available = false;
        nativeBackendArmed = false;
        initialized = false;
        statusMessage = "Destroyed";
    }

    @Override
    public String getStatusMessage() {
        return statusMessage;
    }

    public LsfgConfig getConfig() {
        return config;
    }

    public int getCapabilities() {
        return capabilities;
    }
}
