package io.homo.superresolution.core.graphics.opengl.compat;

import io.homo.superresolution.common.SuperResolution;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GL42;
import org.lwjgl.opengl.GL43;
import org.lwjgl.opengl.GLCapabilities;
import org.lwjgl.system.JNI;

/** The active MobileGlues provider exports ES functions omitted by desktop capability tables. */
public final class MobileGluesGlFunctions {
    private record Functions(GLCapabilities caps, long storage, long image, long dispatch, long barrier) {}
    private static final ThreadLocal<Functions> functions = new ThreadLocal<>();

    private MobileGluesGlFunctions() {}

    private static long resolve(long declared, String name) {
        return OpenGlFeaturePolicy.resolveFunctionAddress(declared, true,
                () -> GL.getFunctionProvider().getFunctionAddress(name));
    }

    private static Functions current() {
        if (!MobileGluesRuntime.isVerifiedMobileGlues()) {
            throw new IllegalStateException("Direct ES entry points require verified MobileGlues");
        }
        var caps = GL.getCapabilities();
        var result = functions.get();
        if (result == null || result.caps() != caps) {
            result = new Functions(caps, resolve(caps.glTexStorage2D, "glTexStorage2D"),
                    resolve(caps.glBindImageTexture, "glBindImageTexture"),
                    resolve(caps.glDispatchCompute, "glDispatchCompute"),
                    resolve(caps.glMemoryBarrier, "glMemoryBarrier"));
            functions.set(result);
            SuperResolution.LOGGER.info(
                    "[MobileGlues] resolved functions storage={} image={} dispatch={} barrier={}; LWJGL table storage={} image={} dispatch={} barrier={}",
                    result.storage() != 0, result.image() != 0, result.dispatch() != 0, result.barrier() != 0,
                    caps.glTexStorage2D != 0, caps.glBindImageTexture != 0,
                    caps.glDispatchCompute != 0, caps.glMemoryBarrier != 0);
        }
        return result;
    }

    public static long textureStorage2DAddress() {
        return MobileGluesRuntime.isVerifiedMobileGlues() ? current().storage() : GL.getCapabilities().glTexStorage2D;
    }

    public static boolean hasImageCopyFunctions() {
        var f = current();
        return f.image() != 0 && f.dispatch() != 0 && f.barrier() != 0;
    }

    private static long require(long address, String name) {
        if (address == 0) throw new IllegalStateException("MobileGlues does not export " + name);
        return address;
    }

    public static void textureStorage2D(int target, int levels, int format, int width, int height) {
        if (MobileGluesRuntime.isVerifiedMobileGlues()) {
            JNI.callV(target, levels, format, width, height, require(current().storage(), "glTexStorage2D"));
        } else {
            GL42.glTexStorage2D(target, levels, format, width, height);
        }
    }

    public static void bindImageTexture(int unit, int texture, int level, boolean layered,
                                        int layer, int access, int format) {
        if (MobileGluesRuntime.isVerifiedMobileGlues()) {
            JNI.callV(unit, texture, level, layered, layer, access, format,
                    require(current().image(), "glBindImageTexture"));
        } else {
            GL42.glBindImageTexture(unit, texture, level, layered, layer, access, format);
        }
    }

    public static void dispatchCompute(int x, int y, int z) {
        if (MobileGluesRuntime.isVerifiedMobileGlues()) {
            JNI.callV(x, y, z, require(current().dispatch(), "glDispatchCompute"));
        } else {
            GL43.glDispatchCompute(x, y, z);
        }
    }

    public static void memoryBarrier(int bits) {
        if (MobileGluesRuntime.isVerifiedMobileGlues()) {
            JNI.callV(bits, require(current().barrier(), "glMemoryBarrier"));
        } else {
            GL42.glMemoryBarrier(bits);
        }
    }
}
