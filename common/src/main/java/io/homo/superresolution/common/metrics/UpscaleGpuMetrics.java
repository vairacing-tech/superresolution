/*
 * Super Resolution
 * Copyright (c) 2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.metrics;

import io.homo.superresolution.common.config.SuperResolutionConfig;
import io.homo.superresolution.common.minecraft.handler.RenderHandlerManager;
import org.lwjgl.opengl.GL15;
import org.lwjgl.opengl.GL33;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Arrays;
import java.util.Locale;

/**
 * High-precision, asynchronous GPU timer metrics for measuring the Super Resolution upscale and composite stage.
 * Uses an asynchronous OpenGL query ring with GL_TIME_ELAPSED to measure GPU execution time with zero CPU/GPU stall.
 */
public final class UpscaleGpuMetrics {
    private static final Logger LOGGER = LoggerFactory.getLogger("SuperResolution/Metrics");

    public static final int WINDOW_SIZE = 240;
    public static final int WARMUP_FRAMES = 30;
    public static final int QUERY_RING_SIZE = 6;

    private static final UpscaleGpuMetrics INSTANCE = new UpscaleGpuMetrics();

    public static boolean metricsEnabled = true;

    // GPU Timer state
    private boolean initialized = false;
    private boolean gpuTimerSupported = false;
    private final int[] queryIds = new int[QUERY_RING_SIZE];
    private final boolean[] queryActive = new boolean[QUERY_RING_SIZE];
    private final double[] pendingCpuSubmitMs = new double[QUERY_RING_SIZE];
    private int currentQueryIndex = 0;
    private boolean isInsideQuery = false;

    // CPU timing
    private long cpuStartTimeNano = 0;

    // Aggregator for statistical metrics
    private final MetricsAggregator aggregator = new MetricsAggregator(WINDOW_SIZE, WARMUP_FRAMES);

    // Track active config to detect transitions
    private String lastAlgorithm = "";
    private boolean lastEnabled = false;
    private double lastScale = 1.0;
    private int lastInternalWidth = 0;
    private int lastInternalHeight = 0;
    private int lastOutputWidth = 0;
    private int lastOutputHeight = 0;

    private UpscaleGpuMetrics() {
    }

    public static UpscaleGpuMetrics getInstance() {
        return INSTANCE;
    }

    public synchronized void initializeGl() {
        if (initialized) return;
        initialized = true;
        try {
            // Check if timer query is supported (OpenGL 3.3+ provides glGenQueries and GL_TIME_ELAPSED)
            gpuTimerSupported = org.lwjgl.opengl.GL.getCapabilities().OpenGL33;
            if (gpuTimerSupported) {
                GL15.glGenQueries(queryIds);
                discardPendingQueries();
                LOGGER.info("[SR-METRICS] gpuTimerSupported=true (queryRingSize={})", QUERY_RING_SIZE);
            } else {
                LOGGER.info("[SR-METRICS] gpuTimerSupported=false");
            }
        } catch (Throwable t) {
            gpuTimerSupported = false;
            LOGGER.warn("[SR-METRICS] Failed to initialize GPU timer queries: {}", t.getMessage());
        }
    }

    public synchronized void destroyGl() {
        if (!initialized) return;
        if (gpuTimerSupported) {
            try {
                GL15.glDeleteQueries(queryIds);
            } catch (Throwable ignored) {}
        }
        initialized = false;
        gpuTimerSupported = false;
        discardPendingQueries();
    }

    /**
     * Discards all outstanding query slots and pending CPU samples on a configuration/resource transition.
     * Prevents old GPU query results from contaminating the new measurement window.
     */
    public synchronized void discardPendingQueries() {
        Arrays.fill(queryActive, false);
        Arrays.fill(pendingCpuSubmitMs, 0.0);
        currentQueryIndex = 0;
        isInsideQuery = false;
    }

    /**
     * Explicitly reset metrics due to external lifecycle transitions (e.g. target recreation).
     */
    public synchronized void resetForTransition(String reason) {
        if (aggregator.getValidSamples() > 0) {
            logMetricsSummary();
        }
        aggregator.reset();
        discardPendingQueries();
        LOGGER.info("[SR-METRICS] reset metrics due to: {}", reason);
    }

