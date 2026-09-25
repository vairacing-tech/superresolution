package io.homo.superresolution.common.mixin.core;

import com.lsfg.minecraft.LsfgContentHistory;
import net.minecraft.client.gui.screens.Screen;
#if MC_VER > MC_26_1_2
import net.minecraft.client.gui.Gui;
#else
import net.minecraft.client.Minecraft;
#endif
import org.objectweb.asm.Opcodes;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

#if MC_VER > MC_26_1_2
@Mixin(Gui.class)
#else
@Mixin(Minecraft.class)
#endif
public abstract class ScreenChangeMixin {
    @Shadow
#if MC_VER > MC_26_1_2
    private Screen screen;
#else
    public Screen screen;
#endif

    // The argument has already been normalized (e.g. null -> TitleScreen).
    // Notify at the actual write, before added()/init() can render or reenter.
    @Inject(method = "setScreen(Lnet/minecraft/client/gui/screens/Screen;)V", at = @At(
            value = "FIELD",
#if MC_VER > MC_26_1_2
            target = "Lnet/minecraft/client/gui/Gui;screen:Lnet/minecraft/client/gui/screens/Screen;",
#else
            target = "Lnet/minecraft/client/Minecraft;screen:Lnet/minecraft/client/gui/screens/Screen;",
#endif
            opcode = Opcodes.PUTFIELD, shift = At.Shift.BEFORE), require = 1)
    private void super_resolution$screenChanged(Screen next, CallbackInfo ci) {
        LsfgContentHistory.screenChanged(screen, next);
    }
}
