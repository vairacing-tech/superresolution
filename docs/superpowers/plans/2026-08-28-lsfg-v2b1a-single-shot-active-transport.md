# LSFG V2B.1A — Single-Shot Active Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement and verify milestone **LSFG V2B.1A (Single-Shot Duplicate-Frame Active Transport)** by adding an opt-in active transport pipeline to the Amethyst Vulkan interposer that performs at most **one** successful active duplicate frame presentation ($M \rightarrow N$) per swapchain generation, while all subsequent application presents pass through via the validated V2B.0 FIFO baseline.

**Architecture:** Amethyst (`liblsfg-vulkan-interposer.so`) intercepts `vkQueuePresentKHR(N)`. When `AMETHYST_LSFG_V2B1_ACTIVE=1` is latched and the single-shot limiter is unconsumed:
1. Interposer validates pre-commit eligibility and selects an idle `TransportSlot`.
2. Interposer performs a non-blocking `vkAcquireNextImageKHR(timeout=0)` to acquire next image index $M$.
3. Interposer records and submits a GPU hardware copy `vkCmdCopyImage` ($N \rightarrow M$) on Queue 0, waiting on all original application render semaphores ($S_{\text{app\_render}}$) plus `slot.extraAcquireSemaphore`.
4. Copy submission signals `generatedPresentReady[M]`, `realPresentReady[N]`, and `slot.copyFence`.
5. Interposer calls `realQueuePresentKHR(M)` waiting on `generatedPresentReady[M]`.
6. Interposer calls `realQueuePresentKHR(N)` waiting on `realPresentReady[N]`.
7. Caller receives the semantic `VkResult` of original present $N$, and the single-shot limiter is consumed.
8. All subsequent application presentations pass through using the validated V2B.0 FIFO passive baseline.

**Tech Stack:** C++20, Android NDK (r27b / clang), Vulkan 1.3 Loader APIs, POSIX environment variables, PowerShell contract testing, Gradle (Amethyst Plus).

