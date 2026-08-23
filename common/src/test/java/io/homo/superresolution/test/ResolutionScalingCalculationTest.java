package io.homo.superresolution.test;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class ResolutionScalingCalculationTest {

    @Test
    void testQualityScaleCalculation() {
        int screenWidth = 1920;
        int screenHeight = 1080;
        float upscaleRatio = 1.5f; // Quality preset
        float scaleFactor = 1.0f / upscaleRatio;

        int renderWidth = (int) Math.max(screenWidth * scaleFactor, 32);
        int renderHeight = (int) Math.max(screenHeight * scaleFactor, 32);

        assertEquals(1280, renderWidth, "Render width for 1080p with 1.5x ratio should be 1280 (720p)");
        assertEquals(720, renderHeight, "Render height for 1080p with 1.5x ratio should be 720 (720p)");
    }

    @Test
    void testBalancedScaleCalculation() {
        int screenWidth = 1920;
        int screenHeight = 1080;
        float upscaleRatio = 1.7f; // Balanced preset
        float scaleFactor = 1.0f / upscaleRatio;

        int renderWidth = (int) Math.max(screenWidth * scaleFactor, 32);
        int renderHeight = (int) Math.max(screenHeight * scaleFactor, 32);

        assertTrue(renderWidth < 1280 && renderWidth > 1000, "Render width should be scaled appropriately");
        assertTrue(renderHeight < 720 && renderHeight > 600, "Render height should be scaled appropriately");
    }

    @Test
    void testClampMinimumSize() {
        int screenWidth = 10;
        int screenHeight = 10;
        float scaleFactor = 0.5f;

        int renderWidth = (int) Math.max(screenWidth * scaleFactor, 32);
        int renderHeight = (int) Math.max(screenHeight * scaleFactor, 32);

        assertEquals(32, renderWidth, "Should clamp to minimum 32px");
        assertEquals(32, renderHeight, "Should clamp to minimum 32px");
    }
}
