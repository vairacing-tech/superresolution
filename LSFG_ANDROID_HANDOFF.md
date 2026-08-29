# ANDROID SGSR + LSFG FRAME GENERATION INTEGRATION HANDOFF

> **Authoritative Technical Hand-Off Document**  
> **Workspace**: `C:\Proyectos\SGSR`  
> **Target Platform**: Android AArch64 (ARM64-v8a) / AYN Odin 2 Portal (Snapdragon 8 Gen 2 / Adreno 740)  
> **Graphics Stack**: Minecraft 26.2 + Fabric 0.19.3 + Iris Shaders + Mesa Zink (OpenGL 4.6 on Vulkan) + Turnip Driver (PurpleVK) + Amethyst Plus Launcher  
> **Document Date**: August 27, 2026  

---

## 0. CURRENT VALIDATION STATUS & PHASE CLOSURE

> [!IMPORTANT]
> **MILESTONE STATUS (August 29, 2026)**:
> **LSFG V2B.1B PRODUCTION TRANSPORT CLEANUP — PHYSICALLY VALIDATED AND PHASE CLOSED**
>
> - **Tested APK Candidate**: `clean-v2b1b-production-cleanup.apk`
> - **Tested APK SHA-256**: `D2B38EC20628D5163CEAE732667BA99BC12A1DFAF5361FCA92DBF0547B0DCA86`
> - **Target Platform / Stack**:
>   - Device: AYN Odin 2 Portal (Qualcomm Snapdragon 8 Gen 2 / Adreno 740)
>   - OS: Android API 33
>   - Vulkan Driver: Turnip Driver via PurpleVK (`vulkan.purple.so`)
>   - Translation Layer: Mesa Zink (`libEGL_mesa.so` / `libgallium_dri.so`, OpenGL 4.6 on Vulkan)
>   - Game & Mods: Minecraft 26.2 + Fabric 0.19.3 + Iris Shaders + SGSR1
>   - Launcher: Amethyst Plus Debug (`com.vairacing.amethystplus.debug`)
> - **Production Configuration**:
>   ```text
>   AMETHYST_LSFG_VULKAN_INTERPOSER=1
>   AMETHYST_LSFG_V2B0_FIFO=1
>   AMETHYST_LSFG_V2B1_ACTIVE=2
>   ```
>   *(Zero `DIAG_*` variables required)*
> - **Physical Validation Results**:
>   - Clean launcher startup and Minecraft launch over WiFi ADB.
>   - Flawless in-game rendering in `Mundo nuevo` without graphical corruption.
>   - Zero crashes, zero freezes, zero deadlocks, zero SIGSEGV, zero `kgsl_syncobj_merge` driver faults.
>   - Structural resource normalization (`diagAcquireReadyCommandBuffer` $\to$ `acquireBridgeCommandBuffer`) physically verified.
>   - Full clean shutdown.
>
> **Scope & Architectural Boundaries**:
> 1. **Hardware/Driver Specificity**: Physical validation applies specifically to the tested Odin 2 Portal / Adreno 740 / Turnip stack; universal Vulkan driver compatibility is neither claimed nor implied.
> 2. **Real Frame Generation Status**: **NOT IMPLEMENTED**. The current active transport executes 1:1 duplicate/copy transport ($N \to M$) to prove Vulkan presentation and synchronization integrity.
>
> **Next Planned Phase**:
> **Phase B: Real Frame Generation Integration** (SPIR-V Vulkan compute kernels, optical flow interpolation, metadata capture, and synthesized present frames).

---

## 1. PROJECT GOAL & TARGET ARCHITECTURE

The objective is end-to-end, hardware-accelerated Super Resolution and Lossless Scaling Frame Generation (LSFG) running on Android AArch64 with full shaderpack support under unmodified Fabric.

