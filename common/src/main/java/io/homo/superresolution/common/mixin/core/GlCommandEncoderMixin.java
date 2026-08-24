/*
 * Super Resolution
 * Copyright (c) 2026. 187J3X1-114514
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

package io.homo.superresolution.common.mixin.core;

import org.objectweb.asm.Opcodes;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

#if MC_VER >= MC_26_2
@Mixin(targets = "com.mojang.blaze3d.opengl.GlCommandEncoder")
public abstract class GlCommandEncoderMixin {
    @Redirect(
            method = "clearDepthTexture",
            at = @At(value = "FIELD", target = "Lcom/mojang/blaze3d/opengl/GlTexture;id:I", opcode = Opcodes.GETFIELD)
    )
    private int redirectClearDepthTextureId(com.mojang.blaze3d.opengl.GlTexture texture) {
        if (texture instanceof io.homo.superresolution.common.minecraft.GpuTextureAdapter adapter) {
            return adapter.glId();
        }
        return texture.glId();
    }

    @Redirect(
            method = "clearColorTexture",
            at = @At(value = "FIELD", target = "Lcom/mojang/blaze3d/opengl/GlTexture;id:I", opcode = Opcodes.GETFIELD)
    )
    private int redirectClearColorTextureId(com.mojang.blaze3d.opengl.GlTexture texture) {
        if (texture instanceof io.homo.superresolution.common.minecraft.GpuTextureAdapter adapter) {
            return adapter.glId();
        }
        return texture.glId();
    }

    @Redirect(
            method = "writeToTexture(Lcom/mojang/blaze3d/textures/GpuTexture;Ljava/nio/ByteBuffer;IIIIII)V",
            at = @At(value = "FIELD", target = "Lcom/mojang/blaze3d/opengl/GlTexture;id:I", opcode = Opcodes.GETFIELD)
    )
    private int redirectWriteToTextureId(com.mojang.blaze3d.opengl.GlTexture texture) {
        if (texture instanceof io.homo.superresolution.common.minecraft.GpuTextureAdapter adapter) {
            return adapter.glId();
        }
        return texture.glId();
    }

    @Redirect(
            method = "copyBufferToTexture(Lcom/mojang/blaze3d/buffers/GpuBufferSlice;IIIILcom/mojang/blaze3d/textures/GpuTexture;IIIIII)V",
            at = @At(value = "FIELD", target = "Lcom/mojang/blaze3d/opengl/GlTexture;id:I", opcode = Opcodes.GETFIELD)
    )
    private int redirectCopyBufferToTextureId(com.mojang.blaze3d.opengl.GlTexture texture) {
        if (texture instanceof io.homo.superresolution.common.minecraft.GpuTextureAdapter adapter) {
            return adapter.glId();
        }
        return texture.glId();
    }

    @Redirect(
            method = "trySetup",
            at = @At(value = "FIELD", target = "Lcom/mojang/blaze3d/opengl/GlTexture;id:I", opcode = Opcodes.GETFIELD)
    )
    private int redirectTrySetupTextureId(com.mojang.blaze3d.opengl.GlTexture texture) {
        if (texture instanceof io.homo.superresolution.common.minecraft.GpuTextureAdapter adapter) {
            return adapter.glId();
        }
        return texture.glId();
    }
}
#else
@Mixin(net.minecraft.client.Minecraft.class)
public abstract class GlCommandEncoderMixin {
}
#endif
