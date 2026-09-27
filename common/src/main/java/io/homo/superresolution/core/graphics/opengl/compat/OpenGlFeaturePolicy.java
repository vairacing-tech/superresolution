package io.homo.superresolution.core.graphics.opengl.compat;

/** Feature decisions use numeric versions without pretending the ES backend is desktop GL. */
public final class OpenGlFeaturePolicy {
    private OpenGlFeaturePolicy() {}

    public static long resolveFunctionAddress(long declared, boolean verifiedMobileGlues,
                                               java.util.function.LongSupplier lookup) {
        return declared != 0 || !verifiedMobileGlues ? declared : lookup.getAsLong();
    }

    public static boolean atLeast(int major, int minor, int requiredMajor, int requiredMinor) {
        return major > requiredMajor || (major == requiredMajor && minor >= requiredMinor);
    }

    public static boolean immutableTexture2D(int major, int minor, boolean arbTextureStorage,
                                              boolean verifiedMobileGlues, boolean storageEntryPoint) {
        return storageEntryPoint && (atLeast(major, minor, 4, 2) || arbTextureStorage
                || (verifiedMobileGlues && atLeast(major, minor, 3, 0)));
    }

    public static boolean mobileGluesSgsr1(int major, int minor, boolean verifiedMobileGlues,
                                           boolean storage, boolean bindImage, boolean dispatch,
                                           boolean memoryBarrier) {
        // SGSR1 is raster, but its shared input/output copy uses ES 3.1 image load/store.
        return verifiedMobileGlues && atLeast(major, minor, 3, 1)
                && storage && bindImage && dispatch && memoryBarrier;
    }

    public static boolean noneAvailable(boolean verifiedMobileGlues, boolean supportsFrameGeneration) {
        return verifiedMobileGlues || supportsFrameGeneration;
    }
}
