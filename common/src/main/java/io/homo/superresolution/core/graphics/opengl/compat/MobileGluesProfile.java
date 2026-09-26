package io.homo.superresolution.core.graphics.opengl.compat;

import java.util.Objects;

/** Pure policy for opting into the MobileGlues-specific SGSR runtime safeguards. */
public final class MobileGluesProfile {
    public enum Mode {
        AUTO,
        COMPAT,
        OFF
    }

    public record Identity(boolean android, String extensions, String glVersion, String backendRenderer) {
        public Identity {
            extensions = Objects.requireNonNullElse(extensions, "");
            glVersion = Objects.requireNonNullElse(glVersion, "");
            backendRenderer = Objects.requireNonNullElse(backendRenderer, "");
        }
    }

    public record Decision(boolean active, boolean supportedBackend, boolean allowLsfg, String reason) {}

    private MobileGluesProfile() {}

    public static Mode parseMode(String value) {
        if (value == null || value.isBlank()) {
            return Mode.AUTO;
        }
        try {
            return Mode.valueOf(value.trim().toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException ignored) {
            return Mode.AUTO;
        }
    }

    public static Decision evaluate(Mode mode, Identity identity) {
        Objects.requireNonNull(mode, "mode");
        Objects.requireNonNull(identity, "identity");

        String allIdentity = (identity.glVersion() + " " + identity.backendRenderer()).toLowerCase(java.util.Locale.ROOT);
        boolean angle = allIdentity.contains("angle");
        boolean mobileGlues = hasExtension(identity.extensions(), "GL_MG_mobileglues")
                || allIdentity.contains("mobileglues");
        boolean supportedBackend = identity.android() && mobileGlues && !angle;

        if (angle) {
            return new Decision(false, false, true, "ANGLE is outside the direct MobileGlues profile");
        }
        if (mode == Mode.OFF) {
            return new Decision(false, supportedBackend, true, "MobileGlues compatibility profile disabled");
        }
        if (mode == Mode.COMPAT && identity.android()) {
            return new Decision(true, supportedBackend, false,
                    supportedBackend ? "MobileGlues detected; compatibility safeguards enabled"
                            : "Android compatibility override enabled; backend identity is not verified");
        }
        if (supportedBackend) {
            return new Decision(true, true, false, "MobileGlues detected on Android");
        }
        if (!identity.android()) {
            return new Decision(false, false, true, "MobileGlues profile is Android-only");
        }
        return new Decision(false, false, true, "MobileGlues was not detected");
    }

    private static boolean hasExtension(String extensions, String expected) {
        for (String extension : extensions.split("\\s+")) {
            if (expected.equalsIgnoreCase(extension)) {
                return true;
            }
        }
        return false;
    }
}
