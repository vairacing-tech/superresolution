package com.lsfg.minecraft;

import org.junit.jupiter.api.Test;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.jupiter.api.Assertions.*;

class LsfgContentHistoryTest {
    @Test void enteringChangingAndLeavingScreensNotifySynchronously() {
        AtomicInteger calls = new AtomicInteger();
        LsfgContentHistory history = new LsfgContentHistory(() -> true, () -> {
            calls.incrementAndGet(); return 0;
        });
        Object options = new Object(), language = new Object();
        history.onScreenChange(null, options);
        assertEquals(1, calls.get());
        history.onScreenChange(options, language); // Same Java class, different identity.
        assertEquals(2, calls.get());
        history.onScreenChange(language, null);
        assertEquals(3, calls.get());
    }

    @Test void stableScreenAndFrameDoNotResetHistory() {
        AtomicInteger calls = new AtomicInteger();
        LsfgContentHistory history = new LsfgContentHistory(() -> true, () -> {
            calls.incrementAndGet(); return 0;
        });
        Object screen = new Object();
        history.onScreenChange(null, null);
        history.onScreenChange(screen, screen);
        history.flushPending();
        assertEquals(0, calls.get());
        history.onScreenChange(null, screen);
        history.flushPending();
        history.flushPending();
        assertEquals(1, calls.get());
    }

    @Test void earlyChangesCoalesceAndSurviveUntilBridgeIsReady() {
        AtomicBoolean loaded = new AtomicBoolean();
        AtomicInteger calls = new AtomicInteger();
        LsfgContentHistory history = new LsfgContentHistory(loaded::get, () -> {
            calls.incrementAndGet(); return 0;
        });
        Object a = new Object(), b = new Object();
        history.onScreenChange(null, a);
        history.onScreenChange(a, b);
        history.onScreenChange(b, b);
        assertEquals(0, calls.get());
        loaded.set(true);
        history.flushPending();
        history.flushPending();
        assertEquals(1, calls.get());
    }

    @Test void missingInterposerDoesNotDiscardPendingChange() {
        AtomicInteger calls = new AtomicInteger();
        LsfgContentHistory history = new LsfgContentHistory(() -> true,
                () -> calls.incrementAndGet() == 1 ? -100 : 0);
        history.onScreenChange(null, new Object());
        assertEquals(1, calls.get());
        history.flushPending();
        history.flushPending();
        assertEquals(2, calls.get());
    }

    @Test void oldJniLibraryDoesNotCrashOrThrowOnEveryFrame() {
        AtomicInteger calls = new AtomicInteger();
        LsfgContentHistory history = new LsfgContentHistory(() -> true, () -> {
            calls.incrementAndGet(); throw new UnsatisfiedLinkError("older bridge");
        });
        assertDoesNotThrow(() -> history.onScreenChange(null, new Object()));
        history.flushPending();
        history.onScreenChange(null, new Object());
        assertEquals(1, calls.get());
    }
}
