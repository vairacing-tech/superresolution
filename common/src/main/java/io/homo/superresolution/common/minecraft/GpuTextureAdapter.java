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

package io.homo.superresolution.common.minecraft;

import io.homo.superresolution.core.graphics.impl.texture.ITexture;
#if MC_VER > MC_1_21_4
import io.homo.superresolution.core.graphics.impl.framebuffer.IFrameBuffer;
import io.homo.superresolution.core.graphics.impl.framebuffer.FrameBufferAttachmentType;
import com.mojang.blaze3d.opengl.DirectStateAccess;
import com.mojang.blaze3d.opengl.GlTexture;
import com.mojang.blaze3d.textures.AddressMode;
import com.mojang.blaze3d.textures.FilterMode;
import com.mojang.blaze3d.textures.GpuTexture;
import io.homo.superresolution.core.graphics.impl.texture.TextureFormat;

import javax.annotation.Nullable;

public class GpuTextureAdapter extends GlTexture {
    private final ITexture staticTexture;
    private final IFrameBuffer frameBuffer;
    private final FrameBufferAttachmentType attachmentType;

    public GpuTextureAdapter(IFrameBuffer frameBuffer, FrameBufferAttachmentType attachmentType) {
        #if MC_VER > MC_1_21_5
        super(
                GpuTexture.USAGE_COPY_DST |
                        GpuTexture.USAGE_COPY_SRC |
                        GpuTexture.USAGE_TEXTURE_BINDING |
                        GpuTexture.USAGE_RENDER_ATTACHMENT,
                "DynamicFbAttachment--" + attachmentType,
                #if MC_VER < MC_26_2
                resolveFormat(frameBuffer, attachmentType) != null && resolveFormat(frameBuffer, attachmentType).isDepth() ?
                        com.mojang.blaze3d.textures.TextureFormat.DEPTH32 :
                        com.mojang.blaze3d.textures.TextureFormat.RGBA8,
                #else
                toMojangGpuFormat(resolveFormat(frameBuffer, attachmentType)),
                #endif
                frameBuffer != null ? frameBuffer.getWidth() : 1,
                frameBuffer != null ? frameBuffer.getHeight() : 1,
                1,
                1,
                (int) resolveHandle(frameBuffer, attachmentType)
                #if MC_VER > MC_26_1_2
                ,(com.mojang.blaze3d.opengl.FrameBufferCache)MinecraftUtils.getFrameBufferCache()
                #endif
        );
        #else
        super(
                "DynamicFbAttachment--" + attachmentType,
                resolveFormat(frameBuffer, attachmentType) != null && resolveFormat(frameBuffer, attachmentType).isDepth() ?
                        com.mojang.blaze3d.textures.TextureFormat.DEPTH32 :
                        com.mojang.blaze3d.textures.TextureFormat.RGBA8,
                frameBuffer != null ? frameBuffer.getWidth() : 1,
                frameBuffer != null ? frameBuffer.getHeight() : 1,
                1,
                (int) resolveHandle(frameBuffer, attachmentType)
        );
        #endif
        this.frameBuffer = frameBuffer;
        this.attachmentType = attachmentType;
        this.staticTexture = null;
    }

