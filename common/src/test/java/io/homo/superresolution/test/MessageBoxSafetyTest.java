package io.homo.superresolution.test;

import io.homo.superresolution.core.utils.MessageBox;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class MessageBoxSafetyTest {

    @BeforeEach
    @AfterEach
    void cleanup() {
        System.clearProperty("superresolution.java_only");
    }

    @Test
    void testMessageBoxDoesNotThrowInJavaOnlyMode() {
        System.setProperty("superresolution.java_only", "true");

        // In Java-only mode, these must safely log via SLF4J and not invoke TinyFileDialogs
        assertDoesNotThrow(() -> MessageBox.createError("Test error message", "Test Error"));
        assertDoesNotThrow(() -> MessageBox.createWarn("Test warn message", "Test Warning"));
        assertDoesNotThrow(() -> MessageBox.createInfo("Test info message", "Test Info"));
    }
}
