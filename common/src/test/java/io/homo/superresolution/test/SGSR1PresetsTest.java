package io.homo.superresolution.test;

import io.homo.superresolution.api.QualityPreset;
import io.homo.superresolution.common.upscale.AlgorithmDescriptions;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

public class SGSR1PresetsTest {

    @Test
    void testSGSR1QualityPresetsAndCustomRatio() {
        assertTrue(AlgorithmDescriptions.SGSR1.isCustomUpscaleRatio(), "SGSR1 must support custom upscale ratios");

        List<QualityPreset> presets = AlgorithmDescriptions.SGSR1.getQualityPresets();
        assertNotNull(presets);
        assertEquals(3, presets.size(), "SGSR1 must define exactly 3 quality presets (50%, 45%, 40%)");

        // Preset 1: 50%
        QualityPreset p50 = presets.get(0);
        assertEquals("sgsr1_50", p50.getCodeName());
        assertEquals("50%", p50.getName().getString());
        assertEquals(2.0f, p50.getUpscaleRatio(), 0.0001f);

        // Preset 2: 45%
        QualityPreset p45 = presets.get(1);
        assertEquals("sgsr1_45", p45.getCodeName());
        assertEquals("45%", p45.getName().getString());
        assertEquals(1.0f / 0.45f, p45.getUpscaleRatio(), 0.0001f);

        // Preset 3: 40%
        QualityPreset p40 = presets.get(2);
        assertEquals("sgsr1_40", p40.getCodeName());
        assertEquals("40%", p40.getName().getString());
        assertEquals(2.5f, p40.getUpscaleRatio(), 0.0001f);
    }

    @Test
    void testCalculatedDimensionsAt1080p() {
        int screenW = 1920;
        int screenH = 1080;

        List<QualityPreset> presets = AlgorithmDescriptions.SGSR1.getQualityPresets();

        // 50% -> 960x540
        float scale50 = 1.0f / presets.get(0).getUpscaleRatio();
        int w50 = (int) (screenW * scale50);
        int h50 = (int) (screenH * scale50);
        assertEquals(960, w50);
        assertEquals(540, h50);

        // 45% -> 864x486
        float scale45 = 1.0f / presets.get(1).getUpscaleRatio();
        int w45 = (int) (screenW * scale45);
        int h45 = (int) (screenH * scale45);
        assertEquals(864, w45);
        assertEquals(486, h45);

        // 40% -> 768x432
        float scale40 = 1.0f / presets.get(2).getUpscaleRatio();
        int w40 = (int) (screenW * scale40);
        int h40 = (int) (screenH * scale40);
        assertEquals(768, w40);
        assertEquals(432, h40);
    }
}