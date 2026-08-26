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

import io.homo.superresolution.api.platform.OperatingSystemType;
import io.homo.superresolution.api.platform.SystemArchitecture;

import java.io.File;

public final class LsfgPlatform {

    public enum OsType {
        ANDROID,
        LINUX,
        WINDOWS,
        MACOS,
        UNKNOWN
    }

    public enum ArchType {
        ARM64,
        X86_64,
        ARM32,
        X86,
        UNKNOWN
    }

    private static final OsType CURRENT_OS = detectOs();
    private static final ArchType CURRENT_ARCH = detectArch();

    private LsfgPlatform() {}

    public static OsType getOs() {
        return CURRENT_OS;
    }

    public static ArchType getArch() {
        return CURRENT_ARCH;
    }

    public static boolean isAndroidArm64() {
        return CURRENT_OS == OsType.ANDROID && CURRENT_ARCH == ArchType.ARM64;
    }

    public static boolean isSupportedPlatform() {
        return isAndroidArm64();
    }

    public static boolean isProbeEnabled() {
        if (!isSupportedPlatform()) {
            return false;
        }

        String prop = System.getProperty("superresolution.lsfg_probe");
        if (prop != null && (prop.equalsIgnoreCase("true") || prop.equals("1"))) {
            return true;
        }

        return false;
    }

    private static OsType detectOs() {
        if (OperatingSystemType.get() == OperatingSystemType.ANDROID) {
            return OsType.ANDROID;
        }

        String javaVendor = System.getProperty("java.vendor", "").toLowerCase();
        String vmVendor = System.getProperty("java.vm.vendor", "").toLowerCase();
        String osName = System.getProperty("os.name", "").toLowerCase();

        if (javaVendor.contains("android") || vmVendor.contains("android") ||
                System.getenv("ANDROID_ROOT") != null ||
                System.getenv("POJAV_NATIVEDIR") != null ||
                System.getenv("AMETHYST_RENDERER") != null ||
                new File("/system/build.prop").exists() ||
                new File("/system/bin/app_process").exists()) {
            return OsType.ANDROID;
        }

        if (osName.contains("win")) {
            return OsType.WINDOWS;
        } else if (osName.contains("mac") || osName.contains("darwin")) {
            return OsType.MACOS;
        } else if (osName.contains("linux")) {
            return OsType.LINUX;
        }

        return OsType.UNKNOWN;
    }

    private static ArchType detectArch() {
        if (SystemArchitecture.get() == SystemArchitecture.AARCH64) {
            return ArchType.ARM64;
        }

        String arch = System.getProperty("os.arch", "").toLowerCase();
        if (arch.contains("aarch64") || arch.contains("arm64") || arch.contains("armv8")) {
            return ArchType.ARM64;
        } else if (arch.contains("x86_64") || arch.contains("amd64")) {
            return ArchType.X86_64;
        } else if (arch.contains("arm")) {
            return ArchType.ARM32;
        } else if (arch.contains("x86") || arch.contains("i386") || arch.contains("i686")) {
            return ArchType.X86;
        }
        return ArchType.UNKNOWN;
    }
}
