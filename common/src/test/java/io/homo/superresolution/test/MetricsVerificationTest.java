package io.homo.superresolution.test;

import io.homo.superresolution.common.metrics.MetricsAggregator;
import io.homo.superresolution.common.metrics.UpscaleGpuMetrics;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class MetricsVerificationTest {

    @BeforeEach
    void setup() {
        UpscaleGpuMetrics.getInstance().resetForTransition("test setup");
    }

    @Test
    void testEmptyMetricsState() {
        MetricsAggregator agg = new MetricsAggregator(240, 30);
        assertTrue(agg.isWarmingUp());
        assertEquals(30, agg.getWarmupRemaining());
        assertEquals(0, agg.getValidSamples());
        assertEquals(0.0, agg.getAverageGpuMs());
        assertEquals(0.0, agg.getP50GpuMs());
        assertEquals(0.0, agg.getP95GpuMs());
        assertEquals(0.0, agg.getMinGpuMs());
        assertEquals(0.0, agg.getMaxGpuMs());
        assertEquals(0.0, agg.getCpuSubmitAvgMs());
    }

    @Test
    void testWarmupFramesAreExcluded() {
        MetricsAggregator agg = new MetricsAggregator(240, 5);
        for (int i = 0; i < 5; i++) {
            agg.recordGpuSample(10.0, 1.0);
            assertTrue(agg.isWarmingUp() || i == 4);
        }
        assertFalse(agg.isWarmingUp());
        assertEquals(0, agg.getWarmupRemaining());
        assertEquals(0, agg.getValidSamples(), "Warmup samples must not be counted in validSamples");

        // First sample after warmup
        agg.recordGpuSample(0.50, 0.05);
        assertEquals(1, agg.getValidSamples());
        assertEquals(0.50, agg.getAverageGpuMs(), 0.001);
        assertEquals(0.05, agg.getCpuSubmitAvgMs(), 0.001);
    }

    @Test
    void testAverageCalculation() {
        MetricsAggregator agg = new MetricsAggregator(240, 0);
        agg.recordGpuSample(0.40, 0.04);
        agg.recordGpuSample(0.60, 0.06);
        agg.recordGpuSample(0.80, 0.08);

        assertEquals(3, agg.getValidSamples());
        assertEquals(0.60, agg.getAverageGpuMs(), 0.001);
        assertEquals(0.06, agg.getCpuSubmitAvgMs(), 0.001);
    }

    @Test
    void testMinAndMaxGpuMs() {
        MetricsAggregator agg = new MetricsAggregator(240, 0);
        agg.recordGpuSample(0.75, 0.05);
        agg.recordGpuSample(0.25, 0.02);
        agg.recordGpuSample(0.95, 0.08);
        agg.recordGpuSample(0.45, 0.03);

        assertEquals(0.25, agg.getMinGpuMs(), 0.001);
        assertEquals(0.95, agg.getMaxGpuMs(), 0.001);
    }

    @Test
    void testP50Median() {
        MetricsAggregator agg = new MetricsAggregator(240, 0);
        // Sorted: 0.1, 0.2, 0.3, 0.4, 0.5
        agg.recordGpuSample(0.3, 0.01);
        agg.recordGpuSample(0.1, 0.01);
        agg.recordGpuSample(0.5, 0.01);
        agg.recordGpuSample(0.2, 0.01);
        agg.recordGpuSample(0.4, 0.01);

        assertEquals(0.3, agg.getP50GpuMs(), 0.001);
    }

    @Test
    void testP95Percentile() {
        MetricsAggregator agg = new MetricsAggregator(100, 0);
        for (int i = 1; i <= 100; i++) {
            agg.recordGpuSample(i * 0.01, 0.01); // 0.01 to 1.00
        }
        assertEquals(100, agg.getValidSamples());
        assertEquals(0.95, agg.getP95GpuMs(), 0.01);
    }

    @Test
    void testRollingWindowEviction() {
        int window = 5;
        MetricsAggregator agg = new MetricsAggregator(window, 0);

        // Fill buffer with 1.0
        for (int i = 0; i < window; i++) {
            agg.recordGpuSample(1.0, 0.1);
        }
        assertEquals(5, agg.getValidSamples());
        assertEquals(1.0, agg.getAverageGpuMs(), 0.001);

        // Add 5 samples of 2.0 (evicting all 1.0s)
        for (int i = 0; i < window; i++) {
            agg.recordGpuSample(2.0, 0.2);
        }
        assertEquals(5, agg.getValidSamples());
        assertEquals(2.0, agg.getAverageGpuMs(), 0.001);
        assertEquals(2.0, agg.getMinGpuMs(), 0.001);
        assertEquals(2.0, agg.getMaxGpuMs(), 0.001);
    }

    @Test
    void test240ValidSamplesMeans240RealGpuSamples() {
        MetricsAggregator agg = new MetricsAggregator(240, 30);
        // Record 30 warmup frames
        for (int i = 0; i < 30; i++) {
            agg.recordGpuSample(0.5, 0.05);
        }
        assertEquals(0, agg.getValidSamples());

        // Record 240 valid GPU frames
        for (int i = 0; i < 240; i++) {
            agg.recordGpuSample(0.42, 0.04);
        }
        assertEquals(240, agg.getValidSamples(), "Exactly 240 real GPU samples must be tracked");
        assertEquals(0.42, agg.getAverageGpuMs(), 0.001);
    }

    @Test
    void testSkippedGpuQueryDoesNotReduceWarmupOrIncrementValidSamples() {
        MetricsAggregator agg = new MetricsAggregator(240, 30);
        assertEquals(30, agg.getWarmupRemaining());
        assertEquals(0, agg.getValidSamples());

        // Simulate skipped frames (calling recordCpuOnlySample instead of recordGpuSample)
        for (int i = 0; i < 10; i++) {
            agg.recordCpuOnlySample(0.04);
        }
        assertEquals(30, agg.getWarmupRemaining(), "Skipped query frames must NOT reduce warmup remaining");
        assertEquals(0, agg.getValidSamples(), "Skipped query frames must NOT increment validSamples");

        // Now record 30 real GPU samples to finish warmup
        for (int i = 0; i < 30; i++) {
            agg.recordGpuSample(0.40, 0.04);
        }
        assertEquals(0, agg.getWarmupRemaining());
        assertEquals(0, agg.getValidSamples());

        // Again simulate skipped frames after warmup
        for (int i = 0; i < 10; i++) {
            agg.recordCpuOnlySample(0.04);
        }
        assertEquals(0, agg.getValidSamples(), "Skipped query frames after warmup must NOT increment validSamples");

        // Record 1 real GPU sample
        agg.recordGpuSample(0.45, 0.045);
        assertEquals(1, agg.getValidSamples());
        assertEquals(0.45, agg.getAverageGpuMs(), 0.001);
    }

    @Test
    void testResetDiscardsPendingSlotBookkeeping() {
        UpscaleGpuMetrics metrics = UpscaleGpuMetrics.getInstance();
        metrics.checkConfigTransition("Bilinear", true, 2.0, 960, 540, 1920, 1080);
        for (int i = 0; i < 35; i++) {
            metrics.getAggregator().recordGpuSample(0.30, 0.03);
        }
        assertEquals(5, metrics.getAggregator().getValidSamples());

        // Switch to SGSR1 (triggers config transition and discardPendingQueries)
        boolean transitioned = metrics.checkConfigTransition("SGSR1", true, 2.0, 960, 540, 1920, 1080);
        assertTrue(transitioned);

        // Verify ring slots are fully cleared and current index is reset
        for (int slot = 0; slot < UpscaleGpuMetrics.QUERY_RING_SIZE; slot++) {
            assertFalse(metrics.isQuerySlotActive(slot), "All query slots must be inactive after transition");
        }
        assertEquals(0, metrics.getCurrentQueryIndex());
        assertEquals(0, metrics.getAggregator().getValidSamples(), "Valid samples must be reset to 0");
        assertTrue(metrics.getAggregator().isWarmingUp(), "Metrics must enter warmup upon transition");
    }

    @Test
    void testOutputResolutionTransitionResetsMetrics() {
        UpscaleGpuMetrics metrics = UpscaleGpuMetrics.getInstance();
        // Initial state at 1920x1080
        metrics.checkConfigTransition("SGSR1", true, 2.0, 960, 540, 1920, 1080);
        for (int i = 0; i < 35; i++) {
            metrics.getAggregator().recordGpuSample(0.42, 0.04);
        }
        assertEquals(5, metrics.getAggregator().getValidSamples());
        assertEquals(1920, metrics.getLastOutputWidth());
        assertEquals(1080, metrics.getLastOutputHeight());

        // Change ONLY output resolution to 2560x1440 (same algorithm, scale, and internal resolution)
        boolean transitioned = metrics.checkConfigTransition("SGSR1", true, 2.0, 960, 540, 2560, 1440);
        assertTrue(transitioned, "Output resolution change must trigger a config transition");
        assertTrue(metrics.getAggregator().isWarmingUp(), "Metrics must enter warmup upon output resolution transition");
        assertEquals(0, metrics.getAggregator().getValidSamples(), "Valid samples must be reset upon output resolution transition");
        assertEquals(2560, metrics.getLastOutputWidth());
        assertEquals(1440, metrics.getLastOutputHeight());
    }

    @Test
    void testTargetRecreationExplicitReset() {
        UpscaleGpuMetrics metrics = UpscaleGpuMetrics.getInstance();
        metrics.checkConfigTransition("SGSR1", true, 2.0, 960, 540, 1920, 1080);
        for (int i = 0; i < 35; i++) {
            metrics.getAggregator().recordGpuSample(0.40, 0.03);
        }
        assertEquals(5, metrics.getAggregator().getValidSamples());

        // Explicit target recreation reset
        metrics.resetForTransition("SR targets recreated");
        assertTrue(metrics.getAggregator().isWarmingUp());
        assertEquals(0, metrics.getAggregator().getValidSamples());
        for (int slot = 0; slot < UpscaleGpuMetrics.QUERY_RING_SIZE; slot++) {
            assertFalse(metrics.isQuerySlotActive(slot));
        }
    }

    @Test
    void testPerSlotCpuGpuCorrelation() {
        MetricsAggregator agg = new MetricsAggregator(10, 0);
        double[] pendingCpu = new double[6];

        // Simulate Query 0 submit
        pendingCpu[0] = 0.035;
        // Simulate Query 1 submit
        pendingCpu[1] = 0.048;

        // Query 0 completes later with 0.41 ms GPU time -> records with pendingCpu[0]
        agg.recordGpuSample(0.41, pendingCpu[0]);
        // Query 1 completes later with 0.52 ms GPU time -> records with pendingCpu[1]
        agg.recordGpuSample(0.52, pendingCpu[1]);

        assertEquals(2, agg.getValidSamples());
        assertEquals(0.465, agg.getAverageGpuMs(), 0.001);
        assertEquals(0.0415, agg.getCpuSubmitAvgMs(), 0.0001);
    }
}