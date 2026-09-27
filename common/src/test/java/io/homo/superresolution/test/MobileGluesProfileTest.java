package io.homo.superresolution.test;

import io.homo.superresolution.core.graphics.opengl.compat.MobileGluesProfile;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class MobileGluesProfileTest {
    @Test
    void autoActivatesOnlyForAndroidMobileGluesContext() {
        var mobileGlues = new MobileGluesProfile.Identity(
                true, "", "OpenGL ES 3.2 MobileGlues", "Adreno (TM) 740"
        );
        var zink = new MobileGluesProfile.Identity(
                true, "", "OpenGL ES 3.2 Mesa 23.1.9", "zink (Adreno (TM) 740)"
        );
        var desktopMobileGlues = new MobileGluesProfile.Identity(
                false, "GL_MG_mobileglues", "OpenGL ES 3.2", "MobileGlues"
        );

        assertTrue(MobileGluesProfile.evaluate(MobileGluesProfile.Mode.AUTO, mobileGlues).active());
        assertFalse(MobileGluesProfile.evaluate(MobileGluesProfile.Mode.AUTO, zink).active());
        assertFalse(MobileGluesProfile.evaluate(MobileGluesProfile.Mode.AUTO, desktopMobileGlues).active());
    }

    @Test
    void extensionCanIdentifyMobileGluesAndAngleIsNeverQualified() {
        var extensionOnly = new MobileGluesProfile.Identity(
                true, "GL_MG_mobileglues GL_EXT_color_buffer_float", "OpenGL ES 3.2", "Adreno 740"
        );
        var angle = new MobileGluesProfile.Identity(
                true, "GL_MG_mobileglues", "OpenGL ES 3.2 ANGLE", "ANGLE (Adreno 740)"
        );

        assertTrue(MobileGluesProfile.evaluate(MobileGluesProfile.Mode.AUTO, extensionOnly).active());
        var angleDecision = MobileGluesProfile.evaluate(MobileGluesProfile.Mode.COMPAT, angle);
        assertFalse(angleDecision.active());
        assertFalse(angleDecision.supportedBackend());
        assertTrue(angleDecision.reason().toLowerCase().contains("angle"));
    }

    @Test
    void compatIsAndroidOnlyOverrideAndSuppressesLsfg() {
        var hiddenMobileGlues = new MobileGluesProfile.Identity(true, "", "OpenGL ES 3.2", "Adreno 740");
        var desktop = new MobileGluesProfile.Identity(false, "", "OpenGL 4.6", "NVIDIA RTX");

        var decision = MobileGluesProfile.evaluate(MobileGluesProfile.Mode.COMPAT, hiddenMobileGlues);
        assertTrue(decision.active());
        assertFalse(decision.supportedBackend());
        assertFalse(decision.allowLsfg());
        assertFalse(MobileGluesProfile.evaluate(MobileGluesProfile.Mode.COMPAT, desktop).active());
    }

    @Test
    void offLeavesExistingRendererPolicyAloneAndUnknownModeFallsBackToAuto() {
        var mobileGlues = new MobileGluesProfile.Identity(true, "GL_MG_mobileglues", "", "Adreno 740");

        assertFalse(MobileGluesProfile.evaluate(MobileGluesProfile.Mode.OFF, mobileGlues).active());
        assertEquals(MobileGluesProfile.Mode.AUTO, MobileGluesProfile.parseMode("typo"));
        assertEquals(MobileGluesProfile.Mode.COMPAT, MobileGluesProfile.parseMode(" COMPAT "));
    }
}
