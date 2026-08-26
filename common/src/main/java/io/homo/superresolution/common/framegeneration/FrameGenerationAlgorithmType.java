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

public enum FrameGenerationAlgorithmType {
    NONE("superresolution:fg_none", "None"),
    LSFG("superresolution:fg_lsfg", "Lossless Scaling (LSFG)");

    private final String id;
    private final String displayName;

    FrameGenerationAlgorithmType(String id, String displayName) {
        this.id = id;
        this.displayName = displayName;
    }

    public String getId() {
        return id;
    }

    public String getDisplayName() {
        return displayName;
    }
}
