package io.homo.superresolution.test;

import com.lsfg.minecraft.LosslessDllResolver;
import com.lsfg.minecraft.LsfgNativeLoader;
import com.lsfg.minecraft.LsfgPlatform;
import io.homo.superresolution.common.framegeneration.FrameGenerationAlgorithm;
import io.homo.superresolution.common.framegeneration.FrameGenerationAlgorithmType;
import io.homo.superresolution.common.framegeneration.FrameGenerationManager;
import io.homo.superresolution.common.upscale.AlgorithmDescriptions;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.File;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

public class FrameGenerationManagerTest {

    private Path tempGameDir;

    @BeforeEach
    void setUp() {
        System.clearProperty("superresolution.lsfg_probe");
        tempGameDir = new File(System.getProperty("java.io.tmpdir"), "sgsr_test_game_dir").toPath();
        FrameGenerationManager.destroy();
    }

    @AfterEach
    void tearDown() {
        System.clearProperty("superresolution.lsfg_probe");
        FrameGenerationManager.destroy();
    }

    @Test
    void testNoneAlgorithmAlwaysAvailable() {
        FrameGenerationManager.initialize(tempGameDir);
        assertTrue(FrameGenerationManager.isAvailable(FrameGenerationAlgorithmType.NONE),
                "NONE frame generation algorithm should always be available.");
        assertEquals(FrameGenerationAlgorithmType.NONE, FrameGenerationManager.getActiveType());
    }

    @Test
    void testPlatformGuardBehavior() {
        boolean isAndroidArm64 = LsfgPlatform.isAndroidArm64();
        boolean supported = LsfgPlatform.isSupportedPlatform();
        assertEquals(isAndroidArm64, supported,
                "LsfgPlatform.isSupportedPlatform() must strictly match isAndroidArm64().");

        if (!supported) {
            FrameGenerationManager.initialize(tempGameDir);
            assertFalse(FrameGenerationManager.isAvailable(FrameGenerationAlgorithmType.LSFG),
                    "LSFG must be unavailable on unsupported platforms (e.g. desktop host test runner).");
        }
    }

    @Test
    void testProbeDefaultDisabled() {
        assertFalse(LsfgPlatform.isProbeEnabled(), "LSFG passive probe must be disabled by default.");
        FrameGenerationManager.initialize(tempGameDir);
        assertFalse(FrameGenerationManager.isProbeActive(), "Probe must be inactive when probe property is not set.");
    }

    @Test
    void testDesktopProbeDisabledEvenWithProperty() {
        if (!LsfgPlatform.isSupportedPlatform()) {
            System.setProperty("superresolution.lsfg_probe", "true");
            assertFalse(LsfgPlatform.isProbeEnabled(),
                    "LsfgPlatform.isProbeEnabled() must remain false on unsupported platforms (desktop) even when property is set.");
            FrameGenerationManager.initialize(tempGameDir);
            assertFalse(FrameGenerationManager.isProbeActive(), "Probe must not activate on desktop host.");
        }
    }

    @Test
    void testGracefulFallbackWhenLsfgUnavailable() {
        FrameGenerationManager.initialize(tempGameDir);

        if (!FrameGenerationManager.isAvailable(FrameGenerationAlgorithmType.LSFG)) {
            // Attempting to select LSFG on an unsupported platform should fall back to NONE
            FrameGenerationManager.setAlgorithm(FrameGenerationAlgorithmType.LSFG);
            assertEquals(FrameGenerationAlgorithmType.NONE, FrameGenerationManager.getActiveType(),
                    "Selecting unavailable LSFG algorithm must fall back to NONE.");
        }
    }

    @Test
    void testNativeLoaderSafetyOnDesktop() {
        if (!LsfgPlatform.isSupportedPlatform()) {
            boolean loaded = LsfgNativeLoader.load();
            assertFalse(loaded, "LsfgNativeLoader.load() must safely return false on unsupported host platforms.");
            assertNotNull(LsfgNativeLoader.getLastError(), "Error message should be set on failure.");
        }
    }

    @Test
    void testLosslessDllResolverNonExistent() {
        LosslessDllResolver.ResolutionResult res = LosslessDllResolver.resolve(tempGameDir);
        assertEquals(LosslessDllResolver.DllStatus.ABSENT, res.getStatus(),
                "Non-existent Lossless.dll must return ABSENT status without throwing.");
        assertFalse(res.isValid(), "Absent DLL must not be marked valid.");
    }

    @Test
    void testLifecycleInitDisableDestroy() {
        FrameGenerationManager.initialize(tempGameDir);
        FrameGenerationManager.setAlgorithm(FrameGenerationAlgorithmType.NONE);
        FrameGenerationAlgorithm active = FrameGenerationManager.getActiveAlgorithm();
        assertNotNull(active);
        assertEquals(FrameGenerationAlgorithmType.NONE, active.getType());

        // Test frame tick and resize no-ops
        assertDoesNotThrow(() -> FrameGenerationManager.onFrame(1));
        assertDoesNotThrow(() -> FrameGenerationManager.resize(1920, 1080));

        // Test destroy
        FrameGenerationManager.destroy();
        assertEquals(FrameGenerationAlgorithmType.NONE, FrameGenerationManager.getActiveType());
        assertFalse(FrameGenerationManager.isProbeActive());
    }

    @Test
    void testDuplicateInitializationIdempotence() {
        FrameGenerationManager.initialize(tempGameDir);
        assertDoesNotThrow(() -> FrameGenerationManager.initialize(tempGameDir));
        assertEquals(FrameGenerationAlgorithmType.NONE, FrameGenerationManager.getActiveType());
    }

    @Test
    void testDiagnosticsOutput() {
        String diagBefore = FrameGenerationManager.getDiagnostics();
        assertNotNull(diagBefore);

        FrameGenerationManager.initialize(tempGameDir);
        String diagAfter = FrameGenerationManager.getDiagnostics();
        assertNotNull(diagAfter);
        assertTrue(diagAfter.contains("Active: None"));
        assertTrue(diagAfter.contains("Probe active: false"));
    }

    @Test
    void testSgsr1BaselineUnaffected() {
        // Explicitly verify that SGSR1 algorithm description is available and intact
        assertNotNull(AlgorithmDescriptions.SGSR1, "AlgorithmDescriptions.SGSR1 must remain defined and non-null.");
        assertEquals("sgsr1", AlgorithmDescriptions.SGSR1.codeName);
        assertNotNull(AlgorithmDescriptions.BILINEAR, "AlgorithmDescriptions.BILINEAR must remain defined.");
    }
}