```
+-----------------------------------------------------------------------------------+
|                                MINECRAFT 26.2                                     |
|                           (Fabric Loader 0.19.3)                                  |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
|                             IRIS SHADER ENGINE                                    |
|                      (Complementary Reimagined r5.8.1)                            |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
|                        SUPER RESOLUTION EXTENSION                                 |
|            [CURRENT: SGSR1 (Java/GL)]  --->  [FUTURE: SGSR v2]                    |
+-----------------------------------------------------------------------------------+
                                        |
                                        v (Final Upscaled Frame at Native Resolution)
+-----------------------------------------------------------------------------------+
|                     LSFG FRAME GENERATION (2x / 3x)                               |
|        - V1 / V2A: Passive Handshake & Swapchain/Queue Metadata Capture           |
|        - V2B: Dual-Present Transport Validation (Duplicate/Copy)                  |
|        - V2C: Real LSFG Compute Interpolation via Vulkan Compute                  |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
|                      EARLY VULKAN INTERPOSER LAYER                                |
|             (liblsfg-vulkan-interposer.so / VULKAN_PTR Interposition)             |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
|                          MESA ZINK OPENGL-ON-VULKAN                               |
|                      (libEGL_mesa.so / libgallium_dri.so)                         |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
|                           TURNIP VULKAN DRIVER                                    |
|                          (vulkan.purple.so / Adreno 740)                          |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
|                           ANDROID DISPLAY / ANativeWindow                         |
+-----------------------------------------------------------------------------------+
```

### Architectural Guarantees:
* **Algorithm Agnostic**: The Vulkan interposer and frame-generation transport layers treat the upstream frame purely as a standard color/format surface. SGSR1 today and SGSR v2 tomorrow plug in seamlessly without altering the Vulkan present bridge.
* **Shaderpacks Mandatory**: All rendering paths must remain 100% compatible with Iris framebuffer pipelines, composite passes, and deferred geometry rendering.
* **Standard Fabric**: Unmodified Fabric Loader and Mojang runtime; no core JVM bytecode hacks or modified lwjgl binaries.

---

## 2. COMPONENT RESPONSIBILITIES

| Component / Layer | Repository | Primary Responsibilities | Prohibited Responsibilities |
| :--- | :--- | :--- | :--- |
| **Amethyst Launcher** | `C:\Proyectos\amethyst` | • Early Vulkan loader interposition prior to Zink init<br>• Packaging and loading `liblsfg-vulkan-interposer.so`<br>• Dynamic redirection of `VULKAN_PTR`<br>• Versioned C ABI presentation & metadata bridge<br>• Device/Swapchain/Queue handle tracking | • LSFG compute shaders<br>• Optical flow / frame interpolation<br>• Frame generation scheduling policy<br>• SuperResolution mod configuration<br>• Parsing `Lossless.dll` |
| **SuperResolution (SGSR)** | `C:\Proyectos\SGSR` | • SGSR1 GLSL pipeline and shader dispatch<br>• Android Java/OpenGL-only execution path<br>• Resolution scaling & dynamic viewport adaptation<br>• Loading `liblsfg-minecraft.so`<br>• High-level Frame Generation UI & lifecycle control<br>• Future SGSR v2 motion vector / depth integration | • Modifying Turnip driver binaries<br>• In-memory Mesa memory scanning<br>• Direct private Zink struct patching<br>• Bypassing Amethyst's `VULKAN_PTR` bridge |
| **LS-FG Native Core** | `C:\Proyectos\LS-FG` | • Reference LSFG Vulkan compute pipeline<br>• SPIR-V shader generation & translation<br>• Optical flow & frame interpolation kernels<br>• Native build tree for `liblsfg-minecraft.so` | • Launcher-level environment injection<br>• Minecraft Java GUI rendering |

---

## 3. REPOSITORIES, BRANCHES & VALIDATED CHECKPOINTS

### Status Classification:
* `VALIDATED`: Physically executed on Odin 2 hardware with zero GL/Vulkan errors, 1:1 present ratios, and clean teardown.
* `IMPLEMENTED / UNVALIDATED`: Source code compiled and unit-tested, but pending physical hardware execution.
* `PLANNED`: Architectural design defined; implementation pending.
* `TECHNICAL DEBT`: Known build coupling or incomplete standalone build script.

```
+----------------------------------------------------------------------------------------------------+
| REPOSITORY: C:\Proyectos\amethyst (Launcher & Early Interposer)                                    |
| Current Branch: feature/lsfg-vulkan-interposer                                                     |
+----------------------------------------------------------------------------------------------------+
| Checkpoint Commit | Message                                                      | Status          |
+-------------------+--------------------------------------------------------------+-----------------+
| 43aa28acea9a      | feat(android): add validated early Vulkan interposer for     | VALIDATED       |
|                   | Zink                                                         |                 |
| 1586e4c6c18a      | feat(android): add validated LSFG passive present bridge     | VALIDATED       |
| [Uncommitted]     | V2A Bridge Snapshot & Metadata Export Implementation         | IMPLEMENTED /   |
|                   |                                                              | UNVALIDATED     |
+----------------------------------------------------------------------------------------------------+
```

