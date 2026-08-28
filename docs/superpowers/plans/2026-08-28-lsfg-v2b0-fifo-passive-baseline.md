# LSFG V2B.0 — FIFO Passive Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement and verify milestone **LSFG V2B.0 (FIFO Passive Baseline)** by adding a latched opt-in runtime gate, driver-authoritative FIFO capability resolution, and safe swapchain creation present-mode override to the Amethyst Vulkan interposer, while keeping all presentation strictly passive and maintaining complete compatibility with the validated V2A.1.1 baseline.

**Architecture:** Amethyst (`liblsfg-vulkan-interposer.so`) serves as the Vulkan producer. When `AMETHYST_LSFG_V2B0_FIFO=1` is set, the interposer intercepts `vkCreateSwapchainKHR`, queries surface present modes outside `g_stateMutex`, verifies FIFO support, creates a local shallow copy of `VkSwapchainCreateInfoKHR` with `presentMode = VK_PRESENT_MODE_FIFO_KHR`, calls the real Vulkan driver, records the effective present mode in authoritative metadata, and logs a one-shot `[LSFG-V2B0]` diagnostic block. SGSR and LS-FG consumers remain untouched and strictly passive.

**Tech Stack:** C++20, Android NDK (r27b / clang), Vulkan 1.3 Loader APIs, POSIX environment variables, PowerShell contract testing, Gradle (Amethyst Plus).

**Spec Reference:** [`C:\Proyectos\SGSR\docs\superpowers\specs\2026-08-28-lsfg-v2b0-fifo-passive-baseline-design.md`](file:///C:/Proyectos/SGSR/docs/superpowers/specs/2026-08-28-lsfg-v2b0-fifo-passive-baseline-design.md)

---

## Global Repository & Branch Invariants

| Repository | Path | Required Branch | Target HEAD / Baseline |
| :--- | :--- | :--- | :--- |
| **SGSR** (Primary) | `C:\Proyectos\SGSR` | `feature/android-lsfg-integration` | `165f3d578a148e6b6dc2f48e99d6433cb9eb12b7` |
| **Amethyst** (Auxiliary) | `C:\Proyectos\amethyst` | `feature/lsfg-vulkan-interposer` | `61409f86c5be3e821b0755fd53a451645fa0691a` |
| **LS-FG** (Auxiliary) | `C:\Proyectos\LS-FG` | `feature/minecraft-fabric-lsfg` | `e774e932a68388cc2893a03725589b15b12b52b5` |

### Strict Implementation Constraints
- **Zero Real Vulkan Under Mutex:** No calls to `g_realGipa`, `g_realGdpa`, `realCreateSwapchain`, `realGetModes`, or `realGetCaps` while holding `g_stateMutex`.
- **Passivity Preservation:** Exactly 1 application acquire and 1 application present per frame. Zero injected command buffers, queue submissions, duplicate frames, copies, blits, or compute shaders.
- **Fail-Open by Default:** Any query failure, unmapped surface/device, or missing FIFO capability falls back immediately to the application's original `VkSwapchainCreateInfoKHR`.
- **Zero Production Consumer Changes:** No modifications to `C:\Proyectos\LS-FG` or `C:\Proyectos\SGSR` runtime source code.
- **Clean Artifact Isolation:** Physical debug APK must be compiled from an isolated detached worktree at clean commit HEAD.

---

## Detailed Task Breakdown

### Task 1: Create V2B.0 Contract and Static Verification Tests

**Repository:** `C:\Proyectos\SGSR`  
**Branch:** `feature/android-lsfg-integration`  
**Files:**
- [NEW] `C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1`

**Interfaces & Contract Scope:**
- Evaluates producer source `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`.
- Verifies gate declaration (`AMETHYST_LSFG_V2B0_FIFO`), one-shot latch in `lsfg_interposer_init`, no `getenv` in hot paths.
- Verifies fail-open branches and shallow local copy in `interposer_vkCreateSwapchainKHR`.
- Verifies thread safety and driver isolation (zero real Vulkan calls under `g_stateMutex`).
- Verifies one-shot `[LSFG-V2B0]` diagnostic labels and summary counters.
- Verifies V1/V2 ABI layout invariance and ensures `v2a1_contract_test.ps1` passes with zero regressions.

**Step 1.1 — Write Failing Test First:**
- [ ] Create `C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1` with self-checks and producer assertions for V2B.0 gate, capability query, override, locking, and diagnostic blocks.
- [ ] **Run Command:**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Stage producer
  ```
- [ ] **Expected RED Result:** Test fails with non-zero exit code (`FAIL [producer] AMETHYST_LSFG_V2B0_FIFO gate definition missing`, `FAIL [producer] FIFO capability resolution missing`).

**Step 1.2 — Commit Test Boundary:**
- [ ] Stage `native/lsfg-android/v2b0_contract_test.ps1`.
- [ ] Commit: `test(lsfg): add V2B.0 FIFO passive baseline contract tests`.

---

### Task 2: Implement Latched V2B.0 Runtime Gate

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- Declare global atomic gate: `std::atomic<bool> g_v2b0FifoEnabled{false};`
- In `lsfg_interposer_init(void *realVulkanHandle)`:
  - Read `getenv("AMETHYST_LSFG_V2B0_FIFO")`.
  - If value is `"1"` or `"true"` (case-insensitive), set `g_v2b0FifoEnabled.store(true, std::memory_order_relaxed)`.
  - Log gate status: `LOGI("[LSFG-VK] V2B.0 FIFO gate: %s", g_v2b0FifoEnabled.load() ? "ENABLED" : "DISABLED");`.

**Step 2.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Check gate
  ```
- [ ] **Expected Result:** Gate checks PASS; capability/override checks remain RED.

**Step 2.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): latch AMETHYST_LSFG_V2B0_FIFO runtime gate at init`.

---

### Task 3: Implement FIFO Support Resolution & Fail-Open Logic

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- In `interposer_vkCreateSwapchainKHR`:
  - Check `g_v2b0FifoEnabled.load(std::memory_order_relaxed)`.
  - If gate is enabled and `pCreateInfo != nullptr` and `pCreateInfo->presentMode != VK_PRESENT_MODE_FIFO_KHR`:
    - Resolve `physicalDevice`, `instance`, and `realGetModes` PFN from state maps under `g_stateMutex`.
    - **Release `g_stateMutex`**.
    - Invoke `QueryAllPresentModes(realGetModes, physDev, pCreateInfo->surface, supportedModes)` outside mutex.
    - Check if `VK_PRESENT_MODE_FIFO_KHR` is present in `supportedModes`.
    - If resolution fails or FIFO is absent, set fallback reason and proceed with original `pCreateInfo` (Fail Open).

**Step 3.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Check capability
  ```
