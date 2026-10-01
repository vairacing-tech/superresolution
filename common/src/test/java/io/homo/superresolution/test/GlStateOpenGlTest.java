package io.homo.superresolution.test;

import io.homo.superresolution.core.graphics.opengl.GlState;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1.Sgsr1OptimizationPolicy;
import io.homo.superresolution.core.graphics.impl.texture.*;
import org.lwjgl.opengl.GL;
import javax.tools.ToolProvider;
import java.nio.file.Files;
import java.nio.file.Path;
import java.net.URLClassLoader;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;
import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.opengl.GL45.*;

/** Opt-in tests against a real, hidden desktop GL context, not a game session. */
class GlStateOpenGlTest {
    private static long window;
    private static Class<?> stateClass;
    @TempDir static Path fixture;
    private static URLClassLoader loader;

    @BeforeAll
    static void createContext() throws Exception {
        assumeTrue(Boolean.getBoolean("superresolution.test.opengl"), "Enable with -Ptest_opengl=true");
        assertTrue(glfwInit(), "GLFW initialization");
        glfwDefaultWindowHints();
        glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
        glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
        glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
        glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
        window = glfwCreateWindow(32, 32, "SGSR state validation", 0, 0);
        assertNotEquals(0, window, "Hidden GL 4.3 context");
        glfwMakeContextCurrent(window);
        GL.createCapabilities();
        System.out.println("SGSR GL validation: " + glGetString(GL_RENDERER) + " / " + glGetString(GL_VERSION));
        // Only debug markers are stubbed: production GlState bytecode and all GL calls
        // are real. GlDebug otherwise initializes the entire Minecraft config/platform.
        Path debug = fixture.resolve("GlDebug.java");
        Files.writeString(debug, "package io.homo.superresolution.core.graphics.opengl; public class GlDebug {"
                + "public static int nextStateId(){return 0;} public static void pushGroup(int i,String s){}"
                + "public static void popGroup(){} }");
        assertEquals(0, ToolProvider.getSystemJavaCompiler().run(null, null, null, "-d", fixture.toString(), debug.toString()));
        ClassLoader parent = GlStateOpenGlTest.class.getClassLoader();
        loader = new URLClassLoader(new java.net.URL[]{fixture.toUri().toURL()}, parent) {
            @Override
            protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                if (name.equals("io.homo.superresolution.core.graphics.opengl.GlDebug")) return findClass(name);
                if (name.equals("io.homo.superresolution.core.graphics.opengl.GlState")) {
                    try (var in = parent.getResourceAsStream(name.replace('.', '/') + ".class")) {
                        byte[] bytes = in.readAllBytes();
                        return defineClass(name, bytes, 0, bytes.length);
                    } catch (java.io.IOException ex) { throw new ClassNotFoundException(name, ex); }
                }
                return super.loadClass(name, resolve);
            }
        };
        stateClass = loader.loadClass("io.homo.superresolution.core.graphics.opengl.GlState");
    }

    @AfterAll
    static void destroyContext() throws Exception {
        if (loader != null) loader.close();
        if (window != 0) {
            GL.setCapabilities(null);
            glfwDestroyWindow(window);
            glfwTerminate();
        }
    }

    @Test
    void restoresOriginallyUnboundTextureUnitsAndActiveUnit() throws Exception {
        int texture = glGenTextures();
        try {
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, 0);
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D, 0);
            glActiveTexture(GL_TEXTURE7);
            try (AutoCloseable ignored = save(GlState.STATE_TEXTURES | GlState.STATE_ACTIVE_TEXTURE, 2)) {
                glActiveTexture(GL_TEXTURE0);
                glBindTexture(GL_TEXTURE_2D, texture);
                glActiveTexture(GL_TEXTURE1);
                glBindTexture(GL_TEXTURE_2D, texture);
            }
            assertEquals(GL_TEXTURE7, glGetInteger(GL_ACTIVE_TEXTURE));
            glActiveTexture(GL_TEXTURE0);
            assertEquals(0, glGetInteger(GL_TEXTURE_BINDING_2D), "Unit zero must be unbound again");
            glActiveTexture(GL_TEXTURE1);
            assertEquals(0, glGetInteger(GL_TEXTURE_BINDING_2D), "Unit one must be unbound again");
            assertEquals(GL_NO_ERROR, glGetError());
        } finally {
            glDeleteTextures(texture);
        }
    }

    private static AutoCloseable save(long mask, int units) throws Exception {
        return (AutoCloseable) stateClass.getConstructor(long.class, int.class).newInstance(mask, units);
    }

    @Test
    void restoresSamplerImageAndIndexedUniformRangeWithoutLosingGenericBinding() throws Exception {
        int sampler = glGenSamplers(), texture = glGenTextures();
        int indexed = glGenBuffers(), generic = glGenBuffers(), replacement = glGenBuffers();
        int alignment = glGetInteger(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT);
        try {
            glBindTexture(GL_TEXTURE_2D, texture);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, 4, 4, 0, GL_RGBA, GL_FLOAT, (java.nio.ByteBuffer) null);
            glBindImageTexture(0, texture, 0, false, 0, GL_READ_ONLY, GL_RGBA16F);
            glBindSampler(0, sampler);
            glBindSampler(1, 0);
            glBindBuffer(GL_UNIFORM_BUFFER, indexed);
            glBufferData(GL_UNIFORM_BUFFER, alignment + 64L, GL_STATIC_DRAW);
            glBindBufferRange(GL_UNIFORM_BUFFER, 0, indexed, alignment, 64);
            glBindBuffer(GL_UNIFORM_BUFFER, generic);
            try (AutoCloseable ignored = save(Sgsr1OptimizationPolicy.stateMask(true), 2)) {
                glBindSampler(0, 0);
                glBindSampler(1, sampler);
                glBindImageTexture(0, 0, 0, false, 0, GL_READ_WRITE, GL_RGBA8);
                glBindBufferBase(GL_UNIFORM_BUFFER, 0, replacement);
            }
            assertEquals(sampler, glGetIntegeri(GL_SAMPLER_BINDING, 0));
            assertEquals(0, glGetIntegeri(GL_SAMPLER_BINDING, 1));
            assertEquals(texture, glGetIntegeri(GL_IMAGE_BINDING_NAME, 0));
            assertEquals(GL_READ_ONLY, glGetIntegeri(GL_IMAGE_BINDING_ACCESS, 0));
            assertEquals(GL_RGBA16F, glGetIntegeri(GL_IMAGE_BINDING_FORMAT, 0));
            assertEquals(indexed, glGetIntegeri(GL_UNIFORM_BUFFER_BINDING, 0));
            assertEquals(alignment, glGetInteger64i(GL_UNIFORM_BUFFER_START, 0));
            assertEquals(64, glGetInteger64i(GL_UNIFORM_BUFFER_SIZE, 0));
            assertEquals(generic, glGetInteger(GL_UNIFORM_BUFFER_BINDING));
            assertEquals(GL_NO_ERROR, glGetError());
        } finally {
            glBindSampler(0, 0); glBindSampler(1, 0);
            glBindImageTexture(0, 0, 0, false, 0, GL_READ_WRITE, GL_RGBA8);
            glBindBufferBase(GL_UNIFORM_BUFFER, 0, 0);
            glDeleteSamplers(sampler); glDeleteTextures(texture);
            glDeleteBuffers(indexed); glDeleteBuffers(generic); glDeleteBuffers(replacement);
        }
    }

    @Test
    void restoresPipelineCapsAndDrawBufferZeroWithoutChangingOtherDrawBuffers() throws Exception {
        glEnable(GL_STENCIL_TEST); glEnable(GL_DEPTH_CLAMP); glEnable(GL_RASTERIZER_DISCARD);
        glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
        glEnablei(GL_BLEND, 0); glDisablei(GL_BLEND, 1);
        glColorMaski(0, false, true, false, true);
        glColorMaski(1, true, false, true, false);
        int[] originalPolygon = new int[2]; glGetIntegerv(GL_POLYGON_MODE, originalPolygon);
        assertEquals(GL_LINE, originalPolygon[0]);
        assertEquals(GL_NO_ERROR, glGetError(), "Seed pipeline state");
        System.out.println("Initial polygon mode: " + java.util.Arrays.toString(originalPolygon));
        try (AutoCloseable ignored = save(Sgsr1OptimizationPolicy.stateMask(false), 2)) {
            glDisable(GL_STENCIL_TEST); glDisable(GL_DEPTH_CLAMP); glDisable(GL_RASTERIZER_DISCARD);
            glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
            glDisablei(GL_BLEND, 0); glColorMaski(0, true, true, true, true);
        }
        assertEquals(GL_NO_ERROR, glGetError(), "Restore pipeline state");
        assertTrue(glIsEnabled(GL_STENCIL_TEST));
        assertTrue(glIsEnabled(GL_DEPTH_CLAMP));
        assertTrue(glIsEnabled(GL_RASTERIZER_DISCARD));
        int[] polygon = new int[2]; glGetIntegerv(GL_POLYGON_MODE, polygon);
        assertArrayEquals(originalPolygon, polygon);
        assertTrue(glIsEnabledi(GL_BLEND, 0));
        assertFalse(glIsEnabledi(GL_BLEND, 1));
        int[] mask = new int[4]; glGetIntegeri_v(GL_COLOR_WRITEMASK, 0, mask);
        assertArrayEquals(new int[]{0, 1, 0, 1}, mask);
        glGetIntegeri_v(GL_COLOR_WRITEMASK, 1, mask);
        assertArrayEquals(new int[]{1, 0, 1, 0}, mask);
        assertEquals(GL_NO_ERROR, glGetError());
        glDisable(GL_STENCIL_TEST); glDisable(GL_DEPTH_CLAMP); glDisable(GL_RASTERIZER_DISCARD);
        glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
        glDisablei(GL_BLEND, 0); glColorMaski(0, true, true, true, true); glColorMaski(1, true, true, true, true);
    }

    @Test
    void directAndCopiedColorProduceIdenticalSgsrPixels() throws Exception {
        String vertex = shaderSource("/shader/sgsr/v1/sgsr1_shader.vert.glsl");
        String fragment = defines(shaderSource("/shader/sgsr/v1/sgsr1_shader.frag.glsl"), "#define UseEdgeDirection\n");
        int sgsr = program(new int[]{GL_VERTEX_SHADER, GL_FRAGMENT_SHADER}, vertex, fragment);
        int vao = glGenVertexArrays(), vertices = glGenBuffers(), ubo = glGenBuffers(), fbo = glGenFramebuffers();
        final int inputW = 31, inputH = 19, outputW = 57, outputH = 35;
        try {
            glBindVertexArray(vao); glBindBuffer(GL_ARRAY_BUFFER, vertices);
            glBufferData(GL_ARRAY_BUFFER, new float[]{-1,-1,0,0, 1,-1,1,0, -1,1,0,1, 1,1,1,1}, GL_STATIC_DRAW);
            glVertexAttribPointer(0, 2, GL_FLOAT, false, 16, 0); glEnableVertexAttribArray(0);
            glVertexAttribPointer(1, 2, GL_FLOAT, false, 16, 8); glEnableVertexAttribArray(1);
            glBindBuffer(GL_UNIFORM_BUFFER, ubo);
            glBufferData(GL_UNIFORM_BUFFER, new float[]{1f/inputW, 1f/inputH, inputW, inputH}, GL_STATIC_DRAW);
            glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);
            glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE); glDisable(GL_SCISSOR_TEST);
            glDisable(GL_STENCIL_TEST); glDisable(GL_RASTERIZER_DISCARD); glDisable(GL_DEPTH_CLAMP);
            glDisablei(GL_BLEND, 0); glColorMaski(0, true, true, true, true); glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
            float[] pattern = new float[inputW * inputH * 4];
            for (int y = 0; y < inputH; y++) for (int x = 0; x < inputW; x++) {
                int p = (y * inputW + x) * 4;
                pattern[p] = ((x / 3 + y / 2) & 1) == 0 ? 0.02f : 0.95f;
                pattern[p+1] = (float) x / (inputW - 1);
                pattern[p+2] = (float) y / (inputH - 1);
                pattern[p+3] = ((x + y) % 7) / 6f;
            }
            for (TextureFormat format : new TextureFormat[]{TextureFormat.RGBA8, TextureFormat.RGBA16F, TextureFormat.RGBA32F}) {
                int source = texture(format.gl(), inputW, inputH, pattern);
                int copied = texture(format.gl(), inputW, inputH, null);
                int output = texture(format.gl(), outputW, outputH, null);
                String copyDefines = "#define COPY_CHANNEL 4\n#define COPY_DST_FORMAT " + format.getGlslFormatQualifier() + "\n";
                for (int channel = 0; channel < 4; channel++) copyDefines += "#define COPY_SRC_CHANNEL" + channel + " " + channel
                        + "\n#define COPY_DST_CHANNEL" + channel + " " + channel + "\n";
                int copy = program(new int[]{GL_COMPUTE_SHADER}, defines(shaderSource("/shader/copy.comp.glsl"), copyDefines));
                try {
                    TextureDescription description = TextureDescription.create().size(inputW, inputH).format(format)
                            .type(TextureType.Texture2D).usages(TextureUsages.create().sampler().attachmentColor()).build();
                    assertTrue(Sgsr1OptimizationPolicy.canBorrowColor(description, source, output, copied, inputW, inputH, format));
                    glUseProgram(copy); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, source); glBindSampler(0, 0);
                    glBindImageTexture(0, copied, 0, false, 0, GL_WRITE_ONLY, format.gl());
                    glDispatchCompute(2, 2, 1); glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT);
                    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, output, 0);
                    assertEquals(GL_FRAMEBUFFER_COMPLETE, glCheckFramebufferStatus(GL_FRAMEBUFFER));
                    glViewport(0, 0, outputW, outputH); glUseProgram(sgsr); glBindVertexArray(vao); glBindSampler(1, 0);
                    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, copied); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
                    float[] baseline = new float[outputW * outputH * 4];
                    glReadPixels(0, 0, outputW, outputH, GL_RGBA, GL_FLOAT, baseline);
                    glBindTexture(GL_TEXTURE_2D, source); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
                    float[] direct = new float[baseline.length]; glReadPixels(0, 0, outputW, outputH, GL_RGBA, GL_FLOAT, direct);
                    assertNotEquals(baseline[0], baseline[(outputW - 1) * 4 + 1], "Pattern must produce non-uniform output");
                    assertArrayEquals(baseline, direct, "Copy versus direct pixels for " + format);
                    assertEquals(GL_NO_ERROR, glGetError(), format.toString());
                    System.out.println("SGSR copy/direct pixel equality: " + format + " " + outputW + "x" + outputH);
                } finally {
                    glDeleteProgram(copy); glDeleteTextures(source); glDeleteTextures(copied); glDeleteTextures(output);
                }
            }
        } finally {
            glBindFramebuffer(GL_FRAMEBUFFER, 0); glBindVertexArray(0); glBindBufferBase(GL_UNIFORM_BUFFER, 0, 0);
            glBindImageTexture(0, 0, 0, false, 0, GL_READ_WRITE, GL_RGBA8);
            glDeleteProgram(sgsr); glDeleteFramebuffers(fbo); glDeleteVertexArrays(vao); glDeleteBuffers(vertices); glDeleteBuffers(ubo);
        }
    }

    private static String shaderSource(String path) throws Exception {
        try (var stream = GlStateOpenGlTest.class.getResourceAsStream(path)) {
            assertNotNull(stream, path);
            return new String(stream.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        }
    }

    private static String defines(String source, String definitions) {
        int versionEnd = source.indexOf('\n') + 1;
        return source.substring(0, versionEnd) + definitions + source.substring(versionEnd);
    }

    private static int program(int[] types, String... sources) {
        int program = glCreateProgram();
        for (int i = 0; i < types.length; i++) {
            int shader = glCreateShader(types[i]); glShaderSource(shader, sources[i]); glCompileShader(shader);
            assertEquals(GL_TRUE, glGetShaderi(shader, GL_COMPILE_STATUS), glGetShaderInfoLog(shader));
            glAttachShader(program, shader); glDeleteShader(shader);
        }
        glLinkProgram(program); assertEquals(GL_TRUE, glGetProgrami(program, GL_LINK_STATUS), glGetProgramInfoLog(program));
        return program;
    }

    private static int texture(int format, int width, int height, float[] pixels) {
        int texture = glGenTextures(); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        glTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0, GL_RGBA, GL_FLOAT, pixels);
        return texture;
    }
}