    public GpuTextureAdapter(ITexture texture) {
        #if MC_VER > MC_1_21_5
        super(
                GpuTexture.USAGE_COPY_DST |
                        GpuTexture.USAGE_COPY_SRC |
                        GpuTexture.USAGE_TEXTURE_BINDING |
                        GpuTexture.USAGE_RENDER_ATTACHMENT,
                texture.handle() + "--" + texture.getTextureFormat(),
                #if MC_VER < MC_26_2
                texture.getTextureFormat().isDepth() ?
                        com.mojang.blaze3d.textures.TextureFormat.DEPTH32 :
                        com.mojang.blaze3d.textures.TextureFormat.RGBA8,
                #else
                toMojangGpuFormat(texture.getTextureFormat()),
                #endif
                texture.getWidth(),
                texture.getHeight(),
                1,
                texture.getTextureDescription().getMipmapSettings().getLevels(),
                (int) texture.handle()
                #if MC_VER > MC_26_1_2
                ,(com.mojang.blaze3d.opengl.FrameBufferCache)MinecraftUtils.getFrameBufferCache()
                #endif
        );
        #else
        super(texture.handle() + "--" + texture.getTextureFormat(),
                texture.getTextureFormat().isDepth() ?
                        com.mojang.blaze3d.textures.TextureFormat.DEPTH32 :
                        com.mojang.blaze3d.textures.TextureFormat.RGBA8,
                texture.getWidth(),
                texture.getHeight(),
                texture.getTextureDescription().getMipmapSettings().getLevels(),
                (int) texture.handle()
        );
        #endif
        this.staticTexture = texture;
        this.frameBuffer = null;
        this.attachmentType = null;
    }

    private static TextureFormat resolveFormat(IFrameBuffer frameBuffer, FrameBufferAttachmentType attachmentType) {
        if (frameBuffer == null || attachmentType == null) {
            return TextureFormat.RGBA8;
        }
        ITexture tex = frameBuffer.getTexture(attachmentType);
        if (tex == null && (attachmentType == FrameBufferAttachmentType.Depth || attachmentType == FrameBufferAttachmentType.DepthStencil || attachmentType == FrameBufferAttachmentType.AnyDepth)) {
            tex = frameBuffer.getTexture(FrameBufferAttachmentType.DepthStencil);
            if (tex == null) {
                tex = frameBuffer.getTexture(FrameBufferAttachmentType.Depth);
            }
        }
        if (tex != null) {
            return tex.getTextureFormat();
        }
        if (attachmentType == FrameBufferAttachmentType.Depth || attachmentType == FrameBufferAttachmentType.DepthStencil || attachmentType == FrameBufferAttachmentType.AnyDepth) {
            TextureFormat fbDepthFmt = frameBuffer.getDepthTextureFormat();
            return fbDepthFmt != null ? fbDepthFmt : TextureFormat.DEPTH32F;
        }
        return TextureFormat.RGBA8;
    }

    private static long resolveHandle(IFrameBuffer frameBuffer, FrameBufferAttachmentType attachmentType) {
        if (frameBuffer == null || attachmentType == null) {
            return -1;
        }
        ITexture tex = frameBuffer.getTexture(attachmentType);
        if (tex == null && (attachmentType == FrameBufferAttachmentType.Depth || attachmentType == FrameBufferAttachmentType.DepthStencil || attachmentType == FrameBufferAttachmentType.AnyDepth)) {
            tex = frameBuffer.getTexture(FrameBufferAttachmentType.DepthStencil);
            if (tex == null) {
                tex = frameBuffer.getTexture(FrameBufferAttachmentType.Depth);
            }
        }
        return tex != null ? tex.handle() : -1;
    }

    public ITexture currentTexture() {
        if (frameBuffer != null && attachmentType != null) {
            ITexture tex = frameBuffer.getTexture(attachmentType);
            if (tex == null && (attachmentType == FrameBufferAttachmentType.Depth || attachmentType == FrameBufferAttachmentType.DepthStencil || attachmentType == FrameBufferAttachmentType.AnyDepth)) {
                tex = frameBuffer.getTexture(FrameBufferAttachmentType.DepthStencil);
                if (tex == null) {
                    tex = frameBuffer.getTexture(FrameBufferAttachmentType.Depth);
                }
            }
            return tex;
        }
        return staticTexture;
    }

    public int getWidth(int mipLevel) {
        if (frameBuffer != null) {
            return frameBuffer.getWidth();
        }
        ITexture tex = currentTexture();
        return tex != null ? tex.getWidth() : 0;
    }

