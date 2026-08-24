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

package io.homo.superresolution.common.compat.iris;

import io.homo.superresolution.common.config.SuperResolutionConfig;
import io.homo.superresolution.common.workmode.SRWorkModeManager;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Optional;

public final class IrisCompatHelper {
    private static final Logger LOGGER = LoggerFactory.getLogger("SuperResolution-IrisCompat");
    private static final String IRIS_CLASS = "net.irisshaders.iris.Iris";
    private static final String CURRENT_SHADERPACK_FIELD = "currentPack";
    private static volatile boolean initialized;
    private static volatile boolean irisInstalled;
    private static volatile Field currentShaderpack;
    private static volatile Method getCurrentPackNameMethod;
    private static volatile Method reloadMethod;

    private IrisCompatHelper() {
    }

    public static boolean isIrisInstalled() {
        initReflection();
        return irisInstalled;
    }

    public static boolean isCandidateEligible() {
        return SuperResolutionConfig.isUnstableIncompatibleShaderSupportEnabledAtStartup()
                && hasActiveShaderpack();
    }

    public static boolean isHackSelected() {
        return SRWorkModeManager.isCurrentMode(SRWorkModeManager.HACK);
    }

    public static boolean hasActiveShaderpack() {
        initReflection();
        if (currentShaderpack == null) {
            return false;
        }
        try {
            Object value = currentShaderpack.get(null);
            return value instanceof Optional<?> optional ? optional.isPresent() : value != null;
        } catch (Throwable ignored) {
            return false;
        }
    }

    public static String getActiveShaderpackName() {
        initReflection();
        if (getCurrentPackNameMethod != null) {
            try {
                Object res = getCurrentPackNameMethod.invoke(null);
                if (res instanceof Optional<?> opt && opt.isPresent()) {
                    return opt.get().toString();
                } else if (res instanceof String s) {
                    return s;
                }
            } catch (Throwable ignored) {}
        }
        if (currentShaderpack != null) {
            try {
                Object value = currentShaderpack.get(null);
                if (value instanceof Optional<?> optional && optional.isPresent()) {
                    Object pack = optional.get();
                    return pack.toString();
                }
            } catch (Throwable ignored) {}
        }
        return null;
    }

    public static void reloadShaderPack() {
        initReflection();
        if (reloadMethod == null) {
            return;
        }
        try {
            reloadMethod.invoke(null);
        } catch (Throwable t) {
            LOGGER.error("Failed to reload Iris shader pack", t);
        }
    }

    private static void initReflection() {
        if (initialized) {
            return;
        }
        synchronized (IrisCompatHelper.class) {
            if (initialized) {
                return;
            }
            try {
                Class<?> irisClass = Class.forName(IRIS_CLASS);
                irisInstalled = true;
                try {
                    Field field = irisClass.getDeclaredField(CURRENT_SHADERPACK_FIELD);
                    field.setAccessible(true);
                    currentShaderpack = field;
                } catch (Throwable ignored) {
                    currentShaderpack = null;
                }
                try {
                    Method method = irisClass.getDeclaredMethod("getCurrentPackName");
                    method.setAccessible(true);
                    getCurrentPackNameMethod = method;
                } catch (Throwable ignored) {
                    getCurrentPackNameMethod = null;
                }
                try {
                    Method method = irisClass.getDeclaredMethod("reload");
                    method.setAccessible(true);
                    reloadMethod = method;
                } catch (Throwable ignored) {
                    reloadMethod = null;
                }
            } catch (Throwable ignored) {
                irisInstalled = false;
                currentShaderpack = null;
                getCurrentPackNameMethod = null;
                reloadMethod = null;
            }
            initialized = true;
        }
    }
}
