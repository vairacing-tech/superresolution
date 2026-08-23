/*
 * Super Resolution
 * Copyright (c) 2025-2026. 187J3X1-114514
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package io.homo.superresolution.common.mixin.gui;

import io.homo.superresolution.common.debug.SuperResolutionDebugHelper;
import net.minecraft.client.gui.components.DebugScreenOverlay;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.util.List;

@Mixin(DebugScreenOverlay.class)
public class DebugScreenOverlayMixin {

    #if MC_VER > MC_26_1_2
    @Inject(
            method = "extractLines",
            at = @At("HEAD")
    )
    private void superresolution$onExtractLines(net.minecraft.client.gui.GuiGraphicsExtractor extractor, List<String> lines, boolean leftSide, CallbackInfo ci) {
        if (leftSide && lines != null) {
            SuperResolutionDebugHelper.StatusInfo status = SuperResolutionDebugHelper.getStatus();
            lines.add("");
            lines.add(status.getF3Line1());
            lines.add(status.getF3Line2());
            if (status.getF3Line3() != null) {
                lines.add(status.getF3Line3());
            }
            if (status.getF3Line4() != null) {
                lines.add(status.getF3Line4());
            }
        }
    }
    #else
    @Inject(
            method = "getGameInformation",
            at = @At("RETURN")
    )
    private void superresolution$onGetGameInformation(CallbackInfoReturnable<List<String>> cir) {
        List<String> lines = cir.getReturnValue();
        if (lines != null) {
            SuperResolutionDebugHelper.StatusInfo status = SuperResolutionDebugHelper.getStatus();
            lines.add("");
            lines.add(status.getF3Line1());
            lines.add(status.getF3Line2());
            if (status.getF3Line3() != null) {
                lines.add(status.getF3Line3());
            }
            if (status.getF3Line4() != null) {
                lines.add(status.getF3Line4());
            }
        }
    }
    #endif
}
