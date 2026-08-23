package io.homo.superresolution.common.workmode;

import io.homo.superresolution.common.config.SuperResolutionConfig;

public final class HackWorkModeBootstrap {
    private HackWorkModeBootstrap() {
    }

    public static void register() {
        if (SuperResolutionConfig.isUnstableIncompatibleShaderSupportEnabledAtStartup() || io.homo.superresolution.api.platform.Platform.isJavaOnlyMode()) {
            SRWorkModeManager.register(new HackSRWorkModeProvider());
        }
    }
}
