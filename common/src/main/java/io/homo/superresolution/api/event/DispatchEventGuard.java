package io.homo.superresolution.api.event;

import net.neoforged.bus.api.Event;
import net.neoforged.bus.api.EventPriority;
import net.neoforged.bus.api.IEventBus;

import java.util.function.Consumer;

/** Keeps the existing event API while detecting registrations we cannot bound.
 * The flag is deliberately sticky: removing a listener is not proof that all
 * indirect consumers or registrations made by that extension have disappeared.
 */
public final class DispatchEventGuard implements IEventBus {
    private final IEventBus delegate;
    private volatile boolean externalListeners;

    public DispatchEventGuard(IEventBus delegate) { this.delegate = delegate; }

    public boolean hasExternalListeners() { return externalListeners; }

    /** Reserved for built-in listeners whose GL mutations and input needs were audited. */
    public <T extends Event> void addAuditedListener(Class<T> type, Consumer<T> listener) {
        delegate.addListener(type, listener);
    }

    @Override public void register(Object target) { externalListeners = true; delegate.register(target); }
    @Override public <T extends Event> void addListener(Consumer<T> listener) {
        externalListeners = true; delegate.addListener(listener);
    }
    @Override public <T extends Event> void addListener(Class<T> type, Consumer<T> listener) {
        externalListeners = true; delegate.addListener(type, listener);
    }
    @Override public <T extends Event> void addListener(EventPriority priority, Consumer<T> listener) {
        externalListeners = true; delegate.addListener(priority, listener);
    }
    @Override public <T extends Event> void addListener(EventPriority priority, Class<T> type, Consumer<T> listener) {
        externalListeners = true; delegate.addListener(priority, type, listener);
    }
    @Override public <T extends Event> void addListener(EventPriority priority, boolean canceled, Consumer<T> listener) {
        externalListeners = true; delegate.addListener(priority, canceled, listener);
    }
    @Override public <T extends Event> void addListener(EventPriority priority, boolean canceled, Class<T> type, Consumer<T> listener) {
        externalListeners = true; delegate.addListener(priority, canceled, type, listener);
    }
    @Override public <T extends Event> void addListener(boolean canceled, Consumer<T> listener) {
        externalListeners = true; delegate.addListener(canceled, listener);
    }
    @Override public <T extends Event> void addListener(boolean canceled, Class<T> type, Consumer<T> listener) {
        externalListeners = true; delegate.addListener(canceled, type, listener);
    }
    @Override public void unregister(Object target) { delegate.unregister(target); }
    @Override public <T extends Event> T post(T event) { return delegate.post(event); }
    @Override public <T extends Event> T post(EventPriority phase, T event) { return delegate.post(phase, event); }
    @Override public void start() { delegate.start(); }
}
