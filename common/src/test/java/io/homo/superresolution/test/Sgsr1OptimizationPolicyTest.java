package io.homo.superresolution.test;

import io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1.Sgsr1OptimizationPolicy;
import io.homo.superresolution.core.graphics.impl.texture.*;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class Sgsr1OptimizationPolicyTest {
    @Test
    void switchesAreIndependentIncludingAllOffBaseline() {
        for (int flags = 0; flags < 8; flags++) {
            boolean state = (flags & 1) != 0, auxiliary = (flags & 2) != 0, color = (flags & 4) != 0;
            var plan = Sgsr1OptimizationPolicy.select(true, false, false, true, state, auxiliary, color, true);
            assertEquals(state, plan.reducedState());
            assertEquals(!auxiliary, plan.auxiliaryInputs());
            assertEquals(color, plan.directColor());
        }
    }

    @Test
    void otherAlgorithmsAndUnboundedConsumersAlwaysKeepLegacyInputsAndState() {
        assertLegacy(Sgsr1OptimizationPolicy.select(false, false, false, true, true, true, true, true));
        assertLegacy(Sgsr1OptimizationPolicy.select(true, true, false, true, true, true, true, true));
        assertLegacy(Sgsr1OptimizationPolicy.select(true, false, true, true, true, true, true, true));
    }

    @Test
    void handAndUnboundedCopiesDisableOnlyReducedState() {
        var plan = Sgsr1OptimizationPolicy.select(true, false, false, false, true, true, true, true);
        assertFalse(plan.reducedState());
        assertFalse(plan.auxiliaryInputs());
        assertTrue(plan.directColor());
    }

    @Test
    void incompatibleColorFallsBackWithoutDisablingOtherOptimizations() {
        var plan = Sgsr1OptimizationPolicy.select(true, false, false, true, true, true, true, false);
        assertTrue(plan.reducedState());
        assertFalse(plan.auxiliaryInputs());
        assertFalse(plan.directColor());
    }

    @Test
    void borrowingRequiresMatchingStorageAndDistinctLiveImages() {
        TextureDescription source = color(TextureFormat.RGBA16F, 960, 540);
        assertTrue(compatible(source, 12, 13, 14, TextureFormat.RGBA16F));
        assertFalse(compatible(source, 0, 13, 14, TextureFormat.RGBA16F));
        assertFalse(compatible(source, 12, 12, 14, TextureFormat.RGBA16F));
        assertFalse(compatible(source, 12, 13, 12, TextureFormat.RGBA16F));
        assertFalse(compatible(source, 12, 0, 14, TextureFormat.RGBA16F));
        assertFalse(compatible(source, 12, 13, 14, TextureFormat.RGBA8), "Preserve necessary format conversion");
        assertFalse(compatible(color(TextureFormat.RGBA16F, 1920, 1080), 12, 13, 14, TextureFormat.RGBA16F));
        assertFalse(compatible(null, 12, 13, 14, TextureFormat.RGBA16F));
    }

    @Test
    void borrowingRejectsSamplingDifferences() {
        var source = TextureDescription.create().size(960, 540).format(TextureFormat.RGBA8)
                .type(TextureType.Texture2D).usages(TextureUsages.create().sampler())
                .filterMode(TextureFilterMode.Linear).build();
        assertFalse(compatible(source, 12, 13, 14, TextureFormat.RGBA8));
        source = TextureDescription.create().size(960, 540).format(TextureFormat.RGBA8)
                .type(TextureType.Texture2D).usages(TextureUsages.create().sampler())
                .wrapMode(TextureWrapMode.Repeat).build();
        assertFalse(compatible(source, 12, 13, 14, TextureFormat.RGBA8));
    }

    private static boolean compatible(TextureDescription source, long input, long output, long destination, TextureFormat format) {
        return Sgsr1OptimizationPolicy.canBorrowColor(source, input, output, destination, 960, 540, format);
    }

    private static TextureDescription color(TextureFormat format, int width, int height) {
        return TextureDescription.create().size(width, height).format(format).type(TextureType.Texture2D)
                .usages(TextureUsages.create().sampler().attachmentColor()).build();
    }

    private static void assertLegacy(Sgsr1OptimizationPolicy.Plan plan) {
        assertFalse(plan.reducedState());
        assertTrue(plan.auxiliaryInputs());
        assertFalse(plan.directColor());
    }
}
