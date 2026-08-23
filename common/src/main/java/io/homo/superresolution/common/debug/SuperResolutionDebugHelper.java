/*
 * Super Resolution
 * Copyright (c) 2025-2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.debug;

import io.homo.superresolution.api.platform.Platform;
import io.homo.superresolution.common.SuperResolution;
import io.homo.superresolution.common.config.SuperResolutionConfig;
import io.homo.superresolution.common.metrics.UpscaleGpuMetrics;
import io.homo.superresolution.common.minecraft.MinecraftRenderTargetUtil;
import io.homo.superresolution.common.minecraft.handler.RenderHandlerManager;
import net.minecraft.client.Minecraft;
import net.minecraft.network.chat.Component;

import java.util.Locale;

public class SuperResolutionDebugHelper {

    public static class StatusInfo {
        public String algorithm;
        public boolean enabled;
        public int internalWidth;
        public int internalHeight;
        public int outputWidth;
        public int outputHeight;
        public float scaleRatio;
        public String backend;
        public String renderer;
        public boolean javaOnly;
        public String colorFormat;
        public String depthFormat;
        public boolean irisInstalled;
        public boolean shaderpackActive;
        public String shaderpackName;
        public long temporalGen;
        public boolean historyValid;

        public String getF3Line1() {
            if (!enabled) {
                return "SR: OFF | " + outputWidth + "x" + outputHeight + " native";
            }
            int scalePct = (int) Math.round((1.0f / (scaleRatio <= 0 ? 1.0f : scaleRatio)) * 100.0f);
            return "SR: " + algorithm + " | " + internalWidth + "x" + internalHeight + " -> " + outputWidth + "x" + outputHeight + " | " + scalePct + "%";
        }

        public String getF3Line2() {
            return "SR backend: " + backend + " | " + renderer;
        }

        public String getF3Line3() {
            if (!irisInstalled) {
                return null;
            }
            return shaderpackActive && shaderpackName != null
                    ? "Iris: " + shaderpackName
                    : "Iris: installed | shaders OFF";
        }

        public String getF3Line4() {
            if (!enabled) {
                return null;
            }
            return UpscaleGpuMetrics.getInstance().getF3Line();
        }

        public String getChatSummary() {
            String irisPart = irisInstalled
                    ? (" | Iris: " + (shaderpackActive && shaderpackName != null ? shaderpackName : "installed (shaders OFF)"))
                    : "";
            if (!enabled) {
                return "[SR] OFF | " + outputWidth + "x" + outputHeight + " native | " + backend + " (" + renderer + ")" + irisPart;
            }
            int scalePct = (int) Math.round((1.0f / (scaleRatio <= 0 ? 1.0f : scaleRatio)) * 100.0f);
            return "[SR] " + algorithm + " | " + internalWidth + "x" + internalHeight + " -> " + outputWidth + "x" + outputHeight + " | " + scalePct + "% | " + backend + "/" + renderer + irisPart;
        }

        public String getFullLogString() {
            return String.format(
                    Locale.ROOT,
                    "[SR-STATUS] algorithm=%s, enabled=%b, internal=%dx%d, output=%dx%d, scale=%.2f, backend=%s, renderer=%s, javaOnly=%b, colorFormat=%s, depthFormat=%s, irisInstalled=%b, shaderpackActive=%b, shaderpack=%s, temporalGen=%d, historyValid=%b",
                    algorithm, enabled, internalWidth, internalHeight, outputWidth, outputHeight, (1.0f / (scaleRatio <= 0 ? 1.0f : scaleRatio)), backend, renderer, javaOnly,
                    colorFormat, depthFormat, irisInstalled, shaderpackActive, shaderpackName, temporalGen, historyValid
            );
        }
    }

    public static StatusInfo getStatus() {
        StatusInfo info = new StatusInfo();
        info.enabled = SuperResolutionConfig.isEnableUpscale();
        info.algorithm = SuperResolutionConfig.getUpscaleAlgorithm() != null ? SuperResolutionConfig.getUpscaleAlgorithm().briefName : "None";
        info.internalWidth = RenderHandlerManager.getRenderWidth();
        info.internalHeight = RenderHandlerManager.getRenderHeight();
        info.outputWidth = RenderHandlerManager.getScreenWidth();
        info.outputHeight = RenderHandlerManager.getScreenHeight();
        info.scaleRatio = (float) SuperResolutionConfig.getUpscaleRatio();
        info.backend = "OpenGL";
        String r = null;
        try {
            r = org.lwjgl.opengl.GL11.glGetString(org.lwjgl.opengl.GL11.GL_RENDERER);
        } catch (Throwable ignored) {}
        info.renderer = r != null ? r : "OpenGL (Unknown)";
        info.javaOnly = Platform.isJavaOnlyMode();
        info.colorFormat = "RGBA8";
        info.depthFormat = MinecraftRenderTargetUtil.getPreferredDepthFormat().name();
        info.irisInstalled = io.homo.superresolution.common.compat.iris.IrisCompatHelper.isIrisInstalled();
        info.shaderpackActive = io.homo.superresolution.common.compat.iris.IrisCompatHelper.hasActiveShaderpack();
        info.shaderpackName = io.homo.superresolution.common.compat.iris.IrisCompatHelper.getActiveShaderpackName();
        info.temporalGen = io.homo.superresolution.common.temporal.TemporalHistoryManager.getInstance().getResolutionGeneration();
        info.historyValid = io.homo.superresolution.common.temporal.TemporalHistoryManager.getInstance().isHistoryValid();
        return info;
    }

    public static void printDebugInfo() {
        StatusInfo status = getStatus();
        SuperResolution.LOGGER.info("[SR-STATUS] algorithm={}", status.algorithm);
        SuperResolution.LOGGER.info("[SR-STATUS] enabled={}", status.enabled);
        SuperResolution.LOGGER.info("[SR-STATUS] internal={}x{}", status.internalWidth, status.internalHeight);
        SuperResolution.LOGGER.info("[SR-STATUS] output={}x{}", status.outputWidth, status.outputHeight);
        SuperResolution.LOGGER.info(String.format(Locale.ROOT, "[SR-STATUS] scale=%.2f", (1.0f / (status.scaleRatio <= 0 ? 1.0f : status.scaleRatio))));
        SuperResolution.LOGGER.info("[SR-STATUS] backend={}", status.backend);
        SuperResolution.LOGGER.info("[SR-STATUS] renderer={}", status.renderer);
        SuperResolution.LOGGER.info("[SR-STATUS] javaOnly={}", status.javaOnly);
        SuperResolution.LOGGER.info("[SR-STATUS] colorFormat={}", status.colorFormat);
        SuperResolution.LOGGER.info("[SR-STATUS] depthFormat={}", status.depthFormat);
        SuperResolution.LOGGER.info("[SR-STATUS] iris={}", status.irisInstalled);
        SuperResolution.LOGGER.info("[SR-STATUS] shaderpack={}", status.shaderpackActive && status.shaderpackName != null ? status.shaderpackName : "none");

        UpscaleGpuMetrics.getInstance().logStatus();

        try {
            Minecraft mc = Minecraft.getInstance();
            if (mc != null && mc.player != null) {
                mc.player.sendSystemMessage(Component.literal(status.getChatSummary()));
            }
        } catch (Throwable t) {
            SuperResolution.LOGGER.warn("Failed to send chat debug status message", t);
        }
    }
}