```
+----------------------------------------------------------------------------------------------------+
| REPOSITORY: C:\Proyectos\SGSR (Super Resolution & LSFG Mod)                                       |
| Current Branch: feature/android-lsfg-integration                                                   |
+----------------------------------------------------------------------------------------------------+
| Checkpoint Commit | Message                                                      | Status          |
+-------------------+--------------------------------------------------------------+-----------------+
| 194a6a5419eb      | feat(android): add LSFG integration skeleton & Vulkan probe  | VALIDATED       |
| 8c8c8b024d25      | feat(android): add validated passive LSFG present bridge     | VALIDATED       |
| [Uncommitted]     | V2A Bridge Snapshot Query & Logging Implementation           | IMPLEMENTED /   |
|                   |                                                              | UNVALIDATED     |
+----------------------------------------------------------------------------------------------------+
```

```
+----------------------------------------------------------------------------------------------------+
| REPOSITORY: C:\Proyectos\LS-FG (Native LSFG Core & ARM64 Backend)                                  |
| Current Branch: feature/minecraft-fabric-lsfg                                                      |
+----------------------------------------------------------------------------------------------------+
| Checkpoint Commit | Message                                                      | Status          |
+-------------------+--------------------------------------------------------------+-----------------+
| ab599d05e03c      | feat(minecraft-mod): add Fabric mod skeleton and Android    | VALIDATED       |
|                   | ARM64 native backend                                         | (Phase 2A base) |
+----------------------------------------------------------------------------------------------------+
```

---

## 4. SGSR1 VALIDATED ANDROID INVARIANTS

> [!CAUTION]
> **DO NOT MODIFY OR REGRESS ANY OF THE FOLLOWING VALIDATED SGSR1 INVARIANTS.**  
> These invariants represent weeks of physical debugging on Adreno 740 / Zink and ensure zero-overhead, crash-free upscaling with Iris shaderpacks.

1. **Android AArch64 Java/OpenGL-Only Path**:
   * Desktop native binary extraction (`SRNativeMain`, `libfsr2.so`, etc.) is strictly bypassed on Android.
   * Glslang / SPIR-V runtime compilers and internal GLFW/Vulkan device probing are disabled.
   * Shaders are compiled directly via standard OpenGL ES / Desktop GL API: `glShaderSource` + `glCompileShader`.
2. **Algorithm Registry Support**:
   * Active implementations: `NONE`, `SGSR1`, and `BILINEAR`.
3. **Explicit Rasterizer & Viewport State**:
   * Output raster state is strictly bound to `screenWidth` x `screenHeight`.
   * SGSR1 render input texture is bound to `renderWidth` x `renderHeight` (e.g., 50% scale = 960x540).
4. **Color & Depth Formats**:
   * Color target: `GL_RGBA8`.
   * Depth target: Dynamically inherits Iris's active depth buffer format (`GL_DEPTH_COMPONENT32F`).
5. **No Shaderpack-Specific Workarounds**:
   * Works generically across Complementary Reimagined, BSL, AstraLex, and vanilla pipelines.
6. **Asynchronous GPU Timing Metrics**:
   * Profiled strictly via asynchronous `GL_TIME_ELAPSED` query rings.
   * **Zero `glFinish()`** and **zero blocking `glGetQueryObjectuiv`** stalls in the render loop.
7. **Dynamic Resolution Changes**:
   * Resizing window or scaling slider triggers `RenderTargets.resizeIfNeeded` without requiring an Iris shaderpack reload.
   * `GpuTextureAdapter` maintains stable handle identities; dynamic attachments update via `glId()`.
8. **Clean JVM Code**:
   * Zero `sun.misc.Unsafe`, `MethodHandles.privateLookupIn`, reflection hacks, or custom JNI in the SGSR1 rendering path.
9. **Physical Verification**:
   * 0 GL errors (`GL_NO_ERROR`), stable 60 FPS on Odin 2 at 50% scale (960x540 -> 1920x1080).

---

## 5. PASSIVE VULKAN INTERPOSER — PHYSICALLY VALIDATED

### Why Fabric Loading Was Too Late:
In early testing, loading `liblsfg-minecraft.so` inside Fabric (`System.load`) failed to intercept Vulkan calls. Mesa Zink initializes during launcher startup (`pojavInitOpenGL()` -> `dlsym_EGL()` -> `libEGL_mesa.so` -> `libgallium_dri.so`). Zink resolves Vulkan entry points (`vkGetInstanceProcAddr`, `vkCreateInstance`, `vkCreateDevice`, `vkQueuePresentKHR`) and caches them inside its internal `struct zink_screen` **before** the JVM even spawns the Fabric classloader.

