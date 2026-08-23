# Super Resolution Temporal Pipeline Architecture

This document defines the temporal data model, reprojection requirements, history buffer lifecycle, and future Frame Generation boundaries for Super Resolution in Minecraft (Fabric/Sodium/Iris/OpenGL).

---

## 1. Overview & Data Flow

In temporal super-resolution and temporal shaderpack rendering (e.g., Temporal Anti-Aliasing, Screen Space Reflections, Water Reflections), rendering relies on state across successive frames:

```
+--------------------------------------------------------------------------------+
| FRAME N-1                                                                      |
| - Scene Resolution: W_prev x H_prev                                            |
| - Camera Matrices: gbufferPreviousModelView, gbufferPreviousProjection         |
| - Camera Position: previousCameraPosition                                      |
| - Persistent Textures: colortex2 (TAA), colortex7 (Reflections), colortex5     |
+---------------------------------------+----------------------------------------+
                                        |
                                        v
+--------------------------------------------------------------------------------+
| FRAME N (Level Rendering)                                                      |
| - Scene Resolution: W_curr x H_curr (e.g. 960x540 at 50% scale)                |
| - Camera Matrices: gbufferModelView, gbufferProjection                         |
| - Camera Position: cameraPosition                                              |
| - Scene Depth: depthtex0 (solid), depthtex1 / noTranslucents (pre-translucent) |
| - Reprojection: Screen UV -> Clip -> View -> World -> PrevClip -> PrevUV       |
| - Temporal Filter: mix(historySample, currentSample, blendFactor)              |
+---------------------------------------+----------------------------------------+
                                        |
                                        v
+--------------------------------------------------------------------------------+
| SR UPSCALE DISPATCH & FINAL BLIT                                               |
| - Dispatch Resource: colorTexture (960x540), depthTexture (960x540)            |
| - Upscale Output: outFbo (1920x1080)                                           |
| - Blit: outFbo -> originRenderTarget (1920x1080)                               |
+---------------------------------------+----------------------------------------+
                                        |
                                        v
+--------------------------------------------------------------------------------+
| NATIVE HUD / GUI PASS                                                          |
| - Target: originRenderTarget (1920x1080 native)                                |
| - Renders crisp 2D user interface, chat, menus without upscaling artifacts     |
+--------------------------------------------------------------------------------+
```

---

## 2. Temporal Data Model

### A. Current Frame Data
- **Scene Color (`colortex0` / `SRMainRenderTarget`)**: Low-resolution scene color before HUD composition.
- **Scene Depth (`depthtex0`)**: Opaque geometric depth buffer at current internal resolution ($W \times H$).
- **Pre-Translucent Depth (`depthtex1` / `noTranslucents`)**: Opaque depth snapshot captured before water/glass/translucents are rendered. Used for screen-space raymarching and water reflection reprojection.
- **Current Camera Matrices**: View matrix (`gbufferModelView`) and Projection matrix (`gbufferProjection`).
- **Current Camera Position**: World position (`cameraPosition`).

### B. Previous Frame Data
- **Previous History Textures**: Persistent framebuffers (e.g. `colortex2` for TAA, `colortex7` for temporal reflection accumulation, `colortex5` for reflection color).
- **Previous Camera Matrices**: View matrix (`gbufferPreviousModelView`) and Projection matrix (`gbufferPreviousProjection`).
- **Previous Camera Position**: World position (`previousCameraPosition`).

### C. Motion & Reprojection Coordinates
Screen-space reprojection maps a current-frame texel $(u, v, z)$ back to the corresponding previous-frame texel $(u_{prev}, v_{prev})$:

$$\vec{P}_{view} = \text{unproject}(\vec{P}_{screen}, \mathbf{P}_{curr}^{-1})$$
$$\vec{P}_{world} = \mathbf{V}_{curr}^{-1} \vec{P}_{view} + (\vec{C}_{curr} - \vec{C}_{prev})$$
$$\vec{P}_{prev\_clip} = \mathbf{P}_{prev} \mathbf{V}_{prev} \vec{P}_{world}$$
$$\vec{P}_{prev\_screen} = \frac{\vec{P}_{prev\_clip}.xy}{\vec{P}_{prev\_clip}.w} \times 0.5 + 0.5$$

For coherent temporal reprojection:
- Inverse projection $\mathbf{P}_{curr}^{-1}$ and previous projection $\mathbf{P}_{prev}$ must share the same coordinate convention and field of view.
- Internal scene textures must be sampled using normalized $[0, 1] \times [0, 1]$ coordinates or texel coordinates based on current internal resolution ($W_{curr}, H_{curr}$).

---

## 3. UI / HUD Separation
To maintain maximum sharpness:
1. **Level Rendering** executes entirely into `SRMainRenderTarget` ($W_{render} \times H_{render}$, e.g. $960 \times 540$).
2. **Super Resolution Upscaler** dispatches at the end of world level rendering to produce full-resolution image in `outFbo` ($W_{screen} \times H_{screen}$, e.g. $1920 \times 1080$).
3. **Blit to Origin Target** transfers the upscaled image into Minecraft's native `mainRenderTarget`.
4. **HUD / GUI Rendering** executes in Minecraft's native resolution ($1920 \times 1080$) directly onto `originRenderTarget`.

No UI pixels are ever fed into the upscaler or temporal history buffers.

---

## 4. History Invalidation Rules