    /**
     * Checks if rendering configuration has changed and logs a summary before resetting metrics.
     */
    public synchronized boolean checkConfigTransition(String currentAlgorithm, boolean enabled, double scale,
                                                      int internalW, int internalH, int outputW, int outputH) {
        if (!currentAlgorithm.equals(lastAlgorithm)
                || enabled != lastEnabled
                || Math.abs(scale - lastScale) > 0.001
                || internalW != lastInternalWidth
                || internalH != lastInternalHeight
                || outputW != lastOutputWidth
                || outputH != lastOutputHeight) {

            // If we had valid samples recorded, print summary of previous state using PREVIOUS dimensions
            if (aggregator.getValidSamples() > 0) {
                logMetricsSummary();
            }

            this.lastAlgorithm = currentAlgorithm;
            this.lastEnabled = enabled;
            this.lastScale = scale;
            this.lastInternalWidth = internalW;
            this.lastInternalHeight = internalH;
            this.lastOutputWidth = outputW;
            this.lastOutputHeight = outputH;

            aggregator.reset();
            discardPendingQueries();
            return true;
        }
        return false;
    }

    private void logMetricsSummary() {
        LOGGER.info(
                String.format(Locale.ROOT,
                        "[SR-METRICS-SUMMARY] algorithm=%s scale=%.2f internal=%dx%d output=%dx%d samples=%d gpuAvgMs=%.3f gpuP50Ms=%.3f gpuP95Ms=%.3f gpuMinMs=%.3f gpuMaxMs=%.3f cpuSubmitAvgMs=%.3f",
                        lastAlgorithm, (1.0 / (lastScale <= 0 ? 1.0 : lastScale)), lastInternalWidth, lastInternalHeight,
                        lastOutputWidth, lastOutputHeight,
                        aggregator.getValidSamples(), aggregator.getAverageGpuMs(), aggregator.getP50GpuMs(),
                        aggregator.getP95GpuMs(), aggregator.getMinGpuMs(), aggregator.getMaxGpuMs(),
                        aggregator.getCpuSubmitAvgMs()
                )
        );
    }

    /**
     * Begins GPU timer query and CPU timestamp for the upscale/composite region.
     */
    public synchronized void beginUpscale() {
        if (!metricsEnabled) return;
        if (!initialized) {
            initializeGl();
        }

        String algo = SuperResolutionConfig.getUpscaleAlgorithm() != null ? SuperResolutionConfig.getUpscaleAlgorithm().briefName : "None";
        boolean enabled = SuperResolutionConfig.isEnableUpscale();
        double scale = SuperResolutionConfig.getUpscaleRatio();
        int internalW = RenderHandlerManager.getRenderWidth();
        int internalH = RenderHandlerManager.getRenderHeight();
        int outputW = RenderHandlerManager.getScreenWidth();
        int outputH = RenderHandlerManager.getScreenHeight();
        checkConfigTransition(algo, enabled, scale, internalW, internalH, outputW, outputH);

        cpuStartTimeNano = System.nanoTime();

        if (gpuTimerSupported) {
            try {
                // If the target query slot is still active, poll it first
                if (queryActive[currentQueryIndex]) {
                    int available = GL15.glGetQueryObjecti(queryIds[currentQueryIndex], GL15.GL_QUERY_RESULT_AVAILABLE);
                    if (available != 0) {
                        long timeElapsedNano = GL33.glGetQueryObjectui64(queryIds[currentQueryIndex], GL15.GL_QUERY_RESULT);
                        queryActive[currentQueryIndex] = false;
                        double gpuMs = timeElapsedNano / 1_000_000.0;
                        aggregator.recordGpuSample(gpuMs, pendingCpuSubmitMs[currentQueryIndex]);
                    } else {
                        // Slot is still pending, skip query this frame without stalling
                        isInsideQuery = false;
                        return;
                    }
                }

                int queryId = queryIds[currentQueryIndex];
                GL15.glBeginQuery(GL33.GL_TIME_ELAPSED, queryId);
                queryActive[currentQueryIndex] = true;
                isInsideQuery = true;
            } catch (Throwable t) {
                isInsideQuery = false;
            }
        }
    }

    /**
     * Ends GPU timer query, records CPU submit duration, and polls older asynchronous query results without blocking.
     */
    public synchronized void endUpscale() {
        if (!metricsEnabled) return;

        double cpuSubmitMs = (System.nanoTime() - cpuStartTimeNano) / 1_000_000.0;

        if (gpuTimerSupported && isInsideQuery) {
            try {
                GL15.glEndQuery(GL33.GL_TIME_ELAPSED);
            } catch (Throwable ignored) {}
            isInsideQuery = false;

            // Associate CPU submit time with the current query slot
            pendingCpuSubmitMs[currentQueryIndex] = cpuSubmitMs;

            // Advance query ring index
            currentQueryIndex = (currentQueryIndex + 1) % QUERY_RING_SIZE;

            // Poll older completed queries (non-blocking)
            pollCompletedQueries();
        } else if (!gpuTimerSupported) {
            // If GPU timer unsupported on driver, record CPU submit sample
            aggregator.recordCpuOnlySample(cpuSubmitMs);
        }
        // NOTE: If gpuTimerSupported is true but query was skipped (slot pending), do NOT record a sample.
    }