**Spec Reference:** [`C:\Proyectos\SGSR\docs\superpowers\specs\2026-08-28-lsfg-v2b1-duplicate-frame-active-transport-design.md`](file:///C:/Proyectos/SGSR/docs/superpowers/specs/2026-08-28-lsfg-v2b1-duplicate-frame-active-transport-design.md) (Design Commit: `fc6e42de6a911762145c26b485ca07c08a9bcfe6`)

---

## Global Repository & Branch Invariants

| Repository | Path | Required Branch | Target HEAD / Baseline |
| :--- | :--- | :--- | :--- |
| **SGSR** (Primary) | `C:\Proyectos\SGSR` | `feature/android-lsfg-integration` | `fc6e42de6a911762145c26b485ca07c08a9bcfe6` |
| **Amethyst** (Auxiliary) | `C:\Proyectos\amethyst` | `feature/lsfg-vulkan-interposer` | `4f27f9fbfe7384ce23a01205dabc272531eaf445` |
| **LS-FG** (Auxiliary) | `C:\Proyectos\LS-FG` | `feature/minecraft-fabric-lsfg` | `e774e932a68388cc2893a03725589b15b12b52b5` |

### Strict Implementation Constraints
- **V2B.1A Scope Only:** At most ONE active duplicate frame presentation per swapchain generation. Zero V2B.1B continuous activation tasks.
- **Strict Presentation Order:** COPY $N \rightarrow M$, THEN PRESENT $M$ (duplicate), THEN PRESENT $N$ (real). $N$ is NEVER presented before the copy workload is submitted.
- **Binary Semaphore Single-Consumption:** Application wait semaphores ($S_{\text{app\_render}}$) are consumed exactly ONCE by the copy submission and are NEVER passed to real present $N$.
- **Resource Separation:** Transport slots (`TransportSlot`) are decoupled from image presentation states (`SwapchainImagePresentationState[actualImageCount]`).
- **Dynamic Resource Sizing:** Presentation semaphores are sized dynamically to `actualImageCount` (never hardcoded to 4).
- **Non-Blocking Acquire:** Extra acquire uses `timeout = 0`. CPU never blocks waiting for a swapchain image.
- **Fail-Open Pre-Commit:** If extra acquire returns `VK_NOT_READY` or `VK_TIMEOUT`, pass through immediately to original present $N$.
- **Concrete Post-Commit Recovery:** Once $M$ is acquired, $M$ is never abandoned. If copy submit fails (OOM), recovery path releases $M$ to WSI. If device lost, mark terminal.
- **Caller Semantics Preservation:** Generated present $M$ uses local `VkResult` and never mutates caller's `pResults`. Original present $N$ updates caller's `pResults`.
- **Zero Real Vulkan Under Mutex:** All `vkAcquireNextImageKHR`, `vkQueueSubmit`, and `vkQueuePresentKHR` calls execute strictly outside `g_stateMutex`.
- **Zero Per-Frame Allocations & Hot-Path Logs:** Zero `malloc`, `new`, or `std::vector` allocations in present hot paths. Diagnostic block `[LSFG-V2B1]` is one-shot.
- **Preserved Historical Counters:** `AcquireNextImageKHR` and `QueuePresentKHR` continue counting intercepted application calls. Separate internal counters track real active operations.

---

## Detailed Task Breakdown

### Task 1: Create V2B.1A Contract and Static Verification Tests

**Repository:** `C:\Proyectos\SGSR`  
**Branch:** `feature/android-lsfg-integration`  
**Files:**
- [NEW] `C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1`

**Interfaces & Contract Scope:**
- Evaluates producer source `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`.
- Verifies gate declaration `AMETHYST_LSFG_V2B1_ACTIVE`, one-shot latch in `lsfg_interposer_init`, no `getenv` in hot paths.
- Verifies initial eligibility checks (`pNext == nullptr`, `swapchainCount == 1`, valid $N$ index, FIFO active, transfer usage flags).
- Verifies pre-acquire resource availability (transport slots, command pool, semaphores, fences).
- Verifies non-blocking extra acquire (`timeout = 0`) and fail-open on `VK_NOT_READY` / `VK_TIMEOUT`.
- Verifies $N \neq M$ assertion and post-commit state boundary.
- Verifies exact presentation order: Copy submit $\rightarrow$ Present $M$ $\rightarrow$ Present $N$.
- Verifies single-consumption of application wait semaphores by copy submit.
- Verifies presentation semaphores are image-indexed (`generatedPresentReady[M]`, `realPresentReady[N]`).
- Verifies single-shot limiter logic (maximum 1 active duplicate per swapchain generation).
- Verifies post-commit recovery paths (OOM handling, device lost terminal propagation).
- Verifies caller `pResults` preservation and local result handling for $M$.
- Verifies zero real Vulkan calls under `g_stateMutex` and zero per-frame heap allocations.
- Verifies V1, V2, and V2B.0 regression invariance.

**Step 1.1 — Write Failing Test First:**
- [ ] Create `C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1` implementing all contract checks and self-tests.
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Stage full
  ```
- [ ] **Expected RED Result:** Self-checks PASS, producer checks FAIL on missing V2B.1A declarations, structures, and transport logic.

**Step 1.2 — Commit Test Boundary:**
- [ ] Stage `native/lsfg-android/v2b1a_contract_test.ps1`.
- [ ] Commit in SGSR: `test(lsfg): define V2B.1A single-shot active transport contract`.

---

### Task 2: Define V2B.1 Data Structures, Telemetry Counters, and Gate Latching

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- Declare V2B.1 data structures:
  ```cpp
  struct TransportSlot {
      VkSemaphore extraAcquireSemaphore{VK_NULL_HANDLE};
      VkFence copyFence{VK_NULL_HANDLE};
      VkCommandBuffer commandBuffer{VK_NULL_HANDLE};
      VkCommandBuffer recoveryCommandBuffer{VK_NULL_HANDLE};
      bool inFlight{false};
  };

  struct SwapchainImagePresentationState {
      VkSemaphore generatedPresentReady{VK_NULL_HANDLE};
      VkSemaphore realPresentReady{VK_NULL_HANDLE};
      VkSemaphore recoveryPresentReady{VK_NULL_HANDLE};
  };

  struct V2B1TransportState {
      bool initialized{false};
      VkDevice device{VK_NULL_HANDLE};
      VkQueue queue{VK_NULL_HANDLE};
      uint32_t queueFamilyIndex{0};
      VkCommandPool commandPool{VK_NULL_HANDLE};

      static constexpr uint32_t kSlotCount = 2;
      TransportSlot slots[kSlotCount];
      uint32_t currentSlot{0};

      uint32_t imageCount{0};
      std::vector<SwapchainImagePresentationState> imagePresentation;
      std::vector<VkImage> swapchainImages;
  };
  ```
- Declare global atomic gate and single-shot flag:
  ```cpp
  std::atomic<bool> g_v2b1ActiveTransportEnabled{false};
  std::atomic<bool> g_v2b1aCompleted{false};
  ```
- Declare dedicated V2B.1 atomic telemetry counters:
  ```cpp
  std::atomic<uint32_t> g_v2b1AppPresentEligible{0};
  std::atomic<uint32_t> g_v2b1ExtraAcquireAttempt{0};
  std::atomic<uint32_t> g_v2b1ExtraAcquireSuccess{0};
  std::atomic<uint32_t> g_v2b1CopySubmit{0};
  std::atomic<uint32_t> g_v2b1GeneratedPresent{0};
  std::atomic<uint32_t> g_v2b1OriginalPresent{0};
  std::atomic<uint32_t> g_v2b1PostCommitFailure{0};
  std::atomic<uint32_t> g_v2b1Fallback{0};
  ```
- In `lsfg_interposer_init(void *realVulkanHandle)`:
  - Read `getenv("AMETHYST_LSFG_V2B1_ACTIVE")`.
  - If `"1"` or `"true"`, store `true` in `g_v2b1ActiveTransportEnabled`.
  - Log gate state: `LOGI("[LSFG-VK] V2B.1 active transport gate: %s", g_v2b1ActiveTransportEnabled.load() ? "ENABLED" : "DISABLED");`.

**Step 2.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Check gate
  ```
- [ ] **Expected Result:** Gate checks PASS.

**Step 2.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): declare V2B.1 transport structures and latch active gate`.

---

### Task 3: Implement Transport Resource Lifecycle in Swapchain Create and Destroy

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- In `interposer_vkCreateSwapchainKHR`:
  - Reset `g_v2b1aCompleted.store(false, std::memory_order_relaxed);` on new swapchain creation.
  - After real swapchain creation succeeds and capabilities/images are queried:
    - If `g_v2b1ActiveTransportEnabled` is ON and effective mode is `VK_PRESENT_MODE_FIFO_KHR`:
      - Allocate `V2B1TransportState` for the swapchain.
      - Create `VkCommandPool` (Queue Family 0, `VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT`).
      - Allocate 2 primary `VkCommandBuffer` handles for copy and 2 for recovery.
      - Create 2 `extraAcquireSemaphore` handles and 2 `copyFence` handles (created in `SIGNALED` state).
      - Allocate `actualImageCount` entries in `imagePresentation`.
      - For each image $j \in [0 .. \text{actualImageCount}-1]$, create `generatedPresentReady[j]`, `realPresentReady[j]`, and `recoveryPresentReady[j]`.
      - Pre-record static `recoveryCommandBuffer[i]` per slot to transition image $M$ to `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR` without copy.
      - Commit `V2B1TransportState` into `g_swapchainTransportState` map under `g_stateMutex`.
- In `interposer_vkDestroySwapchainKHR` and `interposer_vkDestroyDevice`:
  - Extract transport state under `g_stateMutex` and remove map entry.
  - Call `realDeviceWaitIdle(device)` outside mutex.
  - Destroy all semaphores, fences, command buffers, and command pool.

**Step 3.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Check lifecycle
  ```