### Validated Interposition Mechanism:
Amethyst creates the `pojav-driver` namespace, loads Turnip (`vulkan.purple.so`), loads the patched system `libvulkan.so`, initializes `liblsfg-vulkan-interposer.so`, and points `VULKAN_PTR` to the interposer. When Zink initializes, it queries `dlsym(VULKAN_PTR, "vkGetInstanceProcAddr")` and receives our canonical interposer entry points.

```
[Amethyst Launcher]
       |
       v
[Turnip Driver (vulkan.purple.so) + Patched libvulkan.so]
       |
       v (Real Vulkan Handle)
[liblsfg-vulkan-interposer.so] <--- lsfg_interposer_init(realHandle)
       |
       v (Interposer Handle)
[setenv("VULKAN_PTR", interposerHandleHex)]
       |
       v
[Mesa Zink (libEGL_mesa.so -> libgallium_dri.so)]
       |
       v (dlsym("vkGetInstanceProcAddr") -> Interposer GIPA)
[Minecraft / Fabric / SuperResolution Presentation]
```

### Authoritative Physical Counter Results (Checkpoint `43aa28acea9a`):
```text
[LSFG-VK-SUMMARY]
  gipa                     = 113
  gdpa                     = 433
  createInstance           = 2
  enumPhysDev              = 6
  createDevice             = 1
  getDevQueue              = 2
  getDevQueue2             = 0
  createSwapchain          = 1
  destroySwapchain         = 0
  getSwapchainImages       = 2
  acquire                  = 1907
  acquire2                 = 0
  present                  = 1907
  destroyDevice            = 0
  destroyInstance          = 0
```

* **Acquire Total**: 1907
* **Present Total**: 1907
* **Acquire : Present Ratio**: **Exact 1 : 1**
* **Result**: `VALIDATED` (Zero GL/Vulkan errors, zero graphical artifacts, clean JVM exit code 0).

---

## 6. ZGC & DIAGNOSTIC INSTRUMENTATION FINDINGS

During Phase 2C physical testing, two critical runtime behaviors were isolated:

### 1. ZGC Memory Pressure & LMK:
* `-XX:+UseZGC` with 50+ mods and a 4096 MB allocated heap resulted in multi-mapped virtual page overhead exceeding 4.25 GB RSS during texture atlas stitching (8192x4096 items atlas), triggering Android's Low Memory Killer (`lowmemorykiller: Kill ... to free 4247532kB rss`).
* In shutdown testing, ZGC was also linked to JVM termination stalls (`ClientShutdownWatchdog`).
* **Rule**: Production and development testing must keep **ZGC OFF** (use standard OpenJDK 25 GC / G1GC).

### 2. Diagnostic Instrumentation vs Production Interposer:
To guarantee absolute safety, Amethyst isolates diagnostic logging from the production Vulkan interposer:
* `AMETHYST_LSFG_VULKAN_INTERPOSER=1`: Controls canonical Vulkan entry point interposition (production path).
* `AMETHYST_LSFG_DIAGNOSTICS=1`: Controls verbose `dlsym` / linker tracing (debug only).

### Physical Test Matrix:
| `INTERPOSER` | `DIAGNOSTICS` | JVM GC | Physical Result |
| :---: | :---: | :---: | :--- |
| `0` (OFF) | `0` (OFF) | Standard (ZGC OFF) | **CLEAN** |
| `1` (ON) | `1` (ON) | Standard (ZGC OFF) | **WATCHDOG TRIGGERED** (Instrumentation thread lock) |
| `1` (ON) | `0` (OFF) | Standard (ZGC OFF) | **CLEAN** (Zero stalls, exit code 0) |

> [!IMPORTANT]
> Keep `AMETHYST_LSFG_DIAGNOSTICS=0` (or unset) during all regular gameplay and bridge validation tests.

---

## 7. PASSIVE CONTROL BRIDGE V1 — PHYSICALLY VALIDATED

### Architecture:
Bridge V1 establishes a native-to-native callback between `liblsfg-minecraft.so` (Fabric mod) and `liblsfg-vulkan-interposer.so` (launcher layer) without invoking JNI or Java per frame.