    private void pollCompletedQueries() {
        for (int i = 0; i < QUERY_RING_SIZE; i++) {
            if (i == currentQueryIndex || !queryActive[i]) continue;

            try {
                int available = GL15.glGetQueryObjecti(queryIds[i], GL15.GL_QUERY_RESULT_AVAILABLE);
                if (available != 0) {
                    long timeElapsedNano = GL33.glGetQueryObjectui64(queryIds[i], GL15.GL_QUERY_RESULT);
                    queryActive[i] = false;
                    double gpuMs = timeElapsedNano / 1_000_000.0;
                    double associatedCpuMs = pendingCpuSubmitMs[i];
                    aggregator.recordGpuSample(gpuMs, associatedCpuMs);
                }
            } catch (Throwable ignored) {
                queryActive[i] = false;
            }
        }
    }

    public synchronized boolean isGpuTimerSupported() {
        return gpuTimerSupported;
    }

    public synchronized MetricsAggregator getAggregator() {
        return aggregator;
    }

    public synchronized int getLastOutputWidth() {
        return lastOutputWidth;
    }

    public synchronized int getLastOutputHeight() {
        return lastOutputHeight;
    }

    public synchronized boolean isQuerySlotActive(int slot) {
        if (slot < 0 || slot >= QUERY_RING_SIZE) return false;
        return queryActive[slot];
    }

    public synchronized int getCurrentQueryIndex() {
        return currentQueryIndex;
    }

    public synchronized String getF3Line() {
        if (!metricsEnabled) return null;
        if (aggregator.isWarmingUp()) {
            return "SR GPU: warming up (" + aggregator.getWarmupRemaining() + ")";
        }
        if (!gpuTimerSupported) {
            return String.format(Locale.ROOT, "SR CPU submit: %.2f ms (GPU timer unsupported)", aggregator.getCpuSubmitAvgMs());
        }
        if (aggregator.getValidSamples() == 0) {
            return "SR GPU: collecting samples...";
        }
        return String.format(Locale.ROOT, "SR GPU: %.3f ms avg | p95 %.3f ms | n=%d",
                aggregator.getAverageGpuMs(), aggregator.getP95GpuMs(), aggregator.getValidSamples());
    }

    public synchronized void logStatus() {
        String algo = SuperResolutionConfig.getUpscaleAlgorithm() != null ? SuperResolutionConfig.getUpscaleAlgorithm().briefName : "None";
        int internalW = RenderHandlerManager.getRenderWidth();
        int internalH = RenderHandlerManager.getRenderHeight();
        int outputW = RenderHandlerManager.getScreenWidth();
        int outputH = RenderHandlerManager.getScreenHeight();

        if (aggregator.isWarmingUp()) {
            LOGGER.info("[SR-METRICS] algorithm={} state=warming_up remaining={}", algo, aggregator.getWarmupRemaining());
            return;
        }
        if (!gpuTimerSupported) {
            LOGGER.info(
                    String.format(Locale.ROOT, "[SR-METRICS] algorithm=%s gpuMs=unsupported cpuSubmitAvgMs=%.3f", algo, aggregator.getCpuSubmitAvgMs())
            );
            return;
        }
        LOGGER.info(
                String.format(Locale.ROOT,
                        "[SR-METRICS] algorithm=%s internal=%dx%d output=%dx%d samples=%d gpuLatestMs=%.3f gpuAvgMs=%.3f gpuP50Ms=%.3f gpuP95Ms=%.3f gpuMinMs=%.3f gpuMaxMs=%.3f cpuSubmitAvgMs=%.3f",
                        algo, internalW, internalH, outputW, outputH,
                        aggregator.getValidSamples(), aggregator.getLatestGpuMs(), aggregator.getAverageGpuMs(),
                        aggregator.getP50GpuMs(), aggregator.getP95GpuMs(), aggregator.getMinGpuMs(),
                        aggregator.getMaxGpuMs(), aggregator.getCpuSubmitAvgMs()
                )
        );
    }
}