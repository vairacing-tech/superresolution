/*
 * Super Resolution
 * Copyright (c) 2025-2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.mixin.core;

#if MC_VER > MC_26_1_2
import com.mojang.blaze3d.pipeline.RenderTarget;
import io.homo.superresolution.common.minecraft.MinecraftUtils;
import net.minecraft.client.renderer.SkyRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

@Mixin(SkyRenderer.class)
public class SkyRendererMixin {

    @Redirect(
            method = {
                    "renderSkyDisc",
                    "renderDarkDisc",
                    "renderSun",
                    "renderMoon",
                    "renderStars",
                    "renderSunriseAndSunset",
                    "renderEndSky",
                    "renderEndFlash"
            },
            at = @At(value = "FIELD", target = "Lnet/minecraft/client/renderer/SkyRenderer;renderTarget:Lcom/mojang/blaze3d/pipeline/RenderTarget;", opcode = org.objectweb.asm.Opcodes.GETFIELD)
    )
    private RenderTarget superresolution$redirectSkyRenderTarget(SkyRenderer instance) {
        return MinecraftUtils.getMainRenderTarget();
    }
}
#endif