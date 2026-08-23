/*
 * Super Resolution
 * Copyright (c) 2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1;

/**
 * Pure helper for resolving SGSR dimension contracts.
 * Ensures the internal sampling dimensions and output raster viewport dimensions are cleanly separated.
 */
public final class SgsrViewportDimensions {
    private final int width;
    private final int height;

    public SgsrViewportDimensions(int width, int height) {
        this.width = width;
        this.height = height;
    }

    public int getWidth() {
        return width;
    }

    public int getHeight() {
        return height;
    }

    /**
     * Determines the raster viewport dimensions for the SGSR output pass.
     * Must ALWAYS match the output/screen target dimensions, not the internal render dimensions.
     */
    public static SgsrViewportDimensions output(int renderWidth, int renderHeight, int screenWidth, int screenHeight) {
        return new SgsrViewportDimensions(screenWidth, screenHeight);
    }

    /**
     * Determines the sampling dimensions for SGSR ViewportInfo uniform buffer.
     * Must ALWAYS match the input/internal render dimensions.
     */
    public static SgsrViewportDimensions input(int renderWidth, int renderHeight, int screenWidth, int screenHeight) {
        return new SgsrViewportDimensions(renderWidth, renderHeight);
    }
}