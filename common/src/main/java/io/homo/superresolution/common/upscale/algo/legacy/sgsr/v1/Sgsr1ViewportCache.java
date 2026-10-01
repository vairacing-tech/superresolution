package io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1;

/** Tracks the input dimensions successfully uploaded to this SGSR1 instance's UBO. */
public final class Sgsr1ViewportCache {
    private int width;
    private int height;
    private boolean valid;

    /** Invalidate before a write: OpenGL may mutate the UBO before a later command fails. */
    public boolean beginUpload(int inputWidth, int inputHeight) {
        if (valid && width == inputWidth && height == inputHeight) return false;
        valid = false;
        return true;
    }

    public void uploaded(int inputWidth, int inputHeight) {
        width = inputWidth;
        height = inputHeight;
        valid = true;
    }

    public void invalidate() {
        valid = false;
    }
}