- [ ] **Expected Result:** Lifecycle and allocation checks PASS.

**Step 3.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): add V2B.1 per-swapchain transport resource lifecycle`.

---

### Task 4: Implement Pre-Commit Eligibility and Bounded Extra Acquire

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- In `interposer_vkQueuePresentKHR`:
  - Count application call: `g_presentCalls.fetch_add(1, std::memory_order_relaxed);`.
  - Check pre-commit eligibility:
    - `g_v2b1ActiveTransportEnabled.load() == true`
    - `g_v2b1aCompleted.load() == false` (single-shot limiter unconsumed)
    - `pPresentInfo != nullptr` && `pPresentInfo->swapchainCount == 1` && `pPresentInfo->pNext == nullptr`
    - Swapchain has valid `V2B1TransportState` with `initialized == true`.
    - Index $N = \text{pPresentInfo->pImageIndices}[0] < \text{actualImageCount}$.
  - If any check fails: pass through to `realQueuePresentKHR(queue, pPresentInfo)`.
  - When eligible:
    - Increment `g_v2b1AppPresentEligible`.
    - Select next slot: `slotIndex = transport.currentSlot % 2`.
    - Verify `copyFence[slotIndex]` is signaled via `vkGetFenceStatus`. If not, wait with 16ms timeout and reset fence.
    - Increment `g_v2b1ExtraAcquireAttempt`.
    - Call `realAcquireNextImageKHR(device, swapchain, 0 /* timeout = 0 */, slot.extraAcquireSemaphore, VK_NULL_HANDLE, &M)`.
    - If acquire returns `VK_NOT_READY` or `VK_TIMEOUT`:
      - Increment `g_v2b1Fallback`.
      - Pass through to `realQueuePresentKHR(queue, pPresentInfo)` (Pre-commit safe exit).
    - If acquire returns `VK_SUCCESS` or `VK_SUBOPTIMAL_KHR`:
      - Increment `g_v2b1ExtraAcquireSuccess`.
      - Assert $N \neq M$. If $N == M$, increment `g_v2b1PostCommitFailure` and enter post-commit recovery.
      - Advance to GPU copy submission.

**Step 4.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Check precommit
  ```