```
[Minecraft Frame Completed]
            |
            v
[libgallium_dri.so (Zink)]
            |
            v
[interposer_vkQueuePresentKHR in liblsfg-vulkan-interposer.so]
            |
            +---> (Calls registered native callback: lsfg_present_observer_callback_v1)
            |                   |
            |                   v
            |     [liblsfg-minecraft.so (SuperResolution)]
            |     - Validates serial & timestamps
            |     - Increments native atomics
            |     - Returns ACK (0)
            |                   |
            v <-----------------+
[Forwards unchanged VkPresentInfoKHR to Real Turnip vkQueuePresentKHR]
```

### V1 C ABI Exports (`liblsfg-vulkan-interposer.so`):
```c
uint32_t lsfg_interposer_bridge_get_version(); // Returns 1
int32_t lsfg_interposer_register_present_observer_v1(PFN_lsfg_present_observer_v1 callback, void *userData);
int32_t lsfg_interposer_unregister_present_observer_v1(PFN_lsfg_present_observer_v1 callback);
```

### Authoritative Physical Results (Checkpoints `1586e4c6c18a` & `8c8c8b024d25`):
```text
[LSFG-VK-SUMMARY]
  present            = 16870
  bridgeReg          = 1
  bridgeEligible     = 16870
  bridgeInvocations  = 16870
  bridgeAck          = 16870
  bridgeBadAck       = 0
```

### Authoritative Equalities:
$$\text{bridgeInvocations} == \text{bridgeEligible} = 16870$$
$$\text{bridgeAck} == \text{bridgeInvocations} = 16870$$
$$\text{bridgeBadAck} == 0$$

* **Status**: `VALIDATED` — Passive Control Bridge V1 is complete, lossless, and zero-overhead.

---

## 8. LOSSLESS.DLL RUNTIME POLICY

* `mods/Lossless.dll` is an optional, user-provided Windows x86_64 asset file.
* **Strict Policy**:
  * **Never bundle** `Lossless.dll` into the mod JAR or APK.
  * **Never execute** `Lossless.dll` on Android (incompatible PE binary).
  * **V2A and V2B DO NOT REQUIRE `Lossless.dll`**.
  * Future V2C will extract SPIR-V compute shader resources from the DLL or use a precompiled shader cache if configured.

---

## 9. EXISTING LS-FG NATIVE BACKEND REFERENCE

The reference codebase in `C:\Proyectos\LS-FG\lsfg-vk-android` models the intended 2x interpolation flow:
1. **Source Capture**: Copies Zink's rendered swapchain image (`TRANSFER_SRC`) to an internal history texture.
2. **Compute Dispatch**: Executes LSFG motion estimation and frame interpolation compute pipelines on the Vulkan compute queue.
3. **Extra Acquire**: Calls `vkAcquireNextImageKHR` to acquire an additional physical swapchain image.
4. **Generated Present**: Writes interpolated frame to the extra image and presents it (`vkQueuePresentKHR`).
5. **Real Present**: Presents the original application frame.

> [!WARNING]
> This is a **reference architecture**. It must NOT be implemented on Android until V2A physically measures Turnip/Zink swapchain limits (`minImageCount`, `maxImageCount`, `imageUsage`, `supportedUsageFlags`).

---

## 10. CURRENT V2A STATUS & METADATA HANDSHAKE

* **Current Status**: `IMPLEMENTED / BUILT BUT NOT YET PHYSICALLY VALIDATED`.
* **Objective**: Measure real Android/Zink Vulkan swapchain capabilities with zero presentation modification.