- [ ] **Expected Result:** Capability resolution and fail-open branch checks PASS.

**Step 3.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): add driver-authoritative FIFO capability resolution`.

---

### Task 4: Implement Safe Local VkSwapchainCreateInfoKHR Override

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- When FIFO override is eligible:
  - Construct shallow local stack copy: `VkSwapchainCreateInfoKHR effectiveCreateInfo = *pCreateInfo;`
  - Assign `effectiveCreateInfo.presentMode = VK_PRESENT_MODE_FIFO_KHR;`
  - Pass `&effectiveCreateInfo` to the real driver call: `realFunc(device, &effectiveCreateInfo, pAllocator, pSwapchain);`
- When FIFO override is not eligible (gate OFF, already FIFO, or fallback):
  - Pass `pCreateInfo` unchanged to `realFunc(device, pCreateInfo, pAllocator, pSwapchain);`
- Ensure `oldSwapchain`, `pNext`, and `pQueueFamilyIndices` pointers are preserved verbatim.
- If real driver creation fails, immediately return error code without committing metadata.

**Step 4.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Check override
  ```
- [ ] **Expected Result:** CreateInfo override and const-correctness checks PASS.

**Step 4.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): safely override swapchain createInfo presentMode to FIFO`.

---

### Task 5: Implement Authoritative Effective-Mode Metadata & Generation

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- In `SwapchainMetadata`:
  - Add `VkPresentModeKHR requestedPresentMode = VK_PRESENT_MODE_MAILBOX_KHR;`
  - Add `bool fifoOverrideApplied = false;`
  - Ensure `SwapchainMetadata.presentMode` records the **effective** present mode (`effectiveCreateInfo.presentMode`).
- In `lsfg_interposer_bridge_get_snapshot_v2`:
  - `snapshot.presentMode` reports `pMeta->presentMode` (the authoritative effective mode).
- In `interposer_vkCreateSwapchainKHR`:
  - Commit metadata under `g_stateMutex` only after successful swapchain creation.
  - Increment `g_metadataGeneration.fetch_add(1, std::memory_order_relaxed)` upon successful creation.

**Step 5.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Check metadata
  ```
- [ ] **Expected Result:** Effective metadata and generation increment checks PASS.

**Step 5.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): commit effective present mode and maintain generation integrity`.

---

### Task 6: Implement One-Shot [LSFG-V2B0] Diagnostics & Summary Counters

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- Declare V2B.0 atomic counters:
  - `g_v2b0SwapchainCreateEligible`
  - `g_v2b0FifoOverrideApplied`
  - `g_v2b0FifoFallback`
  - `g_v2b0UnexpectedActiveTransport` (0)
- In `interposer_vkCreateSwapchainKHR`:
  - Emit one-shot `[LSFG-V2B0]` diagnostic block containing: `gateEnabled`, `swapchain`, `surface`, `appRequestedMode`, `effectiveMode`, `fifoSupported`, `queryResult`, `overrideApplied`, `fallbackReason`, `requestedMinImageCount`, `actualImageCount`, `imageUsage`, `extent`, `format`, `colorSpace`.
- In `lsfg_interposer_log_summary()`:
  - Include `v2b0Gate`, `v2b0Eligible`, `v2b0Override`, `v2b0Fallback`, `v2b0ActiveTransport` in logcat and stdout output.

**Step 6.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Check diagnostics
  ```
