package io.homo.superresolution.test;

import io.homo.superresolution.api.registry.AlgorithmDescription;
import io.homo.superresolution.api.registry.AlgorithmRegistry;
import io.homo.superresolution.common.upscale.AlgorithmDescriptions;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

public class AlgorithmRegistryFilteringTest {

    @BeforeEach
    @AfterEach
    void cleanup() {
        System.clearProperty("superresolution.java_only");
        AlgorithmRegistry.getAlgorithmMap().clear();
        AlgorithmDescriptions.registryAlgorithms();
    }

    @Test
    void testAlgorithmRegistryFilteringInJavaOnlyMode() {
        System.setProperty("superresolution.java_only", "true");
        AlgorithmRegistry.getAlgorithmMap().clear();
        AlgorithmDescriptions.registryAlgorithms();

        Map<String, AlgorithmDescription<?>> algorithms = AlgorithmRegistry.getAlgorithmMap();
        assertNotNull(algorithms);
        assertFalse(algorithms.isEmpty());

        Set<String> registeredCodes = algorithms.keySet();

        // NONE and SGSR1 must be present
        assertTrue(registeredCodes.contains("none"), "NONE algorithm must be registered in Java-only mode");
        assertTrue(registeredCodes.contains("sgsr1"), "SGSR1 algorithm must be registered in Java-only mode");

        // Native algorithms must NOT be registered
        assertFalse(registeredCodes.contains("fsr1"), "FSR1 must not be registered in Java-only mode");
        assertFalse(registeredCodes.contains("fsr2"), "FSR2 must not be registered in Java-only mode");
        assertFalse(registeredCodes.contains("fsr"), "FSR (native) must not be registered in Java-only mode");
        assertFalse(registeredCodes.contains("fsr4_d3d12"), "FSR4 must not be registered in Java-only mode");
        assertFalse(registeredCodes.contains("xess"), "XeSS must not be registered in Java-only mode");
        assertFalse(registeredCodes.contains("dlss"), "DLSS must not be registered in Java-only mode");
        assertFalse(registeredCodes.contains("sgsr2"), "SGSR2 must not be registered in Java-only mode");
    }
}
