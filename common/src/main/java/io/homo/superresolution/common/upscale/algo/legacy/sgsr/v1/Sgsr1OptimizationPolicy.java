package io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1;

import io.homo.superresolution.core.graphics.impl.texture.*;
import io.homo.superresolution.core.graphics.opengl.GlState;

/** Conservative, per-frame decisions for the built-in spatial SGSR1 path. */
public final class Sgsr1OptimizationPolicy {
    public record Plan(boolean reducedState, boolean auxiliaryInputs, boolean directColor) {}

    private Sgsr1OptimizationPolicy() {}

    public static Plan select(boolean builtInSgsr1, boolean externalConsumers, boolean auxiliaryConsumer,
                              boolean boundedOperations, boolean reduceState, boolean skipAuxiliary,
                              boolean directColor, boolean compatibleColor) {
        if (!builtInSgsr1 || externalConsumers || auxiliaryConsumer) return new Plan(false, true, false);
        return new Plan(reduceState && boundedOperations, !skipAuxiliary, directColor && compatibleColor);
    }

    public static boolean canBorrowColor(TextureDescription source, long sourceHandle, long outputHandle,
                                         long destinationHandle, int width, int height, TextureFormat format) {
        if (source == null || sourceHandle <= 0 || outputHandle <= 0 || destinationHandle <= 0
                || sourceHandle == outputHandle || sourceHandle == destinationHandle) return false;
        // Restrict borrowing to storage formats whose copy is an identity conversion.
        if (format != TextureFormat.RGBA8 && format != TextureFormat.RGBA16F && format != TextureFormat.RGBA32F) return false;
        return source.getType() == TextureType.Texture2D && source.getFormat() == format
                && source.getWidth() == width && source.getHeight() == height
                && source.getUsages().getUsages().contains(TextureUsage.Sampler)
                && source.getFilterMode() == TextureFilterMode.Nearest
                && source.getWrapMode() == TextureWrapMode.ClampToEdge
                && !source.getMipmapSettings().isEnabled();
    }

    public static long stateMask(boolean copiesInputs) {
        long mask = GlState.STATE_PROGRAM | GlState.STATE_VAO | GlState.STATE_VBO
                | GlState.STATE_READ_FBO | GlState.STATE_DRAW_FBO | GlState.STATE_TEXTURE
                | GlState.STATE_ACTIVE_TEXTURE | GlState.STATE_TEXTURES | GlState.STATE_VIEWPORT
                | GlState.STATE_CULL_FACE_ENABLE | GlState.STATE_FRONT_FACE | GlState.STATE_DEPTH_TEST
                | GlState.STATE_DEPTH_MASK | GlState.STATE_SCISSOR_TEST | GlState.STATE_UNIFORM_BUFFER
                | GlState.STATE_SAMPLERS | GlState.STATE_UNIFORM_BUFFER0 | GlState.STATE_STENCIL_TEST
                | GlState.STATE_POLYGON_MODE | GlState.STATE_DEPTH_CLAMP | GlState.STATE_RASTERIZER_DISCARD
                | GlState.STATE_DRAW_BUFFER0;
        return copiesInputs ? mask | GlState.STATE_IMAGE0 : mask;
    }
}
