package io.homo.superresolution.test;

import io.homo.superresolution.core.graphics.opengl.compat.OpenGlFeaturePolicy;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class OpenGlFeaturePolicyTest {
    @Test
    void mobileGluesResolvesExportHiddenByDesktopVersionTable() {
        assertEquals(123L, OpenGlFeaturePolicy.resolveFunctionAddress(0L, true, () -> 123L));
        assertEquals(0L, OpenGlFeaturePolicy.resolveFunctionAddress(0L, true, () -> 0L));
        assertEquals(456L, OpenGlFeaturePolicy.resolveFunctionAddress(456L, true,
                () -> { fail("A declared entry point must be retained"); return 0L; }));
        assertEquals(0L, OpenGlFeaturePolicy.resolveFunctionAddress(0L, false,
                () -> { fail("Desktop and unverified backends must not bypass capability discovery"); return 123L; }));
    }

    @Test
    void odinNumericEs32RequiresImmutableStorageDespiteMissingDesktop42() {
        assertTrue(OpenGlFeaturePolicy.immutableTexture2D(3, 2, false, true, true));
        assertTrue(OpenGlFeaturePolicy.mobileGluesSgsr1(3, 2, true, true, true, true, true));
    }

    @Test
    void desktopCore42AndExtensionStorageAreRecognized() {
        assertTrue(OpenGlFeaturePolicy.immutableTexture2D(4, 2, false, false, true));
        assertTrue(OpenGlFeaturePolicy.immutableTexture2D(4, 1, true, false, true));
        assertFalse(OpenGlFeaturePolicy.immutableTexture2D(4, 1, false, false, true));
        assertTrue(OpenGlFeaturePolicy.immutableTexture2D(5, 0, false, false, true));
        assertFalse(OpenGlFeaturePolicy.immutableTexture2D(4, 6, true, false, false));
    }

    @Test
    void translationProfileCannotGrantMissingImageCopyCapabilities() {
        assertFalse(OpenGlFeaturePolicy.mobileGluesSgsr1(3, 0, true, true, true, true, true));
        assertFalse(OpenGlFeaturePolicy.mobileGluesSgsr1(3, 2, true, false, true, true, true));
        assertFalse(OpenGlFeaturePolicy.mobileGluesSgsr1(3, 2, true, true, false, true, true));
        assertFalse(OpenGlFeaturePolicy.mobileGluesSgsr1(3, 2, true, true, true, false, true));
        assertFalse(OpenGlFeaturePolicy.mobileGluesSgsr1(3, 2, true, true, true, true, false));
    }

    @Test
    void unverifiedOrDisabledProfileCannotUnlockEsPath() {
        assertFalse(OpenGlFeaturePolicy.immutableTexture2D(3, 2, false, false, true));
        assertFalse(OpenGlFeaturePolicy.mobileGluesSgsr1(3, 2, false, true, true, true, true));
    }

    @Test
    void mobileGluesNoneDoesNotRequireFrameGeneration() {
        assertTrue(OpenGlFeaturePolicy.noneAvailable(true, false));
        assertFalse(OpenGlFeaturePolicy.noneAvailable(false, false));
        assertTrue(OpenGlFeaturePolicy.noneAvailable(false, true));
    }
}
