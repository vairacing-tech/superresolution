package io.homo.superresolution.test;

import io.homo.superresolution.api.platform.OperatingSystemType;
import io.homo.superresolution.api.platform.Platform;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class AndroidJavaOnlyModeTest {

    @AfterEach
    void cleanup() {
        System.clearProperty("superresolution.java_only");
    }

    @Test
    void testSystemPropertyEnablesJavaOnlyMode() {
        System.setProperty("superresolution.java_only", "true");
        assertTrue(Platform.isJavaOnlyMode(), "Java-only mode should be active when -Dsuperresolution.java_only=true");
    }

    @Test
    void testSystemPropertyDisabled() {
        System.setProperty("superresolution.java_only", "false");
        if (OperatingSystemType.get() != OperatingSystemType.ANDROID) {
            assertFalse(Platform.isJavaOnlyMode(), "Java-only mode should be false on non-Android when property is false");
        }
    }
}