- [ ] **Expected Result:** Diagnostic format and summary counter checks PASS.

**Step 6.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): add one-shot LSFG-V2B0 diagnostics and summary counters`.

---

### Task 7: Full Contract, Locking, Passivity & ABI Regression Audit

**Repository:** `C:\Proyectos\SGSR` & `C:\Proyectos\amethyst`  
**Branch:** `feature/android-lsfg-integration` & `feature/lsfg-vulkan-interposer`  
**Files:**
- Audit `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`
- Test `C:\Proyectos\SGSR\native\lsfg-android\v2a1_contract_test.ps1`
- Test `C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1`

**Verification Steps:**
- [ ] **Run Command 1 (V2B.0 Contract Full):**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Stage full
  ```
  **Expected Result:** `V2B.0 CONTRACT: PASS` (0 failures).
- [ ] **Run Command 2 (V2A.1 Regression Check):**
  ```powershell
  pwsh -NoProfile -File C:\Proyectos\SGSR\native\lsfg-android\v2a1_contract_test.ps1 -Stage full
  ```
  **Expected Result:** `V2A.1 CONTRACT: PASS` (0 failures, proves zero V2A regressions).
- [ ] **Run Command 3 (Locking & Driver Call Audit):**
  Assert zero occurrences of driver invocation functions inside `std::lock_guard<std::mutex>` blocks.

---

### Task 8: Build Clean Amethyst Debug APK in Isolated Worktree

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  

**Execution Steps:**
- [ ] Ensure all working-tree changes on `feature/lsfg-vulkan-interposer` are committed.
- [ ] Create a detached, clean temporary worktree at current commit HEAD:
  ```powershell
  git -C C:\Proyectos\amethyst worktree add C:\Proyectos\amethyst-build-v2b0 HEAD
  ```
- [ ] Compile Debug APK in isolated worktree:
  ```powershell
  Set-Location C:\Proyectos\amethyst-build-v2b0
  .\gradlew.bat assembleDebug --offline
  ```
- [ ] Clean up build worktree:
  ```powershell
  Set-Location C:\Proyectos\SGSR
  git -C C:\Proyectos\amethyst worktree remove C:\Proyectos\amethyst-build-v2b0 --force
  ```
- [ ] Verify output APK exists: `C:\Proyectos\amethyst\app_pojavlauncher\build\outputs\apk\debug\app_pojavlauncher-debug.apk`.
- [ ] Compute SHA-256 hash of new APK.

---

### Task 9: APK Binary Diff & Provenance Verification Gate

**Repository:** `C:\Proyectos\amethyst`  

**Execution Steps:**
- [ ] Compare entry table and CRC-32 checksums of new V2B.0 APK against validated V2A.1.1 baseline APK.
- [ ] Prove that the **only** modified binary artifact inside the APK is:
  `lib/arm64-v8a/liblsfg-vulkan-interposer.so`
- [ ] Assert that no DEX bytecode, Java assets, third-party shared libraries, or AndroidManifest entries differ.
- [ ] Document exact SHA-256 hashes and entry classifications in provenance record.

---

### Task 10: Prepare Physical Installation Procedure (Deploy Hold)

**Files & Target:**
- Prepare exact ADB installation commands and `custom_env.txt` configuration for the user.
- **DO NOT EXECUTE** ADB commands or install the APK.

**Procedure Documentation:**
1. **Enable Gate on Odin 2 Portal:**
   Add `AMETHYST_LSFG_V2B0_FIFO=1` to `/sdcard/Android/data/com.vairacing.amethystplus.debug/files/custom_env.txt`.
2. **Install Command (Awaiting User Approval):**
   ```powershell
   adb install -r C:\Proyectos\amethyst\app_pojavlauncher\build\outputs\apk\debug\app_pojavlauncher-debug.apk
   ```
3. **Logcat Capture Filter:**
   ```powershell
   adb logcat -c; adb logcat -s LSFG-VK:I LSFG-V2B0:I LSFG-V2A1:I LSFG-VK-SUMMARY:I
   ```
4. **Physical Acceptance Checklist:**
   - Verify `[LSFG-V2B0]` logs `overrideApplied=true` and `effectiveMode=VK_PRESENT_MODE_FIFO_KHR(2)`.
   - Verify `[LSFG-V2A1]` logs `presentMode=VK_PRESENT_MODE_FIFO_KHR (2)`.
   - Verify `[LSFG-VK-SUMMARY]` logs `acquire == present`, `acquire2 == 0`, `v2b0Override >= 1`, `v2b0ActiveTransport == 0`.
   - Verify rendering at 1080p SGSR1 50% remains fluid, glitch-free, and error-free.
