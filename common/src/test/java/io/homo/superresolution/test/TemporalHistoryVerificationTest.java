package io.homo.superresolution.test;

import io.homo.superresolution.common.debug.SuperResolutionDebugHelper;
import io.homo.superresolution.common.temporal.TemporalHistoryManager;
import io.homo.superresolution.core.graphics.impl.texture.TextureFormat;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class TemporalHistoryVerificationTest {

    @BeforeEach
    void setup() {
        TemporalHistoryManager manager = TemporalHistoryManager.getInstance();
        manager.reset();
    }

    @Test
    void testResolutionChangeIncrementsGenerationAndInvalidatesHistory() {
        TemporalHistoryManager manager = TemporalHistoryManager.getInstance();
        long genBefore = manager.getResolutionGeneration();

        manager.checkResolutionChange(960, 540, "Test 50%");
        assertEquals(960, manager.getCurrentWidth());
        assertEquals(540, manager.getCurrentHeight());
        assertTrue(manager.getResolutionGeneration() > genBefore, "Generation must increment on resolution change");
        assertFalse(manager.isHistoryValid(), "History must be invalid immediately after resolution change");

        // Simulate frame render at new resolution
        manager.onFrameRendered();
        assertTrue(manager.isHistoryValid(), "History must become valid after full frame at new resolution");
    }

    @Test
    void testStableResolutionDoesNotInvalidateEveryFrame() {
        TemporalHistoryManager manager = TemporalHistoryManager.getInstance();
        manager.checkResolutionChange(960, 540, "Initial 50%");
        manager.onFrameRendered();
        assertTrue(manager.isHistoryValid());

        long genStable = manager.getResolutionGeneration();
        for (int i = 0; i < 10; i++) {
            manager.checkResolutionChange(960, 540, "Steady state frame " + i);
            manager.onFrameRendered();
            assertEquals(genStable, manager.getResolutionGeneration(), "Generation must not change during steady-state rendering");
            assertTrue(manager.isHistoryValid(), "History must remain valid during steady-state rendering");
        }
    }

    @Test
    void testScaleFactorChange100To50InvalidatesHistory() {
        TemporalHistoryManager manager = TemporalHistoryManager.getInstance();
        manager.checkResolutionChange(1920, 1080, "Native 100%");
        manager.onFrameRendered();
        assertTrue(manager.isHistoryValid());

        long gen100 = manager.getResolutionGeneration();
        manager.checkResolutionChange(960, 540, "Switch to 50%");
        assertTrue(manager.getResolutionGeneration() > gen100);
        assertFalse(manager.isHistoryValid(), "History must be invalidated when scale switches from 100% to 50%");

        assertEquals(1920, manager.getPreviousWidth());
        assertEquals(1080, manager.getPreviousHeight());
        assertEquals(960, manager.getCurrentWidth());
        assertEquals(540, manager.getCurrentHeight());
    }

    @Test
    void testDebugStatusFormattingWithTemporalFields() {
        SuperResolutionDebugHelper.StatusInfo status = new SuperResolutionDebugHelper.StatusInfo();
        status.algorithm = "Bilinear";
        status.enabled = true;
        status.internalWidth = 960;
        status.internalHeight = 540;
        status.outputWidth = 1920;
        status.outputHeight = 1080;
        status.scaleRatio = 0.5f;
        status.backend = "OpenGL";
        status.renderer = "Turnip PurpleVK";
        status.javaOnly = true;
        status.irisInstalled = true;
        status.shaderpackActive = true;
        status.shaderpackName = "ComplementaryReimagined_r5.5.1";
        status.temporalGen = 42;
        status.historyValid = true;

        String summary = status.getChatSummary();
        assertTrue(summary.contains("Bilinear"));
        assertTrue(summary.contains("960x540"));
        assertTrue(summary.contains("1920x1080"));
    }

    @Test
    void testDepthFormatIsDepthProperty() {
        assertTrue(TextureFormat.DEPTH32F.isDepth());
        assertTrue(TextureFormat.DEPTH32F_STENCIL8.isDepth());
        assertTrue(TextureFormat.DEPTH24_STENCIL8.isDepth());
        assertTrue(TextureFormat.DEPTH24.isDepth());
        assertTrue(TextureFormat.DEPTH32.isDepth());
        assertFalse(TextureFormat.RGBA8.isDepth());
        assertFalse(TextureFormat.RGBA16F.isDepth());
    }
}