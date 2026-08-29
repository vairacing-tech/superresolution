# LSFG V2B.1B — Continuous 1:1 Duplicate-Frame Active Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement and verify milestone **LSFG V2B.1B (Continuous 1:1 Duplicate-Frame Active Transport)** by enabling continuous active presentation doubling ($M \rightarrow N$) across all eligible application frames in the Amethyst Vulkan interposer, while strictly preserving V2B.0 FIFO and V2B.1A single-shot baseline behaviors as zero-rebuild rollbacks.

**Architecture:** Amethyst (`liblsfg-vulkan-interposer.so`) intercepts every `vkQueuePresentKHR(N)` call. When `AMETHYST_LSFG_V2B1_ACTIVE=2` is latched at initialization:
1. Interposer evaluates eligibility (`swapchainCount == 1`, `pNext == nullptr`, valid swapchain transport state, FIFO mode active, `!transport.generationDisabled`).
2. Interposer performs non-blocking fence polling on double-buffered `TransportSlot` execution contexts (`vkGetFenceStatus`). If a slot is in flight, the alternative slot is tested. If no slot is free, interposer performs a non-blocking pre-commit fail-open to V2B.0 FIFO pass-through.
3. Interposer executes non-blocking `vkAcquireNextImageKHR(timeout=0)` to acquire next image index $M$. If `VK_NOT_READY` or `VK_TIMEOUT`, interposer safely fails-open to V2B.0 FIFO pass-through with zero slot/fence state mutation.
4. If $M$ is acquired:
   - **Invariant Check:** If $M == N$, interposer logs transport invariant violation, marks `transport.generationDisabled = true`, and presents $N$ exactly ONCE via original application info (zero double presents of the same image index).
   - **Normal Path ($M \neq N$):** Interposer records GPU hardware copy `vkCmdCopyImage` ($N \rightarrow M$) on Queue 0, resets `slot.copyFence`, and submits the copy workload waiting on all original application render semaphores ($S_{\text{app\_render}}$) plus `slot.extraAcquireSemaphore`.
5. Copy submission signals `generatedPresentReady[M]`, `realPresentReady[N]`, and `slot.copyFence`.
6. Interposer calls `realQueuePresentKHR(M)` waiting on `generatedPresentReady[M]`.
7. Interposer calls `realQueuePresentKHR(N)` waiting on `realPresentReady[N]`.
8. Caller receives the semantic `VkResult` of original present $N$, preserving caller `pResults`.
9. The cycle repeats continuously for every subsequent application frame without per-frame allocations, blocking waits, or semaphore lifetime violations.

**Tech Stack:** C++20, Android NDK (r27b / clang), Vulkan 1.3 Loader APIs, POSIX environment variables, PowerShell contract testing, Gradle (Amethyst Plus).