- [ ] **Expected Result:** Pre-commit and extra acquire checks PASS.

**Step 4.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): implement V2B.1A pre-commit checks and non-blocking extra acquire`.

---

### Task 5: Implement GPU Copy Command Buffer Recording and Queue Submission

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- Begin primary command buffer `slot.commandBuffer`:
  - `vkBeginCommandBuffer(cmdBuf, &beginInfo)`.
  - Record pre-copy barriers:
    - $N$: `PRESENT_SRC_KHR` $\rightarrow$ `TRANSFER_SRC_OPTIMAL` (`COLOR_ATTACHMENT_OUTPUT_BIT` $\rightarrow$ `TRANSFER_BIT`, `COLOR_ATTACHMENT_WRITE_BIT` $\rightarrow$ `TRANSFER_READ_BIT`).
    - $M$: `UNDEFINED` $\rightarrow$ `TRANSFER_DST_OPTIMAL` (`TOP_OF_PIPE_BIT` $\rightarrow$ `TRANSFER_BIT`, `0` $\rightarrow$ `TRANSFER_WRITE_BIT`).
  - Record `vkCmdCopyImage`:
    - Full image color aspect copy from image $N$ to image $M$.
  - Record post-copy barriers:
    - $N$: `TRANSFER_SRC_OPTIMAL` $\rightarrow$ `PRESENT_SRC_KHR` (`TRANSFER_BIT` $\rightarrow$ `BOTTOM_OF_PIPE_BIT`, `TRANSFER_READ_BIT` $\rightarrow$ `0`).
    - $M$: `TRANSFER_DST_OPTIMAL` $\rightarrow$ `PRESENT_SRC_KHR` (`TRANSFER_BIT` $\rightarrow$ `BOTTOM_OF_PIPE_BIT`, `TRANSFER_WRITE_BIT` $\rightarrow$ `0`).
  - `vkEndCommandBuffer(cmdBuf)`.
- Build `VkSubmitInfo`:
  - Wait semaphores: All `pPresentInfo->pWaitSemaphores` ($S_{\text{app\_render}}$) with stage `COLOR_ATTACHMENT_OUTPUT_BIT` + `slot.extraAcquireSemaphore` with stage `TRANSFER_BIT`.
  - Command buffers: `&slot.commandBuffer`.
  - Signal semaphores: `imagePresentation[M].generatedPresentReady`, `imagePresentation[N].realPresentReady`.
- Call `realQueueSubmit(queue, 1, &submitInfo, slot.copyFence)`.
- If submit succeeds: increment `g_v2b1CopySubmit`.
- If submit fails (`VK_ERROR_OUT_OF_HOST/DEVICE_MEMORY`): execute recovery path (Task 7).
- If submit fails (`VK_ERROR_DEVICE_LOST`): return `VK_ERROR_DEVICE_LOST` and mark transport terminal.

**Step 5.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Check copy_submit
  ```
