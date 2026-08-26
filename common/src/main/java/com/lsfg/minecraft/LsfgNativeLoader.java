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
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

public final class LsfgNativeLoader {

    private static final String LIB_NAME = "liblsfg-minecraft.so";
    private static final String RESOURCE_PATH = "/native/android-arm64/" + LIB_NAME;

    private static String extractedPath = null;
    private static String lastError = null;

    public static String getExtractedPath() {
        return extractedPath;
    }

    public static String getLastError() {
        return lastError;
    }

    public static synchronized boolean load() {
        if (LsfgNativeBridge.isLoaded()) {
            return true;
        }

        if (!LsfgPlatform.isSupportedPlatform()) {
            lastError = "Native Frame Generation backend unsupported on this platform (" +
                LsfgPlatform.getOs() + "/" + LsfgPlatform.getArch() + ").";
            System.out.println("[LSFG] " + lastError);
            return false;
        }

        File targetDir = resolveExecutableDirectory();
        if (targetDir == null || (!targetDir.exists() && !targetDir.mkdirs())) {
            lastError = "Could not resolve a writable executable directory for native library extraction.";
            System.err.println("[LSFG] Error: " + lastError);
            return false;
        }

        File targetFile = new File(targetDir, LIB_NAME);
        extractedPath = targetFile.getAbsolutePath();

        try (InputStream in = LsfgNativeLoader.class.getResourceAsStream(RESOURCE_PATH)) {
            if (in == null) {
                lastError = "Native binary " + RESOURCE_PATH + " not found inside JAR resources.";
                System.err.println("[LSFG] Error: " + lastError);
                return false;
            }

            try (OutputStream out = new FileOutputStream(targetFile)) {
                byte[] buffer = new byte[16384];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    out.write(buffer, 0, read);
                }
                out.flush();
            }

            try {
                targetFile.setReadable(true, false);
                targetFile.setExecutable(true, false);
            } catch (Throwable ignored) {}

            System.load(targetFile.getAbsolutePath());
            LsfgNativeBridge.setLoaded(true);

            String version = LsfgNativeBridge.getNativeVersion();
            System.out.println("[LSFG] Native backend loaded: " + version);
            lastError = null;
            return true;
        } catch (Throwable t) {
            lastError = "Failed to extract or load " + LIB_NAME + ": " + t.getMessage();
            System.err.println("[LSFG] " + lastError);
            return false;
        }
    }

    private static File resolveExecutableDirectory() {
        // Priority 1: java.io.tmpdir (set to app private cache by Amethyst/Pojav)
        String tmpProp = System.getProperty("java.io.tmpdir");
        if (tmpProp != null && !tmpProp.isEmpty()) {
            File f = new File(tmpProp, "lsfg-native");
            if (f.exists() || f.mkdirs()) return f;
        }

        // Priority 2: TMPDIR environment variable
        String tmpEnv = System.getenv("TMPDIR");
        if (tmpEnv != null && !tmpEnv.isEmpty()) {
            File f = new File(tmpEnv, "lsfg-native");
            if (f.exists() || f.mkdirs()) return f;
        }

        // Priority 3: POJAV_NATIVEDIR
        String pojavNative = System.getenv("POJAV_NATIVEDIR");
        if (pojavNative != null && !pojavNative.isEmpty()) {
            File f = new File(pojavNative);
            if (f.exists() && f.canWrite()) return f;
        }

        return null;
    }
}
