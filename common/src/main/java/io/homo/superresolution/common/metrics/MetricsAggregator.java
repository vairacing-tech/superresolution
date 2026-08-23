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

import java.util.Arrays;

/**
 * Pure statistical container maintaining a rolling sample window for GPU and CPU metrics.
 * Designed to be completely decoupled from OpenGL APIs for direct unit testing.
 */
public class MetricsAggregator {
    private final int windowSize;
    private final int warmupCount;

    private final double[] gpuSamples;
    private final double[] cpuSamples;
    private int sampleHead = 0;
    private int validSamples = 0;
    private int warmupRemaining;

    private double latestGpuMs = 0.0;
    private double latestCpuSubmitMs = 0.0;

    public MetricsAggregator(int windowSize, int warmupCount) {
        this.windowSize = Math.max(1, windowSize);
        this.warmupCount = Math.max(0, warmupCount);
        this.gpuSamples = new double[this.windowSize];
        this.cpuSamples = new double[this.windowSize];
        this.warmupRemaining = this.warmupCount;
    }

    public synchronized void reset() {
        this.sampleHead = 0;
        this.validSamples = 0;
        this.warmupRemaining = this.warmupCount;
        this.latestGpuMs = 0.0;
        this.latestCpuSubmitMs = 0.0;
        Arrays.fill(gpuSamples, 0.0);
        Arrays.fill(cpuSamples, 0.0);
    }

    /**
     * Records a valid, completed GPU query sample and its associated CPU submission duration.
     * Only valid GPU queries (gpuMs >= 0) reduce warmup and count toward validSamples.
     */
    public synchronized void recordGpuSample(double gpuMs, double cpuMs) {
        if (gpuMs < 0.0) {
            recordCpuOnlySample(cpuMs);
            return;
        }

        this.latestGpuMs = gpuMs;
        this.latestCpuSubmitMs = cpuMs;

        if (warmupRemaining > 0) {
            warmupRemaining--;
            return;
        }

        gpuSamples[sampleHead] = gpuMs;
        cpuSamples[sampleHead] = cpuMs;
        sampleHead = (sampleHead + 1) % windowSize;
        if (validSamples < windowSize) {
            validSamples++;
        }
    }

    /**
     * Records CPU submission timing when GPU timer query is unsupported.
     * Does NOT affect GPU warmupRemaining or validSamples.
     */
    public synchronized void recordCpuOnlySample(double cpuMs) {
        this.latestCpuSubmitMs = cpuMs;
    }

    /**
     * General sample recorder for test compatibility.
     */
    public synchronized void recordSample(double gpuMs, double cpuMs) {
        if (gpuMs >= 0.0) {
            recordGpuSample(gpuMs, cpuMs);
        } else {
            recordCpuOnlySample(cpuMs);
        }
    }

    public synchronized boolean isWarmingUp() {
        return warmupRemaining > 0;
    }

    public synchronized int getWarmupRemaining() {
        return warmupRemaining;
    }

    public synchronized int getValidSamples() {
        return validSamples;
    }

    public synchronized int getWindowSize() {
        return windowSize;
    }

    public synchronized double getLatestGpuMs() {
        return latestGpuMs;
    }

    public synchronized double getLatestCpuSubmitMs() {
        return latestCpuSubmitMs;
    }

    public synchronized double getAverageGpuMs() {
        if (validSamples == 0) return 0.0;
        double sum = 0.0;
        for (int i = 0; i < validSamples; i++) {
            sum += gpuSamples[i];
        }
        return sum / validSamples;
    }

    public synchronized double getCpuSubmitAvgMs() {
        if (validSamples == 0) {
            return latestCpuSubmitMs;
        }
        double sum = 0.0;
        for (int i = 0; i < validSamples; i++) {
            sum += cpuSamples[i];
        }
        return sum / validSamples;
    }

    public synchronized double getMinGpuMs() {
        if (validSamples == 0) return 0.0;
        double min = Double.MAX_VALUE;
        for (int i = 0; i < validSamples; i++) {
            if (gpuSamples[i] < min) min = gpuSamples[i];
        }
        return min;
    }

    public synchronized double getMaxGpuMs() {
        if (validSamples == 0) return 0.0;
        double max = 0.0;
        for (int i = 0; i < validSamples; i++) {
            if (gpuSamples[i] > max) max = gpuSamples[i];
        }
        return max;
    }

    public synchronized double getPercentileGpuMs(double percentile) {
        if (validSamples == 0) return 0.0;

        double[] valid = new double[validSamples];
        System.arraycopy(gpuSamples, 0, valid, 0, validSamples);
        Arrays.sort(valid);

        int rank = (int) Math.round((percentile / 100.0) * (validSamples - 1));
        rank = Math.max(0, Math.min(validSamples - 1, rank));
        return valid[rank];
    }

    public synchronized double getP50GpuMs() {
        return getPercentileGpuMs(50.0);
    }

    public synchronized double getP95GpuMs() {
        return getPercentileGpuMs(95.0);
    }
}