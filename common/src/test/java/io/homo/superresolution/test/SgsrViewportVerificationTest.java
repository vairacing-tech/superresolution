package io.homo.superresolution.test;

import io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1.SgsrViewportDimensions;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

public class SgsrViewportVerificationTest {

    @Test
    void testSgsrViewportDimensionsContract() {
        int renderW = 960;
        int renderH = 540;
        int screenW = 1920;
        int screenH = 1080;

        SgsrViewportDimensions input = SgsrViewportDimensions.input(renderW, renderH, screenW, screenH);
        SgsrViewportDimensions output = SgsrViewportDimensions.output(renderW, renderH, screenW, screenH);

        // Input dimensions must match internal render resolution (for texture sampling and ViewportInfo)
        assertEquals(960, input.getWidth());
        assertEquals(540, input.getHeight());

        // Output dimensions must match full screen resolution (for raster viewport to avoid quarter-screen regression)
        assertEquals(1920, output.getWidth());
        assertEquals(1080, output.getHeight());
    }

    @Test
    void testSgsr1SourceCodeGuaranteesExplicitOutputViewport() throws Exception {
        String sgsr1Source = Files.readString(Paths.get("src/main/java/io/homo/superresolution/common/upscale/algo/legacy/sgsr/v1/Sgsr1.java"));

        assertTrue(sgsr1Source.contains("glViewport(0, 0, outputDim.getWidth(), outputDim.getHeight())")
                || sgsr1Source.contains("glViewport(0, 0, dispatchResource.screenWidth(), dispatchResource.screenHeight())"),
                "Sgsr1.dispatch must explicitly set glViewport to output/screen dimensions");

        assertTrue(sgsr1Source.contains("commandBuffer.setViewport(0, 0, outputDim.getWidth(), outputDim.getHeight())")
                || sgsr1Source.contains("commandBuffer.setViewport(0, 0, dispatchResource.screenWidth(), dispatchResource.screenHeight())"),
                "Sgsr1.dispatch must set commandBuffer viewport to output/screen dimensions");

        assertTrue(sgsr1Source.contains("glDisable(org.lwjgl.opengl.GL11.GL_SCISSOR_TEST)"),
                "Sgsr1.dispatch must explicitly disable scissor test");
    }
}