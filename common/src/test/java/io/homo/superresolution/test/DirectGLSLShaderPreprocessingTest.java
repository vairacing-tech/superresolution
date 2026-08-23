package io.homo.superresolution.test;

import io.homo.superresolution.core.graphics.impl.shader.ShaderSource;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

public class DirectGLSLShaderPreprocessingTest {

    @Test
    void testDefineInjectionBeneathVersion() {
        String baseShader = "#version 410 core\n\nvoid main() {\n    gl_Position = vec4(0.0);\n}\n";
        Map<String, String> defines = new LinkedHashMap<>();
        defines.put("UseEdgeDirection", "");
        defines.put("SR_INTERNAL_TEXTURE_FORMAT", "rgba8");

        String result = ShaderSource.addCustomDefines(baseShader, defines);

        assertTrue(result.startsWith("#version 410 core"), "Shader must start with #version directive");
        assertTrue(result.contains("#define UseEdgeDirection"), "Should contain defined flag");
        assertTrue(result.contains("#define SR_INTERNAL_TEXTURE_FORMAT rgba8"), "Should contain key-value define");
        
        // Ensure #define is before main()
        int defineIndex = result.indexOf("#define UseEdgeDirection");
        int mainIndex = result.indexOf("void main()");
        assertTrue(defineIndex < mainIndex, "Defines must be placed before main()");
    }

    @Test
    void testShaderWithoutDefinesUnmodified() {
        String baseShader = "#version 410 core\n\nvoid main() {\n}\n";
        Map<String, String> emptyDefines = new LinkedHashMap<>();
        String result = ShaderSource.addCustomDefines(baseShader, emptyDefines);
        assertTrue(result.contains("#version 410 core"));
    }
}
