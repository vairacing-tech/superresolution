package io.homo.superresolution.core.graphics.opengl.compat;

import io.homo.superresolution.api.platform.OperatingSystemType;
import io.homo.superresolution.api.platform.Platform;
import io.homo.superresolution.common.SuperResolution;
import io.homo.superresolution.core.graphics.GraphicsCapabilities;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GL11;

/** Captures the live OpenGL identity once and gates optional LSFG side effects. */
public final class MobileGluesRuntime {
    private static final String MODE_PROPERTY = "superresolution.mobileglues.mode";
    private static volatile MobileGluesProfile.Decision decision =
            new MobileGluesProfile.Decision(false, false, false, "Waiting for a current OpenGL context");
    private static volatile boolean initialized;

    private MobileGluesRuntime() {}

    public static synchronized boolean initializeFromCurrentContext() {
        if (initialized) {
            return true;
        }
        try {
            if (GL.getCapabilities() == null) {
                return false;
            }
            String extensions = String.join(" ", GraphicsCapabilities.getGLExtensions());
            MobileGluesProfile.Identity identity = new MobileGluesProfile.Identity(
                    OperatingSystemType.get() == OperatingSystemType.ANDROID,
                    extensions,
                    GL11.glGetString(GL11.GL_VERSION),
                    GL11.glGetString(GL11.GL_RENDERER)
            );
            String requestedMode = System.getProperty(MODE_PROPERTY);
            MobileGluesProfile.Mode mode = MobileGluesProfile.parseMode(requestedMode);
            if (requestedMode != null && !requestedMode.isBlank()
                    && !requestedMode.trim().equalsIgnoreCase(mode.name())) {
                SuperResolution.LOGGER.warn("Unknown {} value '{}'; using auto", MODE_PROPERTY, requestedMode);
            }
            decision = MobileGluesProfile.evaluate(mode, identity);
            initialized = true;
            SuperResolution.LOGGER.info(
                    "[MobileGlues] profile={} active={} supportedBackend={} allowLsfg={} reason={}; GL_VERSION='{}', GL_RENDERER='{}'",
                    mode, decision.active(), decision.supportedBackend(), decision.allowLsfg(), decision.reason(),
                    identity.glVersion(), identity.backendRenderer()
            );
            return true;
        } catch (Throwable t) {
            SuperResolution.LOGGER.warn("Could not identify the current OpenGL renderer; deferring optional LSFG setup", t);
            return false;
        }
    }

    public static MobileGluesProfile.Decision decision() {
        return decision;
    }

    public static boolean isInitialized() {
        return initialized;
    }

    public static boolean isVerifiedMobileGlues() {
        return initializeFromCurrentContext() && decision.active() && decision.supportedBackend();
    }

    public static boolean supportsImmutableTexture2D() {
        var caps = GL.getCapabilities();
        int[] version = GraphicsCapabilities.getGLVersion();
        return OpenGlFeaturePolicy.immutableTexture2D(version[0], version[1],
                caps.GL_ARB_texture_storage, isVerifiedMobileGlues(),
                MobileGluesGlFunctions.textureStorage2DAddress() != 0);
    }

    public static boolean supportsSgsr1Pipeline() {
        if (!isVerifiedMobileGlues()) {
            return false;
        }
        int[] version = GraphicsCapabilities.getGLVersion();
        boolean imageCopy = MobileGluesGlFunctions.hasImageCopyFunctions();
        return OpenGlFeaturePolicy.mobileGluesSgsr1(version[0], version[1], true,
                supportsImmutableTexture2D(), imageCopy, imageCopy, imageCopy);
    }

    public static boolean supportsSgsr1Algorithm() {
        int[] version = GraphicsCapabilities.getGLVersion();
        return OpenGlFeaturePolicy.atLeast(version[0], version[1], 4, 0) || supportsSgsr1Pipeline();
    }

    public static boolean isNoneAvailable(boolean supportsFrameGeneration) {
        return OpenGlFeaturePolicy.noneAvailable(isVerifiedMobileGlues(), supportsFrameGeneration);
    }

    /** Side effects wait for a verified renderer context, then follow its policy. */
    public static boolean isLsfgSideEffectAllowed() {
        return !Platform.isJavaOnlyMode() || (initialized && decision.allowLsfg());
    }
}