### Captured V2A Metadata (`LsfgBridgeSnapshotV2`):
```c
struct LsfgBridgeSnapshotV2 {
    uint32_t abiVersion;               // Must be LSFG_BRIDGE_ABI_VERSION_V2 (2)
    uint32_t structSize;               // Caller sizeof(LsfgBridgeSnapshotV2)
    uint64_t generation;               // Monotonically increasing metadata generation
    uint32_t validMask;                // Bitmask of valid fields (Core, Queue, Swapchain, etc.)
    
    // Core Vulkan Handles
    VkInstance instance;
    VkPhysicalDevice physicalDevice;
    VkDevice device;
    
    // Present Queue Metadata
    VkQueue presentQueue;
    uint32_t queueFamilyIndex;
    uint32_t queueIndex;
    VkQueueFlags queueFlags;
    
    // Swapchain Metadata
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat imageFormat;
    VkColorSpaceKHR imageColorSpace;
    VkExtent2D imageExtent;
    uint32_t imageArrayLayers;
    VkImageUsageFlags imageUsage;
    VkSharingMode imageSharingMode;
    VkSurfaceTransformFlagBitsKHR preTransform;
    VkCompositeAlphaFlagBitsKHR compositeAlpha;
    VkPresentModeKHR presentMode;
    VkBool32 clipped;
    VkSwapchainKHR oldSwapchain;
    
    // Image Counts & Capabilities
    uint32_t requestedMinImageCount;
    uint32_t actualImageCount;
    VkImage images[LSFG_BRIDGE_MAX_SWAPCHAIN_IMAGES]; // Max 8
    VkSurfaceCapabilitiesKHR surfaceCapabilities;
    uint32_t supportedPresentModeCount;
    VkPresentModeKHR supportedPresentModes[LSFG_BRIDGE_MAX_PRESENT_MODES]; // Max 8
};
```

---

## 11. CURRENT V2A PRE-PHYSICAL CORRECTION DETAILS

Before running the physical test on Odin 2, ensure the following audit items are satisfied:

1. **V1 Backward Compatibility**:
   `lsfg_interposer_bridge_get_version()` must return `1`. V2 snapshot export is exposed as a separate symbol: `lsfg_interposer_bridge_get_snapshot_v2`.
2. **Forward-Compatible Bounded Copy**:
   ```cpp
   if (outSnapshot->abiVersion != LSFG_BRIDGE_ABI_VERSION_V2) return -2;
   if (outSnapshot->structSize < LSFG_BRIDGE_SNAPSHOT_V2_MIN_SIZE) return -3;
   size_t copyBytes = std::min(static_cast<size_t>(outSnapshot->structSize), sizeof(LsfgBridgeSnapshotV2));
   std::memcpy(outSnapshot, &hostSnapshot, copyBytes);
   ```
3. **Independent Probing Properties**:
   * V1 Probe: `-Dsuperresolution.lsfg_bridge_probe=true`
   * V2A Probe: `-Dsuperresolution.lsfg_bridge_v2_probe=true`
4. **Strict Concurrency Locking Rules**:
   Never invoke real Vulkan driver entry points (`vkGetSwapchainImagesKHR`, `vkGetPhysicalDeviceSurfaceCapabilitiesKHR`) while holding `g_stateMutex`. Fetch real driver results into local stack memory first, then acquire `g_stateMutex` to commit to global metadata structures.
5. **Caller Copy-Out for Images**:
   `lsfg_interposer_bridge_get_swapchain_images_v2` copies handles directly into caller-allocated arrays.
6. **Monotonic Generation Counter**:
   `g_metadataGeneration` increments on device creation, swapchain creation, and swapchain image retrieval.

---

## 12. V2B DESIGN CONSTRAINTS (DO NOT IMPLEMENT YET)

When V2A physical validation is complete, V2B will implement dual-present transport. The following constraints must be respected:

1. **Explicit Pre-Commit / Post-Commit Fail-Open**:
   * If failure occurs *before* acquiring an extra image or consuming render semaphores: Fail-open by presenting the original frame normally.
   * If failure occurs *after* state modification: Handle cleanly without deadlocking Vulkan queues or leaving orphaned semaphores.
2. **Swapchain Usage Validation**:
   * Do not assume `imageUsage` contains `VK_IMAGE_USAGE_TRANSFER_DST_BIT` or `VK_IMAGE_USAGE_STORAGE_BIT`. Verify against V2A physical results.
3. **Extra Image Capacity**:
   * Do not assume `actualImageCount >= 3` allows an extra acquire without blocking. Verify surface capabilities.
4. **FIFO vs Mailbox Pacing**:
   * FIFO is required for initial transport validation to ensure deterministic present ordering.
5. **Shared Device / Zero Cross-Device Overhead**:
   * LSFG compute must run on the exact same `VkDevice` as Mesa Zink.
   * **Zero `vkDeviceWaitIdle()`** or `vkQueueWaitIdle()` calls in the render loop.
6. **Semaphore Chaining**:
   * Zink Render Semaphore $\rightarrow$ LSFG Work $\rightarrow$ Generated Present Semaphore $\rightarrow$ Real Present Semaphore.

---

## 13. STAGED DEVELOPMENT ROADMAP

