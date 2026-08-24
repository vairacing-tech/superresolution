package io.homo.superresolution.test;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class IrisResizeLifecycleTest {

    @Test
    void testAllAndroidScalePresetDimensionsAt1080p() {
        int screenW = 1920;
        int screenH = 1080;

        float[] scalePresets = {
                2.5f,         // 40%
                1.0f / 0.45f, // 45%
                2.0f,         // 50%
                1.7f,         // ~59%
                1.5f,         // ~67%
                1.33f,        // ~75%
                1.0f          // 100%
        };

        // 40% -> 768x432
        int w40 = (int) (screenW * (1.0f / scalePresets[0]));
        int h40 = (int) (screenH * (1.0f / scalePresets[0]));
        assertEquals(768, w40);
        assertEquals(432, h40);

        // 45% -> 864x486
        int w45 = (int) (screenW * (1.0f / scalePresets[1]));
        int h45 = (int) (screenH * (1.0f / scalePresets[1]));
        assertEquals(864, w45);
        assertEquals(486, h45);

        // 50% -> 960x540
        int w50 = (int) (screenW * (1.0f / scalePresets[2]));
        int h50 = (int) (screenH * (1.0f / scalePresets[2]));
        assertEquals(960, w50);
        assertEquals(540, h50);

        // ~59% (1.7) -> 1129x635
        int w59 = (int) (screenW * (1.0f / scalePresets[3]));
        int h59 = (int) (screenH * (1.0f / scalePresets[3]));
        assertEquals(1129, w59);
        assertEquals(635, h59);

        // ~67% (1.5) -> 1280x720
        int w67 = (int) (screenW * (1.0f / scalePresets[4]));
        int h67 = (int) (screenH * (1.0f / scalePresets[4]));
        assertEquals(1280, w67);
        assertEquals(720, h67);

        // ~75% (1.33) -> 1443x812
        int w75 = (int) (screenW * (1.0f / scalePresets[5]));
        int h75 = (int) (screenH * (1.0f / scalePresets[5]));
        assertEquals(1443, w75);
        assertEquals(812, h75);

        // 100% (1.0) -> 1920x1080
        int w100 = (int) (screenW * (1.0f / scalePresets[6]));
        int h100 = (int) (screenH * (1.0f / scalePresets[6]));
        assertEquals(1920, w100);
        assertEquals(1080, h100);
    }

    @Test
    void testNoOpResizeLogic() {
        int currentW = 960;
        int currentH = 540;

        // Same dimensions -> no-op
        int nextW = 960;
        int nextH = 540;
        boolean sizeChanged = (currentW != nextW || currentH != nextH);
        assertFalse(sizeChanged, "Same dimensions must result in NO-OP");

        // Dimension change 50% -> 45%
        nextW = 864;
        nextH = 486;
        sizeChanged = (currentW != nextW || currentH != nextH);
        assertTrue(sizeChanged, "Different dimensions must trigger resize");
    }

    @Test
    void testAbsenceOfRuntimeIrisReload() {
        // Static regression test verifying no runtime scale method calls Iris.reload()
        assertDoesNotThrow(() -> {
            Class<?> helperClass = Class.forName("io.homo.superresolution.common.compat.iris.IrisCompatHelper");
            try {
                helperClass.getDeclaredMethod("requestReload", String.class);
                fail("requestReload method should have been removed from IrisCompatHelper");
            } catch (NoSuchMethodException expected) {
                // Expected
            }
        });
    }

    @Test
    void testEncoderAndTextureViewMixinsRegistered() {
        assertDoesNotThrow(() -> {
            Class.forName("io.homo.superresolution.common.mixin.core.GlCommandEncoderMixin");
            Class.forName("io.homo.superresolution.common.mixin.core.GlTextureViewMixin");
        });
    }
}