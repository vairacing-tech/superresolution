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

package io.homo.superresolution.common.config.special;

import io.homo.superresolution.api.config.ModConfigSpecBuilder;
import io.homo.superresolution.api.config.values.single.BooleanValue;
import io.homo.superresolution.common.config.ConfigSpecType;
import net.minecraft.network.chat.Component;

import java.util.Map;

public class SGSR1SpecialConfig extends SpecialConfig {
    public final BooleanValue REDUCED_GL_STATE = specBuilder.defineBoolean(
            "special/sgsr1/reduced_gl_state", () -> true,
            "Save only the GL state touched by the bounded built-in SGSR1 path.");
    public final BooleanValue SKIP_AUXILIARY_INPUTS = specBuilder.defineBoolean(
            "special/sgsr1/skip_auxiliary_inputs", () -> true,
            "Skip auxiliary depth and empty motion-vector textures when SGSR1 is their only consumer.");
    public final BooleanValue DIRECT_COLOR_INPUT = specBuilder.defineBoolean(
            "special/sgsr1/direct_color_input", () -> true,
            "Borrow compatible owned render-target color for this SGSR1 dispatch, avoiding its input copy.");

    public SGSR1SpecialConfig(ModConfigSpecBuilder specBuilder) {
        super(specBuilder);
    }

    @Override
    protected void buildDescriptions(Map<String, SpecialConfigDescription<?>> map) {
        describe(map, "reduced_gl_state", REDUCED_GL_STATE);
        describe(map, "skip_auxiliary_inputs", SKIP_AUXILIARY_INPUTS);
        describe(map, "direct_color_input", DIRECT_COLOR_INPUT);
    }

    private void describe(Map<String, SpecialConfigDescription<?>> map, String key, BooleanValue value) {
        String translation = "superresolution.screen.config.special.sgsr1." + key;
        map.put(key, new SpecialConfigDescription<Boolean>()
                .setValue(value.get()).setDefaultValue(true).setKey(key)
                .setName(Component.translatable(translation + ".name"))
                .setTooltip(Component.translatable(translation + ".tooltip"))
                .setType(ConfigSpecType.BOOLEAN).setSaveConsumer(value::set));
    }
}
