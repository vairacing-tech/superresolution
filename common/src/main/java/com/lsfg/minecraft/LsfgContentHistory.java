package com.lsfg.minecraft;

import java.util.function.BooleanSupplier;
import java.util.function.IntSupplier;

/** Marks content cuts independently of the user's frame-generation settings. */
public final class LsfgContentHistory {
    private static final LsfgContentHistory INSTANCE = new LsfgContentHistory(
            LsfgNativeBridge::isLoaded, LsfgNativeBridge::notifyContentDiscontinuity);

    private final BooleanSupplier bridgeLoaded;
    private final IntSupplier notifyNative;
    private boolean pending;
    private boolean unsupported;

    LsfgContentHistory(BooleanSupplier bridgeLoaded, IntSupplier notifyNative) {
        this.bridgeLoaded = bridgeLoaded;
        this.notifyNative = notifyNative;
    }

    public static void screenChanged(Object previous, Object next) {
        INSTANCE.onScreenChange(previous, next);
    }

    /** Retry an early cut once the native bridge becomes available. */
    public static void flushBeforeFrame() {
        INSTANCE.flushPending();
    }

    synchronized void onScreenChange(Object previous, Object next) {
        if (previous != next && !unsupported) {
            pending = true;
            flushPending();
        }
    }

    synchronized void flushPending() {
        if (!pending || !bridgeLoaded.getAsBoolean()) return;
        try {
            // A missing interposer export returns -100: keep the cut pending.
            if (notifyNative.getAsInt() == 0) pending = false;
        } catch (UnsatisfiedLinkError oldNativeLibrary) {
            // Older/desktop libraries must not turn a menu change into a crash.
            unsupported = true;
            pending = false;
            System.err.println("[LSFG] Native bridge lacks content-history notifications.");
        }
    }
}