- [ ] **Expected Result:** Copy barrier, submission, and semaphore signaling checks PASS.

**Step 5.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): implement V2B.1 GPU copy recording and queue submission`.

---

### Task 6: Implement Two-Phase Presentation ($M \rightarrow N$) and One-Shot Diagnostic Block

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- **Phase 1: Present Duplicate Frame $M$:**
  - Construct local `VkPresentInfoKHR presentInfoM`:
    - `waitSemaphoreCount = 1`, `pWaitSemaphores = &imagePresentation[M].generatedPresentReady`.
    - `swapchainCount = 1`, `pSwapchains = pPresentInfo->pSwapchains`, `pImageIndices = &M`.
    - `pNext = nullptr`, `pResults = &localResultM`.
  - Call `realQueuePresentKHR(queue, &presentInfoM)`.
  - Increment `g_v2b1GeneratedPresent`.
- **Phase 2: Present Original Frame $N$:**
  - Construct local `VkPresentInfoKHR presentInfoN`:
    - `waitSemaphoreCount = 1`, `pWaitSemaphores = &imagePresentation[N].realPresentReady`.
    - `swapchainCount = 1`, `pSwapchains = pPresentInfo->pSwapchains`, `pImageIndices = &N`.
    - `pNext = nullptr`, `pResults = pPresentInfo->pResults` (preserves caller's destination).
  - Call `VkResult resN = realQueuePresentKHR(queue, &presentInfoN)`.
  - Increment `g_v2b1OriginalPresent`.
- **Consume Single-Shot Limiter:**
  - If both presents enqueued successfully, set `g_v2b1aCompleted.store(true, std::memory_order_relaxed)`.
- **Emit One-Shot `[LSFG-V2B1]` Diagnostic Line:**
  ```cpp
  LOGI("[LSFG-V2B1] gateEnabled=true singleShotSuccess=true N=%u(0x%" PRIx64 ") M=%u(0x%" PRIx64 ") swapchain=0x%" PRIx64 " queue=0x%" PRIx64 " copySubmitRes=0 genPresentRes=%d origPresentRes=%d limiterConsumed=true",
       N, handle_to_u64(transport.swapchainImages[N]),
       M, handle_to_u64(transport.swapchainImages[M]),
       handle_to_u64(swapchain), handle_to_u64(queue),
       static_cast<int>(localResultM), static_cast<int>(resN));
  ```
- Return `resN` to caller.

**Step 6.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Check presentation
  ```
- [ ] **Expected Result:** $M \rightarrow N$ ordering, limiter consumption, and diagnostic block checks PASS.

**Step 6.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): implement two-phase presentation and V2B.1A single-shot limiter`.

---

### Task 7: Implement Concrete Post-Commit Recovery Paths

**Repository:** `C:\Proyectos\amethyst`  
**Branch:** `feature/lsfg-vulkan-interposer`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- If `vkQueueSubmit` fails with `VK_ERROR_OUT_OF_HOST_MEMORY` or `VK_ERROR_OUT_OF_DEVICE_MEMORY`:
  - Increment `g_v2b1PostCommitFailure`.
  - Execute pre-created `recoveryCommandBuffer[slotIndex]` (transitions $M$ to `PRESENT_SRC_KHR`), waiting on `slot.extraAcquireSemaphore`, signaling `recoveryPresentReady[M]`.
  - Call `realQueuePresentKHR(M)` with `recoveryPresentReady[M]` to release image $M$ back to WSI.
  - Call `realQueuePresentKHR(N)` with the original unconsumed $S_{\text{app\_render}}$ semaphores.
  - Disable V2B.1 active transport for the remainder of this swapchain generation (`g_v2b1aCompleted = true`).
  - Return the result of present $N$.
- If `realQueuePresentKHR(M)` returns `VK_ERROR_OUT_OF_DATE_KHR` or `VK_ERROR_SURFACE_LOST_KHR`:
  - Still execute `realQueuePresentKHR(N)` with `realPresentReady[N]`.
  - Return `VK_ERROR_OUT_OF_DATE_KHR` to trigger caller swapchain recreation.

**Step 7.1 — Verification:**
- [ ] **Run Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Check recovery
  ```
- [ ] **Expected Result:** Recovery state machine checks PASS.