**Spec Reference:** [`C:\Proyectos\SGSR\docs\superpowers\specs\2026-08-28-lsfg-v2b1-duplicate-frame-active-transport-design.md`](file:///C:/Proyectos/SGSR/docs/superpowers/specs/2026-08-28-lsfg-v2b1-duplicate-frame-active-transport-design.md) (Design Commit: `fc6e42de6a911762145c26b485ca07c08a9bcfe6`)

---

## Global Repository & Branch Invariants

| Repository | Path | Required Branch | Target HEAD / Baseline |
| :--- | :--- | :--- | :--- |
| **SGSR** (Primary) | `C:\Proyectos\SGSR` | `feature/android-lsfg-integration` | `47e34c3a80ac8047b0c2ce789a63679261a62106` |
| **Amethyst** (Production) | `C:\Proyectos\amethyst` | `feature/lsfg-vulkan-interposer` | `ac953d2379050f1ac895841d37bfe7103e7b555c` |
| **LS-FG** (Auxiliary) | `C:\Proyectos\LS-FG` | `feature/minecraft-fabric-lsfg` | `e774e932a68388cc2893a03725589b15b12b52b5` |

### Strict Implementation Constraints
- **Direct Continuous 1:1 Mode:** Zero intermediate sparse / every-N-frames phase. Every eligible application frame executes active transport.
- **Single Authoritative Environment Gate:** `AMETHYST_LSFG_V2B1_ACTIVE`
  - `0` or unset: V2B.0 FIFO passive baseline (`V2B1Mode::Disabled`).
  - `1`: V2B.1A single-shot active baseline (`V2B1Mode::SingleShot`).
  - `2`: V2B.1B continuous active transport (`V2B1Mode::Continuous`).
  - Zero secondary environment flags (no `AMETHYST_LSFG_V2B1B_CONTINUOUS`).
- **Strict Presentation Order:** COPY $N \rightarrow M$, THEN PRESENT $M$ (duplicate), THEN PRESENT $N$ (real). $N$ is NEVER presented before copy submission.
- **Binary Semaphore Single-Consumption:** Application wait semaphores ($S_{\text{app\_render}}$) are consumed exactly ONCE by the copy submission and are NEVER passed to real present $N$.
- **Per-Image Presentation Semaphore Lifetime Model:** Presentation semaphores are indexed by swapchain image index (`generatedPresentReady[M]`, `realPresentReady[N]`), sized dynamically to `actualImageCount` (never hardcoded to 4).
- **Non-Blocking Slot Polling:** Reusable `TransportSlot` selection uses non-blocking `vkGetFenceStatus`. Zero `vkWaitForFences` or blocking sleeps on the main presentation thread.
- **Deferred Fence Reset (No Slot Poisoning):** `vkResetFences` is called ONLY immediately before `vkQueueSubmit` after $M$ is acquired ($M \neq N$) and command recording succeeds. Pre-commit fallbacks (`VK_NOT_READY`, `VK_TIMEOUT`, $M == N$) NEVER reset the fence, leaving the slot clean and immediately reusable.
- **$M == N$ Invariant Violation Policy:** If $M == N$, log invariant failure, mark `generationDisabled = true`, and present $N$ exactly ONCE via original application info. Zero duplicate presents of the same image index.
- **Pre-Commit Fail-Open:** If all slots are in-flight or extra acquire returns `VK_NOT_READY` / `VK_TIMEOUT`, pass through immediately to original present $N$ via V2B.0.
- **Concrete Post-Commit Recovery:** Once $M$ is acquired ($M \neq N$), $M$ is never abandoned. If copy submit fails (OOM), recovery path releases $M$ to WSI and disables active transport for that swapchain generation.
- **Zero Real Vulkan Under Mutex:** All `vkAcquireNextImageKHR`, `vkQueueSubmit`, and `vkQueuePresentKHR` calls execute strictly outside `g_stateMutex`.
- **Zero Per-Frame Allocations & Hot-Path Logs:** Zero `malloc`, `new`, or `std::vector` allocations in present hot paths. Diagnostic block `[LSFG-V2B1]` is one-shot.
- **Preserved Historical Counters:** `AcquireNextImageKHR` and `QueuePresentKHR` continue counting intercepted application calls. Separate internal counters track real active operations.

---

## Detailed Task Breakdown

### Task 1: Create V2B.1B Contract and Static Verification Tests

**Repository:** `C:\Proyectos\SGSR`  
**Branch:** `feature/android-lsfg-integration`  
**Files:**
- [NEW] `C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1`

**Interfaces & Contract Scope:**
- Evaluates producer source `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`.
- Verifies single authoritative gate declaration (`AMETHYST_LSFG_V2B1_ACTIVE` with integer values 0, 1, 2), one-shot latch in `lsfg_interposer_init`, zero `getenv` in hot paths.
- Verifies V2B.1A single-shot rollback preservation when `AMETHYST_LSFG_V2B1_ACTIVE=1`.
- Verifies V2B.0 passive rollback preservation when `AMETHYST_LSFG_V2B1_ACTIVE=0` or unset.
- Verifies multiple active transport events allowed per swapchain generation in continuous mode (`mode == V2B1Mode::Continuous`).
- Verifies non-blocking slot search using `vkGetFenceStatus` and pre-commit fail-open if all slots are in flight.
- Verifies deferred fence reset: `vkResetFences` executed only on committed submit path, preventing slot poisoning on `VK_NOT_READY` / `VK_TIMEOUT`.
- Verifies $M == N$ invariant violation handling: zero double presents of the same image index, generation marked disabled, single-present pass-through.
- Verifies exact presentation order: Copy submit $\rightarrow$ Present $M$ $\rightarrow$ Present $N$.
- Verifies single-consumption of application wait semaphores by copy submit.
- Verifies presentation semaphores are image-indexed (`generatedPresentReady[M]`, `realPresentReady[N]`).
- Verifies post-commit failure disables active transport for the current swapchain generation.
- Verifies caller `pResults` preservation and local result handling for $M$.
- Verifies zero real Vulkan calls under `g_stateMutex` and zero per-frame heap allocations.
- Verifies all required V2B.1B telemetry counters present in `lsfg_interposer_log_summary`.
- Verifies V1, V2, V2B.0, and V2B.1A regression invariance.

**Step 1.1 — Write Failing Test First:**
- [ ] Create `C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1` implementing all contract checks and self-tests.
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1 -Stage full
  ```
- [ ] **Expected RED Result:** Self-checks PASS, producer checks FAIL on missing V2B.1B continuous mode handling and multi-event support.

**Step 1.2 — Commit Test Boundary:**
- [ ] Stage `native/lsfg-android/v2b1b_contract_test.ps1`.
- [ ] Commit in SGSR: `test(lsfg): define V2B.1B continuous active transport contract`.

---

### Task 2: Implement V2B.1B Mode Selection and Gating in Interposer

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- Declare mode enumeration and single atomic variable:
  ```cpp
  enum class V2B1Mode : uint32_t {
      Disabled = 0,
      SingleShot = 1,
      Continuous = 2
  };
  std::atomic<V2B1Mode> g_v2b1Mode{V2B1Mode::Disabled};
  ```
- In `lsfg_interposer_init()`:
  - Parse `AMETHYST_LSFG_V2B1_ACTIVE`:
    - `"2"` $\rightarrow$ `g_v2b1Mode.store(V2B1Mode::Continuous)`, `g_v2b1ActiveTransportEnabled.store(true)`.
    - `"1"` $\rightarrow$ `g_v2b1Mode.store(V2B1Mode::SingleShot)`, `g_v2b1ActiveTransportEnabled.store(true)`.
    - `"0"` or unset $\rightarrow$ `g_v2b1Mode.store(V2B1Mode::Disabled)`, `g_v2b1ActiveTransportEnabled.store(false)`.
  - Log initialization mode cleanly.

**Step 2.1 — Run Contract Test to verify progression:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1 -Stage full
  ```
- [ ] **Expected Partial Progress:** Gate latch and mode selection checks PASS.

---

### Task 3: Implement Continuous Transport Slot Recycling and Non-Blocking Selection

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- In `V2B1TransportState`:
  - Add `bool generationDisabled{false};` to track post-commit fault state per swapchain.
- In `interposer_vkQueuePresentKHR`:
  - Condition continuous active transport on:
    `mode != V2B1Mode::Disabled && (mode == V2B1Mode::Continuous || !v2b1Completed) && !transport.generationDisabled && pPresentInfo != nullptr && pPresentInfo->swapchainCount == 1 && pPresentInfo->pNext == nullptr`
  - Implement non-blocking slot search without early fence reset:
    ```cpp
    uint32_t selectedSlot = UINT32_MAX;
    for (uint32_t i = 0; i < transport.kSlotCount; ++i) {
        uint32_t slotIdx = (transport.currentSlot + i) % transport.kSlotCount;
        auto &slot = transport.slots[slotIdx];
        if (slot.copyFence != VK_NULL_HANDLE && transport.getFenceStatus != nullptr) {
            VkResult fenceRes = transport.getFenceStatus(transport.device, slot.copyFence);
            if (fenceRes == VK_SUCCESS) {
                selectedSlot = slotIdx;
                break;
            }
        }
    }
    if (selectedSlot == UINT32_MAX) {
        g_v2b1SlotUnavailable.fetch_add(1, std::memory_order_relaxed);
        g_v2b1Fallback.fetch_add(1, std::memory_order_relaxed);
        return realFunc(queue, pPresentInfo); // Safe pre-commit fail-open
    }
    ```
  - Note: `slot.copyFence` is NOT reset here. It remains signaled until right before `vkQueueSubmit`.

**Step 3.1 — Run Contract Test to verify progression:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1 -Stage full
  ```
- [ ] **Expected Partial Progress:** Slot selection checks PASS.

---

### Task 4: Implement Invariant Violation Handling, Deferred Fence Reset, and Committed Submission

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- In `interposer_vkQueuePresentKHR`:
  - Execute non-blocking acquire:
    `VkResult resAcquire = transport.acquire(transport.device, swapchain, 0, slot.extraAcquireSemaphore, VK_NULL_HANDLE, &M);`
  - If `resAcquire == VK_NOT_READY || resAcquire == VK_TIMEOUT`:
    - Increment `g_v2b1ExtraAcquireNotReady` and `g_v2b1Fallback`.
    - Fail-open immediately: `return realFunc(queue, pPresentInfo);`.
    - (Fence was not reset and semaphore was not signaled; slot remains 100% reusable).
  - If `resAcquire == VK_SUCCESS || resAcquire == VK_SUBOPTIMAL_KHR`:
    - **Handle $M == N$ (Invariant Violation):**
      ```cpp
      if (M == N || M >= transport.imageCount) {
          g_v2b1InvariantViolation.fetch_add(1, std::memory_order_relaxed);
          g_v2b1PostCommitFailure.fetch_add(1, std::memory_order_relaxed);
          {
              std::lock_guard<std::mutex> lock(g_stateMutex);
              g_swapchainTransportState[swapchain].generationDisabled = true;
          }
          if (mode == V2B1Mode::SingleShot) {
              g_v2b1aCompleted.store(true, std::memory_order_relaxed);
          }
          // Single legal present: Present N once with original app info (zero double presents)
          return realFunc(queue, pPresentInfo);
      }
      ```
    - **Committed Submission Path ($M \neq N$):**
      - Record copy command buffer `vkCmdCopyImage`.
      - **Reset copy fence immediately before submit:**
        `transport.resetFences(transport.device, 1, &slot.copyFence);`
      - Submit copy workload with `slot.copyFence`.
      - Advance `transport.currentSlot = (selectedSlot + 1) % transport.kSlotCount;`
      - If in single-shot mode (`mode == V2B1Mode::SingleShot`), set `g_v2b1aCompleted.store(true)`.
      - Present $M$ with `generatedPresentReady[M]`.
      - Present $N$ with `realPresentReady[N]`.
      - Return result of $N$.

**Step 4.1 — Run Contract Test to verify progression:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1 -Stage full
  ```
- [ ] **Expected Partial Progress:** Invariant check, fence reset, and presentation checks PASS.

---

### Task 5: Add Continuous Telemetry Counters to `lsfg_interposer_log_summary()`

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- Declare new atomic counters:
  ```cpp
  std::atomic<uint32_t> g_v2b1SlotUnavailable{0};
  std::atomic<uint32_t> g_v2b1ExtraAcquireNotReady{0};
  std::atomic<uint32_t> g_v2b1InvariantViolation{0};
  std::atomic<uint32_t> g_v2b1GenerationDisabled{0};
  ```
- In `lsfg_interposer_log_summary()`:
  - Add counters to both `LOGI` and `printf`:
    `v2b1Mode=%u v2b1SlotUnavailable=%u v2b1ExtraAcquireNotReady=%u v2b1InvariantViolation=%u v2b1GenerationDisabled=%u`
  - Flush stdout.

**Step 5.1 — Run Contract Test:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1 -Stage full
  ```
- [ ] **Expected Result:** `v2b1b_contract_test.ps1` is 100% GREEN (all checks pass, 0 failures).

---

### Task 6: Run Full Regression Test Matrix Across All Milestones

**Repository:** `C:\Proyectos\SGSR`  
**Files:**
- `C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1`
- `C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1`
- `C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1`
- `C:\Proyectos\SGSR\native\lsfg-android\v2a1_contract_test.ps1`

**Step 6.1 — Run All Contract Test Suites:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1b_contract_test.ps1 -Stage full
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Stage full
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Stage full
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2a1_contract_test.ps1 -Stage full
  ```
- [ ] **Expected Result:**
  - `v2b1b_contract_test.ps1`: PASS (0 failures)
  - `v2b1a_contract_test.ps1`: PASS (0 failures)
  - `v2b0_contract_test.ps1`: PASS (0 failures)
  - `v2a1_contract_test.ps1`: PASS (0 failures)

**Step 6.2 — Commit Amethyst Implementation:**
- [ ] Stage `app_pojavlauncher/src/main/jni/lsfg_vulkan_interposer.cpp`.
- [ ] Commit in Amethyst: `feat(interposer): implement V2B.1B continuous 1:1 active transport`.

---

### Task 7: Clean Detached Worktree Build and Binary Provenance Gate

**Repository:** `C:\Proyectos\amethyst`  
**Output Path:** `C:\Users\CJF\AppData\Local\Temp\lsfg_v2b1b_repro\clean-v2b1b.apk`

**Step 7.1 — Create Detached Worktree & Build Offline:**
- [ ] Create detached worktree `C:\Proyectos\amethyst-build-v2b1b` from exact Amethyst HEAD.
- [ ] Copy `local.properties` and update submodules.
- [ ] Run `.\gradlew.bat :app_pojavlauncher:assembleDebug --offline`.
- [ ] Verify `BUILD SUCCESSFUL`.

**Step 7.2 — Stage APK & Verify Hash:**
- [ ] Copy output APK to `C:\Users\CJF\AppData\Local\Temp\lsfg_v2b1b_repro\clean-v2b1b.apk`.
- [ ] Remove temporary worktree `C:\Proyectos\amethyst-build-v2b1b`.
- [ ] Compute SHA-256 and size of `clean-v2b1b.apk`.
- [ ] Verify package `com.vairacing.amethystplus.debug` and debug certificate.

**Step 7.3 — Binary Provenance Comparison:**
- [ ] Compare `clean-v2b1b.apk` against baseline `clean-v2b1a.apk` (`C63AD6D143919FDC2FC638A9172F51D62893235360EB38DE75D0708ADA6F076C`).
- [ ] Verify 0 added entries, 0 removed entries, `classes.dex` and assets identical, and only native interposer `.so` binaries updated.

---

## Verification Plan

### Automated Contract Tests
- `v2b1b_contract_test.ps1`: Full contract verification for continuous 1:1 transport, single authoritative gate, deferred fence reset, $M == N$ invariant violation handling, and fault generation disabling.
- `v2b1a_contract_test.ps1`: Regression verification for single-shot limiter behavior.
- `v2b0_contract_test.ps1`: Regression verification for FIFO override baseline.
- `v2a1_contract_test.ps1`: Regression verification for metadata snapshot completeness.

### Future Physical Device Verification (Post-Implementation)
- Deploy `clean-v2b1b.apk` to AYN Odin 2 Portal via `adb install -r`.
- Configure `custom_env.txt`:
  ```
  AMETHYST_LSFG_VULKAN_INTERPOSER=1
  AMETHYST_LSFG_V2B0_FIFO=1
  AMETHYST_LSFG_V2B1_ACTIVE=2
  ```
- User manually opens Sampiland 2 test in Mundo nuevo for 30–60 seconds.
- Physical Acceptance Criteria:
  - `v2b1CopySubmit == v2b1GeneratedPresent == v2b1OriginalPresent == v2b1ExtraAcquireSuccess >> 1`
  - `QueuePresentKHR` remains application-facing count ($N_{\text{app}}$).
  - Zero cyclic semaphore validation errors, zero ANRs, zero crashes.
  - Visually normal gameplay, clean shutdown with exit code 0.
