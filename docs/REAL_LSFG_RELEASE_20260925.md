# REAL-LSFG release — 2026-09-25

This release pairs Amethyst's Experimental REAL-LSFG (Vulkan) setting with SGSR for Fabric / Minecraft 26.2 on Android ARM64.

The launcher setting is persisted in SharedPreferences and passed directly through JNI. Activation does not depend on `custom_env.txt`. Default is OFF; restart the game after changing this launcher setting. The mod controls runtime OFF/x2/x3. Shader cache follows the selected instance. The early-factor file follows the release/debug application's storage and remains shared between its instances.

The mod's runtime configuration and status discovery no longer depend on the V2 diagnostic flag. This fixes persistent ARMING / error -100 when diagnostics are off. The release also preserves content-history resets on screen changes and removes the obsolete x3 restart label. Diagnostic captures/profilers remain off by default.

## Validation and scope

The user reported that the installed combination works after the runtime bridge fix. This is functional user validation, not a new quantitative FPS benchmark or a claim of artifact-free interpolation.

- Amethyst: 174 unit tests; SGSR: 59 unit tests; no failures.
- Host contracts cover authoritative launcher selection, release/debug paths, factor persistence and runtime bridge control with both diagnostic probes off.
- The new distributable APK has no `testOnly` flag. Every DEX and native library is byte-identical to the user-validated APK; only AndroidManifest.xml and signatures differ.
- The released JAR is exactly the user-validated runtime bridge fix. No additional gameplay change was made during publication.
- Vulkan renderer and user-provided `mods/Lossless.dll` remain required. The DLL is not included.

The startup factor is package-wide. When switching instances with different saved factors, select the intended factor and restart the game before relying on x3 swapchain capacity. Cross-instance startup-factor isolation was not validated and is not promised by this release.

## Artifacts

| Artifact | SHA-256 |
|---|---|
| Amethyst-Plus-REAL-LSFG-arm64-release.apk | `802817668b5aa77687c71afc89156bb04a376ca148f18b38cd78e6d4990ab533` |
| SGSR-REAL-LSFG-fabric-26.2.jar | `b96dfda66373de60c4f28ac48e96aa2f569b26a8a7aee823a0e1e01009e01089` |
| liblsfg-minecraft.so | `a469d0c14b42eb4507f325200e02a5389a517a49873b4dbdff2beaf4528d0d54` |

APK package: `com.vairacing.amethystplus`. Signing certificate SHA-256: `2a9629e2a4fafeccb49e2a3a89d617e13968084be75d48f63877b72b88af572d`.

## Source/build mapping

Tag `real-lsfg-2026.09.25` records the checkpoint in superresolution, Amethyst-Android-Local, LSFG-Android-Minecraft and its lsfg-vk-android fork. The parent submodule points at the owned fork and exact engine commit. The committed engine is the existing tested working tree, not a new upstream integration.

The APK and JAR were built before creating the release commits so the validated bytes are retained. Their embedded development version strings retain the earlier HEAD identifiers; those strings are not source-tree hashes. Release tags, source hashes and SHA256SUMS identify this checkpoint. A later rebuild may change version metadata/archive timestamps.

Build prerequisites: local Android SDK, signing key, project Java toolchains and Gradle dependencies. For the existing Windows layout, clone Amethyst and LSFG-Android-Minecraft as siblings named `amethyst_worktree_real_lsfg_functional` and `LS-FG`; initialize the latter's submodules. The Amethyst native source currently includes `../LS-FG/lsfg-vk-android` through a relative path.

Native bridge build uses `LS-FG/minecraft-mod/src/main/cpp`, CMake 3.22.1, NDK 27.0.12077973, Android 29, ARM64, Release. Copy its `liblsfg-minecraft.so` to SGSR `common/src/main/resources/native/android-arm64/` before packaging. Keep the mirrored native hook source in SGSR synchronized.

```powershell
# Amethyst
$env:JAVA_HOME='C:\Program Files\Android\Android Studio\jbr'
.\gradlew.bat :app_pojavlauncher:testDebugUnitTest :app_pojavlauncher:assembleRelease '-Pandroid.injected.build.abi=arm64-v8a' '-Pandroid.injected.testOnly=false' --console=plain
# Output for this ABI-specific build: app_pojavlauncher/build/intermediates/apk/release/app_pojavlauncher-release.apk

# SGSR
python scripts/lsfg_factor_path_contract.py
python scripts/lsfg_runtime_bridge_contract.py
.\gradlew.bat :common:test :fabric:build '-Pminecraft_version_config=26.2' --no-daemon --console=plain
```

The APK is generated through the normal Gradle/native build, not by transplanting an SO into an old APK. Verify the packaged DEX/native libraries, manifest flag and signing certificate, rather than choosing an older APK left in another output directory.

Local evidence is archived under `artifacts/REAL_LSFG_RELEASE_20260925`, `artifacts/LSFG_ARMING_RELEASE_20260925_191530` and `artifacts/REAL_LSFG_AMETHYST_SETTINGS_20260925`. Raw device logs, private attachments and user DLLs are not committed or uploaded. Local accounts remain supported. Selective upstream integration is a later task.