**Step 7.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): implement concrete post-commit recovery and error handling`.

---

### Task 8: Update Summary Telemetry and Run Full Contract & Regression Suites

**Repository:** `C:\Proyectos\amethyst` & `C:\Proyectos\SGSR`  
**Files:**
- [MODIFY] `C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp`

**Interfaces & Changes:**
- In `lsfg_interposer_log_summary()`:
  - Append V2B.1 telemetry counters to both `LOGI` and `printf` output blocks:
    ```text
    v2b1Gate=%u v2b1Eligible=%u v2b1ExtraAcquireAttempt=%u v2b1ExtraAcquireSuccess=%u v2b1CopySubmit=%u v2b1GeneratedPresent=%u v2b1OriginalPresent=%u v2b1PostCommitFailure=%u v2b1Fallback=%u
    ```
- Run full test suites:
  1. `powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b1a_contract_test.ps1 -Stage full`
  2. `powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2b0_contract_test.ps1 -Stage full`
  3. `powershell -ExecutionPolicy Bypass -File C:\Proyectos\SGSR\native\lsfg-android\v2a1_contract_test.ps1 -Stage full`

**Step 8.1 — Verification:**
- [ ] **Expected Result:** All 3 test suites pass with 0 failures (100% GREEN).

**Step 8.2 — Commit Boundary:**
- [ ] Commit in Amethyst: `feat(interposer): publish V2B.1 active transport telemetry counters in summary`.

---

### Task 9: Clean Detached Worktree Build and Artifact Provenance Gate

**Files:**
- Output APK: `C:\Users\CJF\AppData\Local\Temp\lsfg_v2b1a_repro\clean-v2b1a.apk`
- Baseline APK: `C:\Users\CJF\AppData\Local\Temp\lsfg_v2b0_repro\clean-v2b0.apk` (`09386199B5EBA46D0EDF7DABAFBF8991CF5A108D9999F9E4B630F4CBE5DD72EE`)

**Procedure:**
1. Create detached clean worktree:
   ```powershell
   git -C C:\Proyectos\amethyst worktree add --detach C:\Proyectos\amethyst-build-v2b1a HEAD
   git -C C:\Proyectos\amethyst-build-v2b1a submodule update --init --recursive
   Copy-Item C:\Proyectos\amethyst\local.properties C:\Proyectos\amethyst-build-v2b1a\local.properties
   ```
2. Build clean Debug APK:
   ```powershell
   cd C:\Proyectos\amethyst-build-v2b1a
   .\gradlew.bat :app_pojavlauncher:assembleDebug --offline
   ```
3. Stage clean APK and compute SHA-256 hash.
4. Remove temporary build worktree:
   ```powershell
   git -C C:\Proyectos\amethyst worktree remove C:\Proyectos\amethyst-build-v2b1a --force
   ```
5. Run provenance comparison:
   - Prove 0 added or removed entries.
   - Prove only `liblsfg-vulkan-interposer.so` contains functional deltas.
   - Verify `classes.dex`, `MioLibPatcher`, and LWJGL are byte-for-byte identical.

---

## Physical Validation Plan (For Human Execution — Document Only)

Following implementation and clean artifact verification, the user will manually perform the physical test on the **AYN Odin 2 Portal**:
1. Install clean `clean-v2b1a.apk` via `adb install -r`.
2. Configure `custom_env.txt` to:
   ```text
   AMETHYST_LSFG_VULKAN_INTERPOSER=1
   AMETHYST_LSFG_V2B0_FIFO=1
   AMETHYST_LSFG_V2B1_ACTIVE=1
   ```
3. Launch Amethyst Debug, select `Sampiland 2 test`, and play in `Mundo nuevo` for 30–60 seconds with SGSR1 @ 50% scale.
4. Exit world and close Minecraft normally.
5. Post-test log analysis will verify:
   - `[LSFG-V2B1] gateEnabled=true singleShotSuccess=true N!=M`
   - `v2b1ExtraAcquireSuccess=1`, `v2b1CopySubmit=1`, `v2b1GeneratedPresent=1`, `v2b1OriginalPresent=1`
   - `v2b1PostCommitFailure=0`, `v2b1Fallback=0`
   - Total application `QueuePresentKHR = N`, with $N-1$ frames passing through passively under FIFO.
   - Zero Vulkan errors, zero native crashes, clean shutdown (`Exit code: 0`).
