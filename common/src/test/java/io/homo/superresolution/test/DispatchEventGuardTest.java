package io.homo.superresolution.test;

import io.homo.superresolution.api.event.DispatchEventGuard;
import net.neoforged.bus.api.*;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

import static org.junit.jupiter.api.Assertions.*;

public class DispatchEventGuardTest {
    public static class TestEvent extends Event {}
    public static class AnnotatedListener {
        int delivered;
        @SubscribeEvent public void receive(TestEvent event) { delivered++; }
    }

    @Test
    void auditedListenersDoNotPreventOptimizationAndReceiveEvents() {
        var guard = new DispatchEventGuard(BusBuilder.builder().build());
        AtomicInteger delivered = new AtomicInteger();
        guard.addAuditedListener(TestEvent.class, event -> delivered.incrementAndGet());
        guard.post(new TestEvent());
        assertEquals(1, delivered.get());
        assertFalse(guard.hasExternalListeners());
    }

    @Test
    void inferredListenersForceLegacyEvenWhenLaterUnregistered() {
        var guard = new DispatchEventGuard(BusBuilder.builder().build());
        AtomicInteger delivered = new AtomicInteger();
        Consumer<TestEvent> listener = event -> delivered.incrementAndGet();
        guard.addListener(listener);
        assertTrue(guard.hasExternalListeners());
        guard.post(new TestEvent());
        assertEquals(1, delivered.get());
        guard.unregister(listener);
        guard.post(new TestEvent());
        assertEquals(1, delivered.get());
        assertTrue(guard.hasExternalListeners(), "Remain conservative until restart");
    }

    @Test
    void explicitPriorityListenersForceLegacy() {
        var guard = new DispatchEventGuard(BusBuilder.builder().build());
        guard.addListener(EventPriority.LOW, true, TestEvent.class, event -> {});
        assertTrue(guard.hasExternalListeners());
    }

    @Test
    void annotatedRegistrationForcesLegacy() {
        var guard = new DispatchEventGuard(BusBuilder.builder().build());
        var listener = new AnnotatedListener();
        guard.register(listener);
        guard.post(new TestEvent());
        assertEquals(1, listener.delivered);
        assertTrue(guard.hasExternalListeners());
    }
}
