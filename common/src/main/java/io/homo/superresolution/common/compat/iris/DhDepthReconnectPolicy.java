package io.homo.superresolution.common.compat.iris;

/** Determines which existing DH framebuffer depth attachments need reconnecting. */
public final class DhDepthReconnectPolicy {
    public record Reconnect(boolean terrain, boolean water) {}

    private DhDepthReconnectPolicy() {}

    public static Reconnect evaluate(Integer terrainDepth, Integer waterDepth, int requestedDepth) {
        return new Reconnect(
                terrainDepth != null && terrainDepth != requestedDepth,
                waterDepth != null && waterDepth != requestedDepth
        );
    }
}
