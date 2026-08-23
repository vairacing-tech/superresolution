/*
 * Super Resolution
 * Copyright (c) 2025-2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1;

import io.homo.superresolution.api.AbstractAlgorithm;
import io.homo.superresolution.api.InitializationDescription;
import io.homo.superresolution.api.InputResourceType;
import io.homo.superresolution.common.config.SuperResolutionConfig;
import io.homo.superresolution.common.minecraft.handler.RenderHandlerManager;
import io.homo.superresolution.common.upscale.DispatchResource;
import io.homo.superresolution.core.RenderSystems;
import io.homo.superresolution.core.graphics.impl.FullscreenQuad;
import io.homo.superresolution.core.graphics.impl.buffer.*;
import io.homo.superresolution.core.graphics.impl.command.ICommandBuffer;
import io.homo.superresolution.core.graphics.impl.framebuffer.FramebufferDescription;
import io.homo.superresolution.core.graphics.impl.framebuffer.IFrameBuffer;
import io.homo.superresolution.core.graphics.impl.pipeline.GraphicsPipeline;
import io.homo.superresolution.core.graphics.impl.pipeline.RenderPass;
import io.homo.superresolution.core.graphics.impl.pipeline.state.ColorBlendAttachment;
import io.homo.superresolution.core.graphics.impl.pipeline.state.CullMode;
import io.homo.superresolution.core.graphics.impl.pipeline.state.DynamicStateFlags;
import io.homo.superresolution.core.graphics.impl.shader.IShaderProgram;
import io.homo.superresolution.core.graphics.impl.shader.ShaderDescription;
import io.homo.superresolution.core.graphics.impl.shader.ShaderSource;
import io.homo.superresolution.core.graphics.impl.shader.ShaderType;
import io.homo.superresolution.core.graphics.impl.texture.ITexture;
import io.homo.superresolution.core.graphics.impl.texture.TextureDescription;
import io.homo.superresolution.core.graphics.impl.texture.TextureType;
import io.homo.superresolution.core.graphics.impl.texture.TextureUsages;
import io.homo.superresolution.core.graphics.impl.vertex.IVertexBuffer;
import io.homo.superresolution.core.graphics.impl.vertex.PrimitiveType;
import io.homo.superresolution.core.graphics.opengl.pipeline.GlGraphicsPipeline;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class Sgsr1 extends AbstractAlgorithm {
    private static final Logger LOGGER = LoggerFactory.getLogger("SuperResolution/SGSR1");

    private IShaderProgram sgsrShader;
    private GraphicsPipeline sgsrPipeline;
    private RenderPass renderPass;
    private ITexture output;
    private IFrameBuffer outputFbo;
    private StructuredData buffer;
    private IBuffer ubo;
    private IVertexBuffer quadVertexBuffer;

    @Override
    public void initialize(InitializationDescription desc) {
        this.initDesc = desc;
        buffer = Std140StructBuilder.start()
                .vec4Entry("ViewportInfo")
                .build();
        ubo = RenderSystems.current().device().createBuffer(
                BufferDescription.create()
                        .usages(BufferUsages.create().ubo().transferDst())
                        .size(buffer.size())
                        .build());
        output = RenderSystems.current().device().createTexture(
                TextureDescription.create()
                        .type(TextureType.Texture2D)
                        .width(RenderHandlerManager.getScreenWidth())
                        .height(RenderHandlerManager.getScreenHeight())
                        .format(SuperResolutionConfig.getInternalTextureFormat())
                        .usages(TextureUsages.create().sampler().storage().attachmentColor())
                        .label("Sgsr1Output")
                        .build());
        outputFbo = RenderSystems.current().device().createFramebuffer(
                FramebufferDescription.create()
                        .colorAttachment(output)
                        .label("Sgsr1OutputFbo")
                        .build());
        sgsrShader = RenderSystems.current().device().createShaderProgram(
                ShaderDescription.create()
                        .vertex(ShaderSource.file(ShaderType.Vertex, "/shader/sgsr/v1/sgsr1_shader.vert.glsl"))
                        .fragment(ShaderSource.file(ShaderType.Fragment, "/shader/sgsr/v1/sgsr1_shader.frag.glsl"))
                        .name("SGSRV1")
                        .addDefine("UseEdgeDirection", "")
                        .addDefine("SR_INTERNAL_TEXTURE_FORMAT",
                                SuperResolutionConfig.getInternalTextureFormatGlslFormatQualifier())
                        .uniformBuffer("sgsr1_data", 0, (int) buffer.size())
                        .uniformSamplerTexture("ps0", 1)
                        .build());
        sgsrShader.compile();

        LOGGER.info("[SuperResolution] Algorithm: SGSR1");
        LOGGER.info("[SuperResolution] Internal render resolution: {}x{}", RenderHandlerManager.getRenderWidth(), RenderHandlerManager.getRenderHeight());
        LOGGER.info("[SuperResolution] Output resolution: {}x{}", RenderHandlerManager.getScreenWidth(), RenderHandlerManager.getScreenHeight());
        LOGGER.info("[SuperResolution] Scale factor: {}", SuperResolutionConfig.getRenderScaleFactor());

        renderPass = RenderSystems.current().device().createRenderPass(
                RenderPass.builder()
                        .frameBuffer(outputFbo)
        );
        sgsrPipeline = GlGraphicsPipeline.builder()
                .shader(sgsrShader)
                .renderPass(renderPass)
                .primitiveType(PrimitiveType.TriangleStrip)
                .rasterization(r -> r.cullMode(CullMode.None))
                .depthStencil(r -> r.depthTestEnable(false).depthWriteEnable(false).stencilTestEnable(false))
                .dynamicStates(DynamicStateFlags.Viewport)
                .colorBlend(r -> r.addAttachment(ColorBlendAttachment.noBlend()))
                .vertexFormat(FullscreenQuad.getVertexFormat())
                .build(RenderSystems.current().device());
        quadVertexBuffer = FullscreenQuad.create(RenderSystems.current().device());
    }

    @Override
    public boolean dispatch(DispatchResource dispatchResource) {
        super.dispatch(dispatchResource);

        SgsrViewportDimensions inputDim = SgsrViewportDimensions.input(
                dispatchResource.renderWidth(), dispatchResource.renderHeight(),
                dispatchResource.screenWidth(), dispatchResource.screenHeight()
        );
        SgsrViewportDimensions outputDim = SgsrViewportDimensions.output(
                dispatchResource.renderWidth(), dispatchResource.renderHeight(),
                dispatchResource.screenWidth(), dispatchResource.screenHeight()
        );

        buffer.setVec4(
                "ViewportInfo",
                1.0f / inputDim.getWidth(),
                1.0f / inputDim.getHeight(),
                (float) inputDim.getWidth(),
                (float) inputDim.getHeight()
        );
        buffer.fillBuffer();

        sgsrPipeline.descriptorSet().samplerTexture("ps0", dispatchResource.resources().get(InputResourceType.Color));
        sgsrPipeline.descriptorSet().uniformBuffer("sgsr1_data", ubo);
        sgsrPipeline.descriptorSet().update();

        // Explicit fallback bindings for OpenGL compatibility
        int progId = (int) sgsrShader.handle();
        int blockIdx = org.lwjgl.opengl.GL31.glGetUniformBlockIndex(progId, "sgsr1_data");
        if (blockIdx != org.lwjgl.opengl.GL31.GL_INVALID_INDEX) {
            org.lwjgl.opengl.GL31.glUniformBlockBinding(progId, blockIdx, 0);
        }
        org.lwjgl.opengl.GL30.glBindBufferBase(org.lwjgl.opengl.GL31.GL_UNIFORM_BUFFER, 0, (int) ubo.handle());

        // Explicit full-screen raster state for SGSR output framebuffer
        org.lwjgl.opengl.GL11.glDisable(org.lwjgl.opengl.GL11.GL_SCISSOR_TEST);
        org.lwjgl.opengl.GL11.glViewport(0, 0, outputDim.getWidth(), outputDim.getHeight());
        org.lwjgl.opengl.GL11.glDisable(org.lwjgl.opengl.GL11.GL_DEPTH_TEST);
        org.lwjgl.opengl.GL11.glDisable(org.lwjgl.opengl.GL11.GL_CULL_FACE);
        org.lwjgl.opengl.GL11.glDisable(org.lwjgl.opengl.GL11.GL_BLEND);
        org.lwjgl.opengl.GL11.glColorMask(true, true, true, true);
        org.lwjgl.opengl.GL11.glDepthMask(false);

        ICommandBuffer commandBuffer = RenderSystems.current().device().defaultCommandPool().createCommandBuffer();
        commandBuffer.begin();
        commandBuffer.writeToBuffer(ubo, 0, buffer);
        commandBuffer.setViewport(0, 0, outputDim.getWidth(), outputDim.getHeight());
        commandBuffer.beginRenderPass(renderPass);
        commandBuffer.bindPipeline(sgsrPipeline);
        commandBuffer.draw(quadVertexBuffer, quadVertexBuffer.getVertexCount(), 0);
        commandBuffer.endRenderPass();
        commandBuffer.end();
        RenderSystems.current().device().submitCommandBuffer(commandBuffer);
        return true;
    }

    @Override
    public void destroy() {
        output.destroy();
        sgsrShader.destroy();
        sgsrPipeline.destroy();
        quadVertexBuffer.destroy();
        outputFbo.destroy();
        renderPass.destroy();
        buffer.free();
        ubo.destroy();
    }

    @Override
    public void resize(int width, int height) {
        destroy();
        initialize(initDesc);
    }

    @Override
    public IFrameBuffer getOutputFrameBuffer() {
        return outputFbo;
    }

    @Override
    public int getOutputTextureId() {
        return Math.toIntExact(output.handle());
    }
}