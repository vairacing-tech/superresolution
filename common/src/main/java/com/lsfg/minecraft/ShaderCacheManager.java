/*
 * Super Resolution - LSFG Android Integration
 * Copyright (c) 2026. vairacing-tech / FrankBarretta
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package com.lsfg.minecraft;

import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.nio.file.Path;

public final class ShaderCacheManager {

    private static final int SCHEMA_VERSION = 1;
    private static final String EXTRACTOR_VERSION = "lsfg-mc-0.1.0";
    private static final String METADATA_FILENAME = "metadata.json";

    public enum CacheStatus {
        VALID,
        POPULATED_SUCCESSFULLY,
        EXTRACTION_FAILED,
        PROBE_FAILED,
        IO_ERROR
    }

    public static final class CacheResult {
        private final CacheStatus status;
        private final File cacheDir;
        private final String message;

        public CacheResult(CacheStatus status, File cacheDir, String message) {
            this.status = status;
            this.cacheDir = cacheDir;
            this.message = message;
        }

        public CacheStatus getStatus() { return status; }
        public File getCacheDir() { return cacheDir; }
        public String getMessage() { return message; }
        public boolean isReady() { return status == CacheStatus.VALID || status == CacheStatus.POPULATED_SUCCESSFULLY; }
    }

    private ShaderCacheManager() {}

    public static CacheResult ensureShaderCache(Path gameDir, File dllFile, String dllSha256) {
        if (dllFile == null || !dllFile.exists() || dllSha256 == null) {
            return new CacheResult(CacheStatus.IO_ERROR, null, "Invalid Lossless.dll parameters for cache.");
        }

        Path configDir = (gameDir != null ? gameDir : new File(".").toPath())
            .resolve("config")
            .resolve("superresolution")
            .resolve("lsfg_cache");
        File cacheDirFile = configDir.toFile();
        if (!cacheDirFile.exists() && !cacheDirFile.mkdirs()) {
            return new CacheResult(CacheStatus.IO_ERROR, cacheDirFile, "Failed to create cache directory: " + configDir);
        }

        File metadataFile = new File(cacheDirFile, METADATA_FILENAME);
        if (isCacheValid(metadataFile, dllSha256)) {
            return new CacheResult(CacheStatus.VALID, cacheDirFile, "Shader cache is up to date.");
        }

        // Cache is absent or stale: extract shaders from user-provided DLL
        System.out.println("[LSFG] Shader cache missing or stale. Extracting LSFG shaders from mods/Lossless.dll...");
        int extractResult = LsfgNativeBridge.validateAndExtractShaders(
            dllFile.getAbsolutePath(),
            dllSha256,
            cacheDirFile.getAbsolutePath()
        );

        if (extractResult != 0) {
            return new CacheResult(
                CacheStatus.EXTRACTION_FAILED,
                cacheDirFile,
                "Native shader extraction failed with error code: " + extractResult
            );
        }

        // Probe that shaders are accepted by the Vulkan driver
        int probeResult = LsfgNativeBridge.probeShaderCache(cacheDirFile.getAbsolutePath());
        if (probeResult != 0) {
            return new CacheResult(
                CacheStatus.PROBE_FAILED,
                cacheDirFile,
                "Vulkan shader module probing failed with error code: " + probeResult
            );
        }

        // Write metadata
        writeMetadata(metadataFile, dllSha256);

        return new CacheResult(
            CacheStatus.POPULATED_SUCCESSFULLY,
            cacheDirFile,
            "Shader cache successfully extracted and validated."
        );
    }

    private static boolean isCacheValid(File metadataFile, String expectedSha256) {
        if (!metadataFile.exists() || !metadataFile.isFile()) {
            return false;
        }

        try (FileReader reader = new FileReader(metadataFile)) {
            char[] buffer = new char[(int) metadataFile.length()];
            int read = reader.read(buffer);
            String json = new String(buffer, 0, read);

            if (!json.contains("\"schemaVersion\":" + SCHEMA_VERSION)) return false;
            if (!json.contains("\"extractorVersion\":\"" + EXTRACTOR_VERSION + "\"")) return false;
            if (!json.contains("\"dllSha256\":\"" + expectedSha256 + "\"")) return false;
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private static void writeMetadata(File metadataFile, String sha256) {
        String json = "{\n" +
            "  \"schemaVersion\": " + SCHEMA_VERSION + ",\n" +
            "  \"extractorVersion\": \"" + EXTRACTOR_VERSION + "\",\n" +
            "  \"dllSha256\": \"" + sha256 + "\",\n" +
            "  \"supportedVariants\": [\"LSFG_3_1\", \"LSFG_3_1P\", \"FP16_SPIRV\", \"FP32_SPIRV\"],\n" +
            "  \"cachedAtEpochMs\": " + System.currentTimeMillis() + "\n" +
            "}\n";

        File tempFile = new File(metadataFile.getParentFile(), METADATA_FILENAME + ".tmp");
        try (FileWriter writer = new FileWriter(tempFile)) {
            writer.write(json);
            writer.flush();
            if (metadataFile.exists()) {
                metadataFile.delete();
            }
            tempFile.renameTo(metadataFile);
        } catch (Throwable t) {
            System.err.println("[LSFG] Warning: Failed to write cache metadata: " + t.getMessage());
        }
    }
}
