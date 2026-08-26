/*
 * Super Resolution - LSFG Android Integration
 * Copyright (c) 2026. vairacing-tech / FrankBarretta
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package com.lsfg.minecraft;

import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.nio.file.Path;

public final class LsfgConfig {

    public boolean enabled = true;
    public int multiplier = 2;
    public float flowScale = 1.0f;
    public boolean performanceMode = true;
    public boolean framegenFp16 = true;
    public boolean antiArtifacts = true;

    private static final String CONFIG_FILENAME = "lsfg.json";

    public static LsfgConfig load(Path gameDir) {
        Path configDir = (gameDir != null ? gameDir : new File(".").toPath())
            .resolve("config")
            .resolve("superresolution");
        File configFile = configDir.resolve(CONFIG_FILENAME).toFile();

        LsfgConfig config = new LsfgConfig();
        if (configFile.exists() && configFile.isFile()) {
            try (FileReader reader = new FileReader(configFile)) {
                char[] buffer = new char[(int) configFile.length()];
                int read = reader.read(buffer);
                String json = new String(buffer, 0, read);
                if (json.contains("\"enabled\":false")) config.enabled = false;
                if (json.contains("\"multiplier\":3")) config.multiplier = 3;
                if (json.contains("\"performanceMode\":false")) config.performanceMode = false;
                if (json.contains("\"framegenFp16\":false")) config.framegenFp16 = false;
                if (json.contains("\"antiArtifacts\":false")) config.antiArtifacts = false;
            } catch (Throwable ignored) {}
        } else {
            config.save(gameDir);
        }
        return config;
    }

    public void save(Path gameDir) {
        Path configDir = (gameDir != null ? gameDir : new File(".").toPath())
            .resolve("config")
            .resolve("superresolution");
        File dir = configDir.toFile();
        if (!dir.exists()) dir.mkdirs();

        File configFile = new File(dir, CONFIG_FILENAME);
        String json = "{\n" +
            "  \"enabled\": " + enabled + ",\n" +
            "  \"multiplier\": " + multiplier + ",\n" +
            "  \"flowScale\": " + flowScale + ",\n" +
            "  \"performanceMode\": " + performanceMode + ",\n" +
            "  \"framegenFp16\": " + framegenFp16 + ",\n" +
            "  \"antiArtifacts\": " + antiArtifacts + "\n" +
            "}\n";

        try (FileWriter writer = new FileWriter(configFile)) {
            writer.write(json);
            writer.flush();
        } catch (Throwable ignored) {}
    }
}
