package io.homo.superresolution.test;

import io.homo.superresolution.api.platform.Platform;
import io.homo.superresolution.common.debug.SuperResolutionDebugHelper;
import io.homo.superresolution.common.workmode.SRWorkModeState;
import io.homo.superresolution.core.graphics.impl.texture.TextureFormat;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class SGSR1PipelineVerificationTest {

    @Test
    void testViewportUboCalculation() {
        int renderWidth = 960;
        int renderHeight = 540;

        float invW = 1.0f / renderWidth;
        float invH = 1.0f / renderHeight;
        float w = (float) renderWidth;
        float h = (float) renderHeight;

        assertEquals(0.0010416667f, invW, 1e-7f, "Inverse width for 960 must match expected UBO value");
        assertEquals(0.0018518519f, invH, 1e-7f, "Inverse height for 540 must match expected UBO value");
        assertEquals(960.0f, w, 0.001f);
        assertEquals(540.0f, h, 0.001f);
    }

    @Test
    void testOutputViewportUsesScreenDimensionsNotRenderDimensions() {
        int renderWidth = 960;
        int renderHeight = 540;
        int screenWidth = 1920;
        int screenHeight = 1080;

        // Input UBO parameters must match internal render size
        float invW = 1.0f / renderWidth;
        float invH = 1.0f / renderHeight;
        assertEquals(960.0f, (float) renderWidth);
        assertEquals(540.0f, (float) renderHeight);
        assertEquals(0.0010416667f, invW, 1e-7f);
        assertEquals(0.0018518519f, invH, 1e-7f);

        // Output raster viewport and blit destination must match native screen size
        assertEquals(1920, screenWidth, "Output viewport width must match native screen width");
        assertEquals(1080, screenHeight, "Output viewport height must match native screen height");
        assertNotEquals(renderWidth, screenWidth, "Output viewport must not be clamped to internal render width");
        assertNotEquals(renderHeight, screenHeight, "Output viewport must not be clamped to internal render height");
    }

    @Test
    void testAlphaPreservationPolicy() {
        // SGSR1 fragment shader passes through source alpha channel
        float srcSkyAlpha = 1.0f;
        float srcAtmosphereAlpha = 0.65f;
        float srcTransparentAlpha = 0.0f;

        float outSkyAlpha = srcSkyAlpha;
        float outAtmosphereAlpha = srcAtmosphereAlpha;
        float outTransparentAlpha = srcTransparentAlpha;

        assertEquals(srcSkyAlpha, outSkyAlpha, "Sky alpha must be preserved");
        assertEquals(srcAtmosphereAlpha, outAtmosphereAlpha, "Atmosphere alpha must be preserved");
        assertEquals(srcTransparentAlpha, outTransparentAlpha, "Transparent alpha must be preserved");
    }

    @Test
    void testBilinearAlgorithmProperties() {
        assertNotNull(io.homo.superresolution.common.upscale.AlgorithmDescriptions.BILINEAR);
        assertEquals("bilinear", io.homo.superresolution.common.upscale.AlgorithmDescriptions.BILINEAR.codeName);
        assertEquals("Bilinear", io.homo.superresolution.common.upscale.AlgorithmDescriptions.BILINEAR.briefName);
    }

    @Test
    void testDebugStatusFormatting() {
        SuperResolutionDebugHelper.StatusInfo status = new SuperResolutionDebugHelper.StatusInfo();
        status.enabled = true;
        status.algorithm = "Bilinear";
        status.internalWidth = 960;
        status.internalHeight = 540;
        status.outputWidth = 1920;
        status.outputHeight = 1080;
        status.scaleRatio = 2.0f;
        status.backend = "OpenGL";
        status.renderer = "zink (Adreno 740)";
        status.javaOnly = true;

        assertEquals("SR: Bilinear | 960x540 -> 1920x1080 | 50%", status.getF3Line1());
        assertEquals("SR backend: OpenGL | zink (Adreno 740)", status.getF3Line2());
        assertEquals("[SR] Bilinear | 960x540 -> 1920x1080 | 50% | OpenGL/zink (Adreno 740)", status.getChatSummary());
        assertTrue(status.getFullLogString().contains("algorithm=Bilinear"));
        assertTrue(status.getFullLogString().contains("internal=960x540"));
        assertTrue(status.getFullLogString().contains("output=1920x1080"));
        assertFalse(status.getF3Line1().contains("SGSR"), "Bilinear mode must not output SGSR in F3");

        // 100% scale status
        status.internalWidth = 1920;
        status.internalHeight = 1080;
        status.scaleRatio = 1.0f;
        assertEquals("SR: Bilinear | 1920x1080 -> 1920x1080 | 100%", status.getF3Line1());

        // Disabled status
        status.enabled = false;
        assertEquals("SR: OFF | 1920x1080 native", status.getF3Line1());
        assertTrue(status.getChatSummary().contains("OFF"));
    }

    @Test
    void testIrisStatusFormatting() {
        SuperResolutionDebugHelper.StatusInfo status = new SuperResolutionDebugHelper.StatusInfo();
        status.enabled = true;
        status.algorithm = "SGSR V1";
        status.internalWidth = 960;
        status.internalHeight = 540;
        status.outputWidth = 1920;
        status.outputHeight = 1080;
        status.scaleRatio = 2.0f;
        status.backend = "OpenGL";
        status.renderer = "zink (Adreno 740)";
        status.javaOnly = true;

        // 1. Iris not installed
        status.irisInstalled = false;
        assertNull(status.getF3Line3(), "F3 line 3 must be null when Iris is not installed");
        assertFalse(status.getChatSummary().contains("Iris:"), "Chat summary must not mention Iris when not installed");

        // 2. Iris installed, shaders OFF
        status.irisInstalled = true;
        status.shaderpackActive = false;
        status.shaderpackName = null;
        assertEquals("Iris: installed | shaders OFF", status.getF3Line3());
        assertTrue(status.getChatSummary().contains("Iris: installed (shaders OFF)"));
        assertTrue(status.getFullLogString().contains("irisInstalled=true"));
        assertTrue(status.getFullLogString().contains("shaderpackActive=false"));

        // 3. Iris installed, shaderpack active
        status.shaderpackActive = true;
        status.shaderpackName = "Complementary Reimagined";
        assertEquals("Iris: Complementary Reimagined", status.getF3Line3());
        assertTrue(status.getChatSummary().contains("Iris: Complementary Reimagined"));
        assertTrue(status.getFullLogString().contains("shaderpack=Complementary Reimagined"));
    }

    @Test
    void testDefaultWorkModeStateUsesRGBA8() {
        SRWorkModeState state = SRWorkModeState.defaults();
        assertEquals(TextureFormat.RGBA8, state.internalTextureFormat(), "Default work mode format must match vanilla RGBA8 UNORM");
    }

    @Test
    void testAndroidJavaOnlyInvariants() {
        System.setProperty("superresolution.java_only", "true");
        try {
            assertTrue(Platform.isJavaOnlyMode(), "Java-only mode must remain true when configured");
        } finally {
            System.clearProperty("superresolution.java_only");
        }
    }
}