```
+---------------------------------------------------------------------------------------------------+
| PHASE V2A: PASSIVE METADATA & LIFECYCLE SNAPSHOT                                                  |
| Status: IMPLEMENTED / PENDING PHYSICAL VALIDATION                                                 |
| Goal: Physically query and verify VkDevice, VkQueue, VkSwapchainKHR, image handles, and caps.    |
| Presentation Impact: ZERO (100% passive pass-through).                                           |
+---------------------------------------------------------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
| PHASE V2B: DUAL-PRESENT TRANSPORT VALIDATION (DUPLICATE / COPY TEST)                              |
| Status: PLANNED (DO NOT IMPLEMENT YET)                                                            |
| Goal: Prove 2x presentation cadence by acquiring an extra swapchain image, blitting/copying the   |
|       real frame into it, and presenting both frames (Generated + Real) without interpolation.    |
| Presentation Impact: 2x present rate (e.g., 60 Hz -> 120 Hz cadence).                             |
+---------------------------------------------------------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
| PHASE V2C: ACTIVE LSFG COMPUTE & SHADER INTERPOLATION                                             |
| Status: PLANNED (DO NOT IMPLEMENT YET)                                                            |
| Goal: Replace duplicate copy with active LSFG motion estimation & optical flow compute dispatch.  |
| Presentation Impact: True AI frame generation on Android.                                         |
+---------------------------------------------------------------------------------------------------+
```

---

## 14. PHYSICAL TEST DEVICE & ENVIRONMENT

* **Device**: AYN Odin 2 Portal
* **SoC**: Qualcomm Snapdragon 8 Gen 2 (SM8550-AB)
* **GPU**: Qualcomm Adreno 740
* **OS / API**: Android 13 (API Level 33)
* **Java Runtime**: OpenJDK 25 (Environment: `External-25` / `amethyst://External-25`)
* **Minecraft Version**: 26.2
* **Mod Loader**: Fabric Loader 0.19.3
* **Renderer**: `opengles3_desktopgl_zink_kopper`
* **Turnip Driver**: `vulkan.purple.so` (mr_pu 26.1.0-t26-1.4.3-77488fa4)
* **Shaderpack**: Complementary Reimagined r5.8.1 (Preset: Medium / RP Support: Off)
* **Super Resolution**: SGSR1 at 50% scale (Internal: 960x540, Output: 1920x1080)
* **Network / ADB**: Wi-Fi ADB has been used at `192.168.1.187:5555` (*Session-specific; verify connection via `adb devices` before operations*).

### Testing Protocol:
1. The developer/agent prepares builds, pushes JARs/APKs, and sets configuration properties.
2. **The USER manually launches Minecraft, selects the profile, enters the test world, and executes gameplay.**
3. The agent pulls logs (`latestlog.txt`, `latest.log`, `logcat`) after the user exits the world cleanly.
4. **The agent MUST NEVER autonomously launch Minecraft or automate world entry.**

---

## 15. VERIFIED BUILD COMMANDS

### 1. Amethyst Launcher (APK & Native Interposer):
* **Working Directory**: `C:\Proyectos\amethyst`
* **JDK**: Android Studio Embedded JBR / OpenJDK 21
* **Command**:
  ```powershell
  $env:JAVA_HOME="C:\Program Files\Android\Android Studio\jbr"
  .\gradlew.bat assembleDebug --offline
  ```
* **Output APK**: `app_pojavlauncher\build\outputs\apk\debug\app_pojavlauncher-debug.apk`
* **Output Native SO**: `app_pojavlauncher\build\intermediates\stripped_native_libs\debug\stripDebugDebugSymbols\out\lib\arm64-v8a\liblsfg-vulkan-interposer.so`

### 2. SuperResolution Mod (Fabric JAR):
* **Working Directory**: `C:\Proyectos\SGSR`
* **JDK**: OpenJDK 25 (`C:\Program Files\Java\jdk-25` or Android Studio JBR)
* **Commands**:
  ```powershell
  $env:JAVA_HOME="C:\Program Files\Android\Android Studio\jbr"
  .\gradlew.bat :common:test --rerun-tasks --offline
  .\gradlew.bat assemble --offline
  git diff --check
  ```
* **Output JAR**: `fabric\build\libs\super_resolution-fabric-26.2-0.9.1-alpha.2+dev.*.opengl.jar`

### 3. Native LSFG Minecraft Backend (`liblsfg-minecraft.so`):
* **Working Directory**: `C:\Proyectos\LS-FG\minecraft-mod`
* **Command**:
  ```powershell
  $env:JAVA_HOME="C:\Program Files\Android\Android Studio\jbr"
  .\gradlew.bat buildNativeArm64 --offline
  ```
