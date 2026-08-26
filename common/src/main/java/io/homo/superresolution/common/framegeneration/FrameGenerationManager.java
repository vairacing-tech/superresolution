/*
 * Super Resolution
 * Copyright (c) 2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.framegeneration;

import com.lsfg.minecraft.LsfgConfig;
import com.lsfg.minecraft.LsfgFrameGeneration;
import com.lsfg.minecraft.LsfgNativeBridge;
import com.lsfg.minecraft.LsfgNativeLoader;
import com.lsfg.minecraft.LsfgPlatform;
import io.homo.superresolution.common.framegeneration.impl.NoneFrameGeneration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.file.Path;
import java.util.EnumMap;
import java.util.Map;

public final class FrameGenerationManager {

    private static final Logger LOGGER = LoggerFactory.getLogger("SuperResolution/FrameGenManager");

    private static final Map<FrameGenerationAlgorithmType, FrameGenerationAlgorithm> ALGORITHMS =
            new EnumMap<>(FrameGenerationAlgorithmType.class);

    private static FrameGenerationAlgorithmType activeType = FrameGenerationAlgorithmType.NONE;
    private static boolean initialized = false;
    private static boolean probeActive = false;
    private static Path currentGameDir = null;

    private FrameGenerationManager() {}

    public static synchronized void initialize(Path gameDir) {
        if (initialized) {
            return;
        }
        currentGameDir = gameDir;

        // Register NONE algorithm (always available, default)
        NoneFrameGeneration none = new NoneFrameGeneration();
        none.initialize();
        ALGORITHMS.put(FrameGenerationAlgorithmType.NONE, none);

        // Register LSFG candidate algorithm
        LsfgFrameGeneration lsfg = new LsfgFrameGeneration(gameDir);
        ALGORITHMS.put(FrameGenerationAlgorithmType.LSFG, lsfg);

        // Probe initialization on supported Android ARM64 platforms
        if (LsfgPlatform.isProbeEnabled()) {
            try {
                lsfg.initialize();
                if (lsfg.isAvailable() || lsfg.isNativeBackendArmed()) {
                    probeActive = true;
                    LOGGER.info("[LSFG-PROBE] native loaded: {}", LsfgNativeLoader.getExtractedPath());
                    LOGGER.info("[LSFG-PROBE] interception mechanism: GIPA/GDPA export & VULKAN_PTR discovery");
                    LOGGER.info("[LSFG-PROBE] Passive Vulkan observation armed (native build: {})",
                            LsfgNativeBridge.getNativeVersion());
                } else {
                    LOGGER.warn("[LSFG-PROBE] Passive probe initialization skipped: {}", lsfg.getStatusMessage());
                }
            } catch (Throwable t) {
                LOGGER.warn("[LSFG-PROBE] Passive probe initialization failed safely: {}", t.getMessage());
            }
        }

        activeType = FrameGenerationAlgorithmType.NONE;
        initialized = true;
    }

    public static synchronized void setAlgorithm(FrameGenerationAlgorithmType type) {
        if (type == null) {
            type = FrameGenerationAlgorithmType.NONE;
        }

        if (type == activeType) {
            return;
        }

        FrameGenerationAlgorithm target = ALGORITHMS.get(type);
        if (target == null || !target.isAvailable()) {
            LOGGER.warn("[SuperResolution/FrameGen] Algorithm {} is unavailable. Falling back to NONE.", type);
            activeType = FrameGenerationAlgorithmType.NONE;
            return;
        }

        FrameGenerationAlgorithm previous = ALGORITHMS.get(activeType);
        if (previous != null) {
            previous.disable();
        }

        boolean success = target.enable();
        if (success) {
            activeType = type;
            LOGGER.info("[SuperResolution/FrameGen] Frame generation algorithm switched to: {}", type.getDisplayName());
        } else {
            LOGGER.warn("[SuperResolution/FrameGen] Failed to enable {}. Falling back to NONE.", type);
            activeType = FrameGenerationAlgorithmType.NONE;
            ALGORITHMS.get(FrameGenerationAlgorithmType.NONE).enable();
        }
    }

    public static FrameGenerationAlgorithmType getActiveType() {
        return activeType;
    }

    public static FrameGenerationAlgorithm getActiveAlgorithm() {
        return ALGORITHMS.getOrDefault(activeType, ALGORITHMS.get(FrameGenerationAlgorithmType.NONE));
    }

    public static FrameGenerationAlgorithm getAlgorithm(FrameGenerationAlgorithmType type) {
        return ALGORITHMS.get(type);
    }

    public static boolean isAvailable(FrameGenerationAlgorithmType type) {
        FrameGenerationAlgorithm algo = ALGORITHMS.get(type);
        return algo != null && algo.isAvailable();
    }

    public static boolean isProbeActive() {
        return probeActive;
    }

    public static void onFrame(int frameIndex) {
        FrameGenerationAlgorithm active = getActiveAlgorithm();
        if (active != null && active.isEnabled()) {
            active.onFrame(frameIndex);
        }
    }

    public static void resize(int width, int height) {
        FrameGenerationAlgorithm active = getActiveAlgorithm();
        if (active != null) {
            active.resize(width, height);
        }
    }

    public static String getProbeSnapshotString() {
        if (LsfgNativeBridge.isLoaded()) {
            try {
                String snap = LsfgNativeBridge.getProbeSnapshot();
                if (snap != null && !snap.isEmpty()) {
                    return snap;
                }
            } catch (Throwable ignored) {}
        }
        return "gipa=0 gdpa=0 createSwapchain=0 destroySwapchain=0 getSwapchainImages=0 acquire=0 acquire2=0 present=0 size=0x0 format=0 images=0";
    }

    public static synchronized void destroy() {
        LOGGER.info("[LSFG-PROBE-SUMMARY] {}", getProbeSnapshotString());
        probeActive = false;
        for (FrameGenerationAlgorithm algo : ALGORITHMS.values()) {
            if (algo != null) {
                algo.destroy();
            }
        }
        ALGORITHMS.clear();
        activeType = FrameGenerationAlgorithmType.NONE;
        initialized = false;
    }

    public static String getDiagnostics() {
        StringBuilder sb = new StringBuilder();
        sb.append("Frame Generation State:\n");
        sb.append("  Active: ").append(activeType.getDisplayName()).append("\n");
        sb.append("  Probe active: ").append(probeActive).append("\n");
        sb.append("  Probe snapshot: ").append(getProbeSnapshotString()).append("\n");
        for (Map.Entry<FrameGenerationAlgorithmType, FrameGenerationAlgorithm> entry : ALGORITHMS.entrySet()) {
            sb.append("  [").append(entry.getKey()).append("]: ");
            if (entry.getValue() != null) {
                sb.append("available=").append(entry.getValue().isAvailable())
                  .append(", enabled=").append(entry.getValue().isEnabled())
                  .append(" (").append(entry.getValue().getStatusMessage()).append(")\n");
            } else {
                sb.append("not registered\n");
            }
        }
        return sb.toString();
    }
}
