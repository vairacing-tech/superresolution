/*
 * Super Resolution
 * Copyright (c) 2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.framegeneration.impl;

import io.homo.superresolution.common.framegeneration.FrameGenerationAlgorithm;
import io.homo.superresolution.common.framegeneration.FrameGenerationAlgorithmType;

public class NoneFrameGeneration implements FrameGenerationAlgorithm {

    private boolean enabled = false;

    @Override
    public FrameGenerationAlgorithmType getType() {
        return FrameGenerationAlgorithmType.NONE;
    }

    @Override
    public String getId() {
        return FrameGenerationAlgorithmType.NONE.getId();
    }

    @Override
    public String getDisplayName() {
        return FrameGenerationAlgorithmType.NONE.getDisplayName();
    }

    @Override
    public boolean isAvailable() {
        return true;
    }

    @Override
    public void initialize() {
        // No-op
    }

    @Override
    public boolean enable() {
        enabled = true;
        return true;
    }

    @Override
    public void disable() {
        enabled = false;
    }

    @Override
    public boolean isEnabled() {
        return enabled;
    }

    @Override
    public void onFrame(int frameIndex) {
        // No-op
    }

    @Override
    public void resize(int width, int height) {
        // No-op
    }

    @Override
    public void destroy() {
        enabled = false;
    }

    @Override
    public String getStatusMessage() {
        return "Frame Generation: Disabled (NONE)";
    }
}