* **Output SO**: `minecraft-mod\src\main\resources\native\android-arm64\liblsfg-minecraft.so`

---

## 16. NATIVE REPRODUCIBILITY TECHNICAL DEBT

> [!NOTE]
> `liblsfg-minecraft.so` currently requires build assets and submodules located across **both** `C:\Proyectos\SGSR` and `C:\Proyectos\LS-FG` (specifically `lsfg-vk-android`, `dxbc`, `pe-parse`, `volk`, and `toml11`).  
> `C:\Proyectos\SGSR` is **NOT yet standalone** for building `liblsfg-minecraft.so` from scratch. Prebuilt native binaries are synced from `C:\Proyectos\LS-FG`.

---

## 17. ARTIFACT MATRIX

| Artifact Description | Location / Path | Status |
| :--- | :--- | :--- |
| **Validated SGSR1 + Bridge V1 JAR** | `/sdcard/Android/data/com.vairacing.amethystplus/files/custom_instances/Fabric/mods/super_resolution-android-sgsr1-mc26.2-r1.jar.bak` | `VALIDATED` (SHA256: `1cee88c919...`) |
| **V2A Testing JAR** | `C:\Proyectos\SGSR\fabric\build\libs\super_resolution-fabric-26.2-0.9.1-alpha.2+dev.4fa4780a.opengl.jar` | `IMPLEMENTED / UNVALIDATED` |
| **Validated Bridge V1 Amethyst APK** | Built from commit `1586e4c6c18a` | `VALIDATED` |
| **V2A Testing Amethyst APK** | `C:\Proyectos\amethyst\app_pojavlauncher\build\outputs\apk\debug\app_pojavlauncher-debug.apk` | `IMPLEMENTED / UNVALIDATED` |

---

## 18. ABSOLUTE DO-NOT-DO LIST

* ❌ **DO NOT** modify standard Fabric Loader.
* ❌ **DO NOT** re-introduce private Zink dispatch patching or memory scanning.
* ❌ **DO NOT** replace or bypass the Amethyst `VULKAN_PTR` redirection mechanism.
* ❌ **DO NOT** enable `-XX:+UseZGC` during LSFG validation runs.
* ❌ **DO NOT** enable `AMETHYST_LSFG_DIAGNOSTICS=1` in normal tests.
* ❌ **DO NOT** perform JNI calls, memory allocations, or `getenv`/`dlsym` lookups per frame.
* ❌ **DO NOT** acquire `g_stateMutex` while invoking real Vulkan driver entry points.
* ❌ **DO NOT** call `vkDeviceWaitIdle` or `vkQueueWaitIdle` per frame.
* ❌ **DO NOT** couple the Vulkan bridge ABI to SGSR1-specific identifiers.
* ❌ **DO NOT** implement Phase V2B before Phase V2A is physically validated on device.
* ❌ **DO NOT** make V2A or V2B dependent on `mods/Lossless.dll`.
* ❌ **DO NOT** merge unvalidated feature branches into `main`.

---

## 19. HOW CODEX SHOULD START

When starting a new session in this workspace, follow this exact sequence:

1. **Read this handoff document completely** (`C:\Proyectos\SGSR\LSFG_ANDROID_HANDOFF.md`).
2. **Inspect git status and uncommitted diffs** in all three workspaces:
   * `git -C C:\Proyectos\SGSR status`
   * `git -C C:\Proyectos\amethyst status`
   * `git -C C:\Proyectos\LS-FG status`
3. **DO NOT discard uncommitted V2A work**.
4. **Verify current code against Section 11 (V2A Pre-Physical Checklist)**.
5. **Execute tests and builds**:
   * Verify 54 SGSR unit tests pass: `.\gradlew.bat :common:test --rerun-tasks --offline`
   * Verify Amethyst builds cleanly: `.\gradlew.bat assembleDebug --offline`
6. **Present the verified V2A diff to the user** and obtain approval before requesting physical installation.
7. **Never launch Minecraft automatically**; instruct the user to run the physical test on the Odin 2 Portal.

---

**CURRENT NEXT TASK**:
Finish the V2A pre-physical ABI/lifetime corrections, rebuild Amethyst + SuperResolution, review the diff, and obtain approval before installing. **DO NOT IMPLEMENT V2B YET.**
