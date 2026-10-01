package io.homo.superresolution.common.gui;

import io.homo.superresolution.api.config.values.single.BooleanValue;
import io.homo.superresolution.common.config.SuperResolutionConfig;
import io.homo.superresolution.common.minecraft.MinecraftUtils;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;

/** Independent SGSR1 switches for the simplified Android configuration screen. */
public final class Sgsr1OptimizationScreen extends Screen {
    private final Screen parentScreen;

    public Sgsr1OptimizationScreen(Screen parentScreen) {
        super(Component.literal("SGSR1 Optimizations"));
        this.parentScreen = parentScreen;
    }

    @Override
    protected void init() {
        var config = SuperResolutionConfig.SPECIAL.SGSR1;
        addSwitch("reduced_gl_state", config.REDUCED_GL_STATE, 40);
        addSwitch("skip_auxiliary_inputs", config.SKIP_AUXILIARY_INPUTS, 68);
        addSwitch("direct_color_input", config.DIRECT_COLOR_INPUT, 96);
        addRenderableWidget(Button.builder(Component.literal("Done"), btn -> onClose())
                .bounds(width / 2 - 120, 136, 240, 20).build());
    }

    private void addSwitch(String key, BooleanValue value, int y) {
        String translation = "superresolution.screen.config.special.sgsr1." + key;
        addRenderableWidget(Button.builder(switchText(translation, value), btn -> {
                    value.set(!value.get());
                    SuperResolutionConfig.SPEC.save();
                    btn.setMessage(switchText(translation, value));
                }).bounds(width / 2 - 120, y, 240, 20)
                .tooltip(Tooltip.create(Component.translatable(translation + ".tooltip"))).build());
    }

    private Component switchText(String translation, BooleanValue value) {
        return Component.translatable(translation + ".name").append(": " + (value.get() ? "ON" : "OFF"));
    }

    @Override
    public void onClose() {
        SuperResolutionConfig.SPEC.save();
        MinecraftUtils.setScreen(parentScreen);
    }
}
