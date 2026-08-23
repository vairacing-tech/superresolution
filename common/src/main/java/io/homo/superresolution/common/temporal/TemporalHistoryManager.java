/*
 * Super Resolution
 * Copyright (c) 2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package io.homo.superresolution.common.temporal;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Generic manager for tracking temporal history validity, resolution generations,
 * and safe history lifecycle across Super Resolution scale changes and toggles.
 */
public final class TemporalHistoryManager {
    private static final TemporalHistoryManager INSTANCE = new TemporalHistoryManager();
    private static final Logger LOGGER = LoggerFactory.getLogger("SuperResolution-Temporal");

    private int currentWidth = 0;
    private int currentHeight = 0;
    private int previousWidth = 0;
    private int previousHeight = 0;

    private long resolutionGeneration = 0;
    private long frameIndex = 0;
    private boolean historyValid = false;
    private int framesSinceInvalidation = 0;

    private TemporalHistoryManager() {
    }

    public static TemporalHistoryManager getInstance() {
        return INSTANCE;
    }

    public synchronized void reset() {
        this.currentWidth = 0;
        this.currentHeight = 0;
        this.previousWidth = 0;
        this.previousHeight = 0;
        this.historyValid = false;
        this.framesSinceInvalidation = 0;
        this.resolutionGeneration = 0;
        this.frameIndex = 0;
    }

    public synchronized int getCurrentWidth() {
        return currentWidth;
    }

    public synchronized int getCurrentHeight() {
        return currentHeight;
    }

    public synchronized int getPreviousWidth() {
        return previousWidth;
    }

    public synchronized int getPreviousHeight() {
        return previousHeight;
    }

    public synchronized long getResolutionGeneration() {
        return resolutionGeneration;
    }

    public synchronized long getFrameIndex() {
        return frameIndex;
    }

    public synchronized boolean isHistoryValid() {
        return historyValid;
    }

    public synchronized int getFramesSinceInvalidation() {
        return framesSinceInvalidation;
    }

    /**
     * Check if internal resolution has changed and trigger invalidation if so.
     */
    public synchronized void checkResolutionChange(int newWidth, int newHeight, String source) {
        if (newWidth <= 0 || newHeight <= 0) {
            return;
        }
        if (this.currentWidth != newWidth || this.currentHeight != newHeight) {
            this.previousWidth = this.currentWidth;
            this.previousHeight = this.currentHeight;
            this.currentWidth = newWidth;
            this.currentHeight = newHeight;
            invalidateHistory("Resolution change from " + previousWidth + "x" + previousHeight +
                    " to " + currentWidth + "x" + currentHeight + " via " + source);
        }
    }

    /**
     * Explicitly invalidate history state across the pipeline.
     */
    public synchronized void invalidateHistory(String reason) {
        this.historyValid = false;
        this.framesSinceInvalidation = 0;
        this.resolutionGeneration++;

        LOGGER.info("[SR-HISTORY-INVALIDATE] reason={}, generation={}, size={}x{}",
                reason, resolutionGeneration, currentWidth, currentHeight);
    }

    /**
     * Called at the beginning/end of a frame rendering pass.
     */
    public synchronized void onFrameRendered() {
        this.frameIndex++;
        if (!this.historyValid) {
            this.framesSinceInvalidation++;
            if (this.framesSinceInvalidation >= 1) {
                this.historyValid = true;
                LOGGER.info("[SR-HISTORY] History became VALID at frame={}, gen={}, size={}x{}",
                        frameIndex, resolutionGeneration, currentWidth, currentHeight);
            }
        }
    }
}