    public int getHeight(int mipLevel) {
        if (frameBuffer != null) {
            return frameBuffer.getHeight();
        }
        ITexture tex = currentTexture();
        return tex != null ? tex.getHeight() : 0;
    }

    public int getWidth() {
        if (frameBuffer != null) {
            return frameBuffer.getWidth();
        }
        ITexture tex = currentTexture();
        return tex != null ? tex.getWidth() : 0;
    }

    public int getHeight() {
        if (frameBuffer != null) {
            return frameBuffer.getHeight();
        }
        ITexture tex = currentTexture();
        return tex != null ? tex.getHeight() : 0;
    }

    #if MC_VER >= MC_26_2
    @Override
    public com.mojang.blaze3d.GpuFormat getFormat() {
        ITexture tex = currentTexture();
        if (tex != null && tex.getTextureFormat() != null) {
            return toMojangGpuFormat(tex.getTextureFormat());
        }
        return super.getFormat();
    }

    public static com.mojang.blaze3d.GpuFormat toMojangGpuFormat(TextureFormat format) {
        if (format == null) return com.mojang.blaze3d.GpuFormat.RGBA8_UNORM;
        return switch (format) {
            case DEPTH32F -> com.mojang.blaze3d.GpuFormat.D32_FLOAT;
            case DEPTH32F_STENCIL8 -> com.mojang.blaze3d.GpuFormat.D32_FLOAT_S8_UINT;
            case DEPTH24_STENCIL8 -> com.mojang.blaze3d.GpuFormat.D24_UNORM_S8_UINT;
            case DEPTH24, DEPTH32, DEPTH_COMPONENT -> com.mojang.blaze3d.GpuFormat.D32_FLOAT;
            case RGBA16F -> com.mojang.blaze3d.GpuFormat.RGBA16_FLOAT;
            case RGBA32F -> com.mojang.blaze3d.GpuFormat.RGBA32_FLOAT;
            default -> com.mojang.blaze3d.GpuFormat.RGBA8_UNORM;
        };
    }
    #endif

    public static GlTexture ofTexture(ITexture texture) {
        return new GpuTextureAdapter(texture);
    }

    public static GlTexture ofAttachment(IFrameBuffer frameBuffer, FrameBufferAttachmentType attachmentType) {
        return new GpuTextureAdapter(frameBuffer, attachmentType);
    }

    public GpuTextureAdapter bindFramebuffer(IFrameBuffer frameBuffer) {
        return this;
    }

    @Override
    public void close() {
        if (staticTexture != null && !this.closed) {
            this.closed = true;
        }
    }

    @Override
    public boolean isClosed() {
        if (staticTexture != null) {
            return this.closed;
        }
        return frameBuffer == null || frameBuffer.handle() <= 0;
    }

    public int getFbo(DirectStateAccess directStateAccess,
                      @Nullable
                      GpuTexture gpuTexture) {
        return Math.toIntExact(frameBuffer != null ? frameBuffer.handle() : -1);
    }

    public void flushModeChanges() {

    }

    @Override
    public int glId() {
        ITexture tex = currentTexture();
        return tex != null ? Math.toIntExact(tex.handle()) : -1;
    }

    public void setAddressMode(AddressMode addressMode, AddressMode addressMode2) {
    }

    public void setTextureFilter(FilterMode filterMode, FilterMode filterMode2, boolean bl) {
    }

    #if MC_VER > MC_1_21_5
    @Override
    public int usage() {
        return
                GpuTexture.USAGE_COPY_DST | GpuTexture.USAGE_COPY_SRC | GpuTexture.USAGE_TEXTURE_BINDING | GpuTexture.USAGE_RENDER_ATTACHMENT;
    }
    #endif
}

#else
public class GpuTextureAdapter {
    private final ITexture texture;

    GpuTextureAdapter(ITexture texture) {

        this.texture = texture;
    }

    public static Object ofTexture(ITexture texture) {
        return new GpuTextureAdapter(texture);
    }
}
#endif
