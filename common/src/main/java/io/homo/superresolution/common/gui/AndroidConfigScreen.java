/*
 * Super Resolution
 * Copyright (c) 2025-2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.gui;

import io.homo.superresolution.api.registry.AlgorithmDescription;
import io.homo.superresolution.api.registry.AlgorithmRegistry;
import io.homo.superresolution.common.SuperResolution;
import io.homo.superresolution.common.config.SuperResolutionConfig;
import io.homo.superresolution.common.debug.SuperResolutionDebugHelper;
import io.homo.superresolution.common.minecraft.MinecraftUtils;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;

import java.util.ArrayList;
import java.util.List;

public class AndroidConfigScreen extends Screen {
    private final Screen parentScreen;
    private static final float[] SCALE_PRESETS = {2.0f, 1.7f, 1.5f, 1.33f, 1.0f};
    private static final float[] SHARPNESS_PRESETS = {0.0f, 0.25f, 0.5f, 0.55f, 0.75f, 1.0f};

    private Button statusButton;

    public AndroidConfigScreen(Screen parentScreen) {
        super(Component.literal("Super Resolution Settings"));
        this.parentScreen = parentScreen;
    }

    @Override
    protected void init() {
        int centerX = this.width / 2;
        int startY = 30;
        int buttonWidth = 240;
        int buttonHeight = 20;
        int gap = 24;

        // 1. Enable / Disable
        this.addRenderableWidget(
                Button.builder(getEnableText(), btn -> {
                    boolean next = !SuperResolutionConfig.isEnableUpscale();
                    SuperResolutionConfig.setEnableUpscale(next);
                    btn.setMessage(getEnableText());
                    SuperResolutionConfig.SPEC.save();
                    updateStatusText();
                }).bounds(centerX - buttonWidth / 2, startY, buttonWidth, buttonHeight).build()
        );

        // 2. Algorithm (SGSR1 / BILINEAR / NONE)
        this.addRenderableWidget(
                Button.builder(getAlgoText(), btn -> {
                    List<AlgorithmDescription<?>> algos = new ArrayList<>(AlgorithmRegistry.getAlgorithmMap().values());
                    if (algos.isEmpty()) return;
                    AlgorithmDescription<?> current = SuperResolutionConfig.getUpscaleAlgorithm();
                    int idx = algos.indexOf(current);
                    int nextIdx = (idx + 1) % algos.size();
                    AlgorithmDescription<?> nextAlgo = algos.get(nextIdx);
                    SuperResolutionConfig.setUpscaleAlgorithm(nextAlgo);
                    btn.setMessage(getAlgoText());
                    SuperResolutionConfig.SPEC.save();
                    updateStatusText();
                }).bounds(centerX - buttonWidth / 2, startY + gap, buttonWidth, buttonHeight).build()
        );

        // 3. Render Scale / Ratio
        this.addRenderableWidget(
                Button.builder(getScaleText(), btn -> {
                    float current = (float) SuperResolutionConfig.getUpscaleRatio();
                    int bestIdx = 0;
                    float minDiff = Float.MAX_VALUE;
                    for (int i = 0; i < SCALE_PRESETS.length; i++) {
                        float diff = Math.abs(SCALE_PRESETS[i] - current);
                        if (diff < minDiff) {
                            minDiff = diff;
                            bestIdx = i;
                        }
                    }
                    int nextIdx = (bestIdx + 1) % SCALE_PRESETS.length;
                    float nextRatio = SCALE_PRESETS[nextIdx];
                    SuperResolutionConfig.setUpscaleRatio(nextRatio);
                    btn.setMessage(getScaleText());
                    SuperResolutionConfig.SPEC.save();
                    updateStatusText();
                }).bounds(centerX - buttonWidth / 2, startY + gap * 2, buttonWidth, buttonHeight).build()
        );

        // 4. Sharpness
        this.addRenderableWidget(
                Button.builder(getSharpnessText(), btn -> {
                    float current = (float) SuperResolutionConfig.getSharpness();
                    int bestIdx = 0;
                    float minDiff = Float.MAX_VALUE;
                    for (int i = 0; i < SHARPNESS_PRESETS.length; i++) {
                        float diff = Math.abs(SHARPNESS_PRESETS[i] - current);
                        if (diff < minDiff) {
                            minDiff = diff;
                            bestIdx = i;
                        }
                    }
                    int nextIdx = (bestIdx + 1) % SHARPNESS_PRESETS.length;
                    float nextSharp = SHARPNESS_PRESETS[nextIdx];
                    SuperResolutionConfig.setSharpness(nextSharp);
                    btn.setMessage(getSharpnessText());
                    SuperResolutionConfig.SPEC.save();
                }).bounds(centerX - buttonWidth / 2, startY + gap * 3, buttonWidth, buttonHeight).build()
        );

        // 5. Runtime Status Display / SR Debug Info Button
        statusButton = this.addRenderableWidget(
                Button.builder(getStatusButtonText(), btn -> {
                    SuperResolutionDebugHelper.printDebugInfo();
                    updateStatusText();
                }).bounds(centerX - buttonWidth / 2, startY + gap * 4, buttonWidth, buttonHeight).build()
        );

        // 6. Done / Back Button
        this.addRenderableWidget(
                Button.builder(Component.literal("Done"), btn -> {
                    onClose();
                }).bounds(centerX - buttonWidth / 2, startY + gap * 5 + 4, buttonWidth, buttonHeight).build()
        );
    }

    private void updateStatusText() {
        if (statusButton != null) {
            statusButton.setMessage(getStatusButtonText());
        }
    }

    private Component getStatusButtonText() {
        SuperResolutionDebugHelper.StatusInfo status = SuperResolutionDebugHelper.getStatus();
        if (!status.enabled) {
            return Component.literal("SR: OFF (Click to Print Debug)");
        }
        int scalePct = (int) Math.round((1.0f / (status.scaleRatio <= 0 ? 1.0f : status.scaleRatio)) * 100.0f);
        return Component.literal(status.algorithm + " " + scalePct + "% [" + status.internalWidth + "x" + status.internalHeight + "] (Debug)");
    }

    private Component getEnableText() {
        return Component.literal("Super Resolution: " + (SuperResolutionConfig.isEnableUpscale() ? "ON" : "OFF"));
    }

    private Component getAlgoText() {
        AlgorithmDescription<?> algo = SuperResolutionConfig.getUpscaleAlgorithm();
        return Component.literal("Algorithm: " + (algo != null ? algo.displayName : "None"));
    }

    private Component getScaleText() {
        float ratio = (float) SuperResolutionConfig.getUpscaleRatio();
        int percent = Math.round((1.0f / ratio) * 100.0f);
        return Component.literal("Render Scale: " + percent + "% (" + String.format("%.2fx", ratio) + ")");
    }

    private Component getSharpnessText() {
        float sharp = (float) SuperResolutionConfig.getSharpness();
        return Component.literal("Sharpness: " + String.format("%.2f", sharp));
    }

    @Override
    public void onClose() {
        SuperResolutionConfig.SPEC.save();
        SuperResolution.recreateAlgorithm();
        MinecraftUtils.setScreen(this.parentScreen);
    }
}
