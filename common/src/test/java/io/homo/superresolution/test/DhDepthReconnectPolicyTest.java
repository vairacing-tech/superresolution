package io.homo.superresolution.test;

import io.homo.superresolution.common.compat.iris.DhDepthReconnectPolicy;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class DhDepthReconnectPolicyTest {
    @Test
    void reconnectsOnlyPresentFramebufferWhoseDepthChanged() {
        assertEquals(new DhDepthReconnectPolicy.Reconnect(false, false), DhDepthReconnectPolicy.evaluate(null, null, 8));
        assertEquals(new DhDepthReconnectPolicy.Reconnect(true, false), DhDepthReconnectPolicy.evaluate(4, null, 8));
        assertEquals(new DhDepthReconnectPolicy.Reconnect(false, true), DhDepthReconnectPolicy.evaluate(null, 4, 8));
        assertEquals(new DhDepthReconnectPolicy.Reconnect(false, false), DhDepthReconnectPolicy.evaluate(8, 8, 8));
        assertEquals(new DhDepthReconnectPolicy.Reconnect(true, true), DhDepthReconnectPolicy.evaluate(4, 5, 8));
        assertEquals(new DhDepthReconnectPolicy.Reconnect(true, false), DhDepthReconnectPolicy.evaluate(4, 8, 8));
        assertEquals(new DhDepthReconnectPolicy.Reconnect(false, true), DhDepthReconnectPolicy.evaluate(8, 4, 8));
    }
}