Temporal history state and previous matrix records become **invalid** under any of the following events:
1. **Super Resolution Toggle**: Transition between SR OFF ($1920 \times 1080$ native) and SR ON ($960 \times 540$).
2. **Internal Scale Factor Change**: Changing render scale (e.g. 50% $\leftrightarrow$ 75% $\leftrightarrow$ 100%).
3. **Display / Window Resize**: Window resolution or aspect ratio change.
4. **Shaderpack Reload / Switch**: New pipeline creation or shader program recompile.
5. **Dimension Switch / Teleport**: Sudden large camera or world discontinuity (e.g. Overworld $\to$ Nether).

### Invalidation Protocol
When `TemporalHistoryManager.invalidateHistory(reason)` is triggered:
1. `historyValid` is set to `false`.
2. `resolutionGeneration` is incremented.
3. `framesSinceInvalidation` is reset to `0`.
4. After 1 full frame renders at the new resolution, `historyValid` transitions back to `true`.
5. `TemporalHistoryManager` maintains pure generic lifecycle state and does not hardcode specific shaderpack buffer indices.

---

## 5. Future Frame Generation Architectural Boundaries

When implementing future Frame Generation (interpolating or extrapolating intermediate display frames):

> [!IMPORTANT]
> **Shaderpack temporal history must NOT be blindly reused for Frame Generation.**
> Shaderpacks maintain internal histories tailored for shading effects (e.g., blurred roughness accumulation in `colortex7`). Frame Generation requires independent, pristine full-frame resources.

### Frame Generation Resource Requirements
Future Frame Generation pipelines must maintain dedicated, explicitly tracked resources:
- `SCENE CURRENT COLOR`: Full or upscaled scene color before UI.
- `SCENE PREVIOUS COLOR`: Previous display frame scene color before UI.
- `CURRENT DEPTH` & `PREVIOUS DEPTH`: Depth buffers for disocclusion masking.
- `MOTION VECTORS`: High-precision optical flow or geometric motion vectors ($\Delta u, \Delta v$).
- `CURRENT / PREVIOUS CAMERA MATRICES`: Exact camera transforms for perspective warp.
- `JITTER OFFSETS`: Sub-pixel phase offsets if TAA jitter is active.
- `FRAME INDEX / TIMESTAMP`: Exact presentation delta time.
- `UI / HUD SEPARATION`: UI must be rendered after intermediate frame interpolation.
- `HISTORY VALIDITY`: Invalidation signals must discard interpolation during cuts/teleports.

---

## 6. Diagnostic Distinction: Bad Reprojection vs. Missing Current-Frame Writes

When inspecting temporal visual artifacts (such as stale water reflections or TAA smearing), it is critical to distinguish two fundamentally different failure modes:

### A. Stale History Due to Bad Reprojection
- **Mechanism**: The current frame producer is actively writing new data every frame. However, the temporal filter reprojects the previous frame incorrectly (e.g., mismatched projection matrix, wrong motion vectors, incorrect depth unprojection, or distorted UV texel sizes).
- **Symptom**: New reflections or scene changes appear immediately, but trailing edges or moving geometry exhibit smearing, shearing, or trailing ghost contours.

### B. Stale History Due to Missing Current-Frame Writes
- **Mechanism**: The upstream pass (e.g. `deferred1` writing `colortex5`/`gaux2`, `copyPreTranslucentDepth` copying into `noTranslucents`/`depthtex1`, or `gbuffers_water` raymarching) **stops producing or writing valid new data** while Super Resolution is active.
- **Symptom**: New reflections or scene updates do not appear at all. The persistent history buffer (`colortex7`) continues to hold whatever was written before SR was enabled, creating an apparent static "ghost" that never updates regardless of camera rotation.
- **Verification**: Check pixel changes in `colortex5` and `colortex7` across frames (`[SR-REFLECTION-WRITE]`), verify pre-translucent depth copy success (`[SR-DEPTH-COPY]`), and verify framebuffer completeness (`[SR-REFLECTION-FBO]`).

---

## 7. Depth Format Contract & Iris `copyPreTranslucentDepth` Integration

During Iris shaderpack execution with water reflections enabled (e.g. Complementary Reimagined `Water Reflection Quality = Medium/Potato`), Iris captures a pre-translucent depth snapshot via `RenderTargets.copyPreTranslucentDepth()`.

### Failure Mechanism (Internal Format Mismatch)
- Iris creates its `noTranslucents` (`depthtex1`) target matching Minecraft's native depth format contract (`D32_FLOAT` $\to$ `GL_DEPTH_COMPONENT32F`).
- When `SRMainRenderTarget` allocated its depth texture using an incompatible internal format (e.g. `DEPTH32` $\to$ `GL_DEPTH_COMPONENT32`), the OpenGL copy operation (`glCopyImageSubData` under `Gl43CopyImage` strategy) failed every frame with:
  ```text
  GL_INVALID_OPERATION in glCopyImageSubData(internalFormat mismatch)
  ```
- As a consequence, `depthtex1` received no updated geometric depth, causing `gbuffers_water` raymarching to fail and stop generating fresh reflection data into `colortex5`/`colortex7`. The stale reflection appearance was a secondary consequence of the failed pre-translucent depth copy.

### Architectural Resolution
- `SRMainRenderTarget` dynamically queries the origin Minecraft render target depth format (`getPreferredDepthFormat()`) and propagates the exact matching `TextureFormat` (`DEPTH32F`, `DEPTH24_STENCIL8`, `DEPTH32F_STENCIL8`, etc.).
- `GpuTextureAdapter` maps the `TextureFormat` to the exact Mojang `GpuFormat` (`toMojangGpuFormat()`), preserving format equality across all pipeline stages.