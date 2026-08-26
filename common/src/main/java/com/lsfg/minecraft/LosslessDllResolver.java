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
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.file.Path;
import java.security.MessageDigest;

public final class LosslessDllResolver {

    public enum DllStatus {
        ABSENT,
        NOT_A_FILE,
        UNREADABLE,
        INVALID_PE_HEADER,
        VALID
    }

    public static final class ResolutionResult {
        private final DllStatus status;
        private final File file;
        private final String sha256;
        private final String message;

        public ResolutionResult(DllStatus status, File file, String sha256, String message) {
            this.status = status;
            this.file = file;
            this.sha256 = sha256;
            this.message = message;
        }

        public DllStatus getStatus() { return status; }
        public File getFile() { return file; }
        public String getSha256() { return sha256; }
        public String getMessage() { return message; }
        public boolean isValid() { return status == DllStatus.VALID; }
    }

    private LosslessDllResolver() {}

    public static ResolutionResult resolve(Path gameDir) {
        Path modsDir = gameDir != null ? gameDir.resolve("mods") : new File("mods").toPath();
        Path dllPath = modsDir.resolve("Lossless.dll");
        File dllFile = dllPath.toFile();

        if (!dllFile.exists()) {
            return new ResolutionResult(
                DllStatus.ABSENT,
                dllFile,
                null,
                "Lossless.dll not found in mods/ directory."
            );
        }

        if (!dllFile.isFile()) {
            return new ResolutionResult(
                DllStatus.NOT_A_FILE,
                dllFile,
                null,
                "mods/Lossless.dll is a directory or special file, not a regular file."
            );
        }

        if (!dllFile.canRead()) {
            return new ResolutionResult(
                DllStatus.UNREADABLE,
                dllFile,
                null,
                "mods/Lossless.dll is not readable (permission denied)."
            );
        }

        // Validate PE header in read-only mode
        if (!validatePeHeader(dllFile)) {
            return new ResolutionResult(
                DllStatus.INVALID_PE_HEADER,
                dllFile,
                null,
                "mods/Lossless.dll is not a valid Windows PE/DLL executable."
            );
        }

        // Compute SHA-256 without modifying the file
        String sha256 = computeSha256(dllFile);
        if (sha256 == null) {
            return new ResolutionResult(
                DllStatus.UNREADABLE,
                dllFile,
                null,
                "Failed to compute SHA-256 of mods/Lossless.dll."
            );
        }

        return new ResolutionResult(
            DllStatus.VALID,
            dllFile,
            sha256,
            "Valid Lossless.dll verified (SHA-256: " + sha256.substring(0, Math.min(12, sha256.length())) + "...)."
        );
    }

    private static boolean validatePeHeader(File file) {
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            if (raf.length() < 0x40) {
                return false;
            }

            // Check DOS magic 'MZ' (0x5A4D in LE)
            byte[] dosMagic = new byte[2];
            raf.readFully(dosMagic);
            if (dosMagic[0] != 'M' || dosMagic[1] != 'Z') {
                return false;
            }

            // Read e_lfanew offset at 0x3C (4 bytes LE)
            raf.seek(0x3C);
            byte[] peOffsetBytes = new byte[4];
            raf.readFully(peOffsetBytes);
            int peOffset = (peOffsetBytes[0] & 0xFF) |
                          ((peOffsetBytes[1] & 0xFF) << 8) |
                          ((peOffsetBytes[2] & 0xFF) << 16) |
                          ((peOffsetBytes[3] & 0xFF) << 24);

            if (peOffset <= 0 || peOffset + 4 > raf.length()) {
                return false;
            }

            // Check PE signature 'PE\0\0' (0x50, 0x45, 0x00, 0x00)
            raf.seek(peOffset);
            byte[] peSignature = new byte[4];
            raf.readFully(peSignature);
            return peSignature[0] == 'P' &&
                   peSignature[1] == 'E' &&
                   peSignature[2] == 0 &&
                   peSignature[3] == 0;
        } catch (Throwable t) {
            return false;
        }
    }

    private static String computeSha256(File file) {
        try (InputStream in = new FileInputStream(file)) {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[16384];
            int read;
            while ((read = in.read(buffer)) != -1) {
                md.update(buffer, 0, read);
            }
            byte[] digest = md.digest();
            StringBuilder sb = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                sb.append(String.format("%02x", b & 0xFF));
            }
            return sb.toString();
        } catch (Throwable t) {
            return null;
        }
    }
}
