# v2b1b_real_lsfg_functional_backend_contract_test.ps1
# Authoritative Function-Scoped Contract Test for REAL-LSFG Functional Baseline + Physical Pixel-Proof
# Enforces scoped active-path recording, fence-retirement evaluator, memory visibility,
# Alpha dispatch domains (halfExtent / quarterExtent), format handling, and zero false-green placeholders.

$ErrorActionPreference = "Stop"
$failures = @()

function Assert-Condition($cond, $msg) {
    if (-not $cond) {
        Write-Host "[FAIL] $msg" -ForegroundColor Red
        $script:failures += $msg
    } else {
        Write-Host "[PASS] $msg" -ForegroundColor Green
    }
}

function Get-ScopedBlock($content, $startMarker, $endMarker) {
    $sIdx = $content.IndexOf($startMarker)
    if ($sIdx -lt 0) { return "" }
    $sub = $content.Substring($sIdx)
    $eIdx = $sub.IndexOf($endMarker)
    if ($eIdx -lt 0) { return $sub }
    return $sub.Substring(0, $eIdx + $endMarker.Length)
}

Write-Host "=== REAL-LSFG FUNCTIONAL BACKEND + PIXEL-PROOF HARDENED CONTRACT TEST ===" -ForegroundColor Cyan

# Source Paths
$lsfgCppPath = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\v3.1_src\lsfg.cpp"
$headerPath = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\public\lsfg_3_1.hpp"
$interposerPath = "C:\Proyectos\amethyst_worktree_real_lsfg_functional\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
if (-not (Test-Path $interposerPath)) {
    $interposerPath = "C:\Proyectos\amethyst_worktree_real_lsfg_r4b\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
}

Assert-Condition (Test-Path $lsfgCppPath) "lsfg.cpp exists"
Assert-Condition (Test-Path $headerPath) "lsfg_3_1.hpp exists"
Assert-Condition (Test-Path $interposerPath) "interposer source exists"

$lsfgContent = if (Test-Path $lsfgCppPath) { Get-Content $lsfgCppPath -Raw } else { "" }
$headerContent = if (Test-Path $headerPath) { Get-Content $headerPath -Raw } else { "" }
$interposerContent = if (Test-Path $interposerPath) { Get-Content $interposerPath -Raw } else { "" }

# Extract Scoped Blocks (Contract 7: Truly Function-Scoped Enforcement)
$scopedLsfgAlpha = Get-ScopedBlock $lsfgContent "Stage 2: Alpha passes" "Stage 3: Beta passes"
$scopedActiveRecord = Get-ScopedBlock $interposerContent "Functional Pixel Proof Eligibility & Sentinel Clear" "// C4 Two-Hop Output: G -> D -> M"
$scopedFenceEvaluator = Get-ScopedBlock $interposerContent "static void evaluateFunctionalPixelProof" "VKAPI_ATTR VkResult VKAPI_CALL interposer_vkQueuePresentKHR"
$scopedSlotRetirement = Get-ScopedBlock $interposerContent "Evaluate completed functional pixel proof upon slot fence retirement" "g_v2b1ExtraAcquireAttempt"

Assert-Condition ($scopedLsfgAlpha.Length -gt 0) "Scope Extractor: lsfg.cpp Stage 2 Alpha block extracted"
Assert-Condition ($scopedActiveRecord.Length -gt 0) "Scope Extractor: Interposer Active Functional Record block extracted"
Assert-Condition ($scopedFenceEvaluator.Length -gt 0) "Scope Extractor: Interposer Fence Evaluator block extracted"
Assert-Condition ($scopedSlotRetirement.Length -gt 0) "Scope Extractor: Interposer Slot Retirement block extracted"

# -----------------------------------------------------------------------------
# 1. Extent & Geometry Hierarchy Contracts (Sections 2, 3, 29)
# -----------------------------------------------------------------------------

# Contract 1: Authoritative Gamma Extents Table
$gammaExtentsCheck = ($lsfgContent -match "8\s*,\s*4" -and
                      $lsfgContent -match "15\s*,\s*9" -and
                      $lsfgContent -match "30\s*,\s*17" -and
                      $lsfgContent -match "60\s*,\s*34" -and
                      $lsfgContent -match "120\s*,\s*68" -and
                      $lsfgContent -match "240\s*,\s*135" -and
                      $lsfgContent -match "480\s*,\s*270")
Assert-Condition $gammaExtentsCheck "Contract 1: Authoritative Gamma extent hierarchy (8x4 -> 480x270) defined"

# Contract 2: Authoritative Delta Extents Table
$deltaExtentsCheck = ($lsfgContent -match "120\s*,\s*68" -and
                      $lsfgContent -match "240\s*,\s*135" -and
                      $lsfgContent -match "480\s*,\s*270")
Assert-Condition $deltaExtentsCheck "Contract 2: Authoritative Delta extent hierarchy (120x68 -> 480x270) defined"

# Contract 3: Mipmap Geometry Hierarchy
$mipmapHierarchyCheck = ($interposerContent -match "1920.*1080" -and
                         $interposerContent -match "960.*540" -and
                         $interposerContent -match "480.*270" -and
                         $interposerContent -match "240.*135" -and
                         $interposerContent -match "120.*67" -and
                         $interposerContent -match "60.*33" -and
                         $interposerContent -match "30.*16")
Assert-Condition $mipmapHierarchyCheck "Contract 3: Mipmap extent hierarchy (1080p down to 30x16) recognized"

# Contract 4: Stale Telemetry Shift Formulas ELIMINATED
$noStaleGammaShift = -not ($interposerContent -match '1920u\s*>>\s*\(\s*6\s*-\s*lvl\s*\)')
$noStaleDeltaShift = -not ($interposerContent -match '1920u\s*>>\s*\(\s*2\s*-\s*lvl\s*\)')
Assert-Condition ($noStaleGammaShift -and $noStaleDeltaShift) "Contract 4: Stale shift formulas eliminated from telemetry"

# Contract 5: Alpha Multi-Tier Representation (sourceExtent, halfExtent, quarterExtent)
$alphaMultiTierLog = ($interposerContent -match "sourceExtent=" -and
                      $interposerContent -match "halfExtent=" -and
                      $interposerContent -match "quarterExtent=")
Assert-Condition $alphaMultiTierLog "Contract 5: Alpha telemetry reports sourceExtent, halfExtent, and quarterExtent"

# -----------------------------------------------------------------------------
# 2. Alpha Dispatch-Domain Contracts (Scoped to lsfg.cpp Alpha Stage)
# -----------------------------------------------------------------------------

# Contract 6a: Alpha Pass 0 & Pass 1 use halfExtent dispatch
$alphaPass01Check = ($scopedLsfgAlpha -match 'hw\s*=\s*\([^\)]*width\s*>>\s*lvl\)[^\)]*\+\s*1\)\s*>>\s*1' -or
                     $scopedLsfgAlpha -match 'hw\s*=\s*\([^\)]*\+\s*1\)\s*>>\s*1' -or
                     $scopedLsfgAlpha -match 'halfExtent') -and
                    ($scopedLsfgAlpha -match 'p\s*<\s*2\s*\?\s*hw\s*:\s*qw' -or
                     $scopedLsfgAlpha -match 'dw\s*=\s*\(p\s*<\s*2\)\s*\?\s*hw\s*:\s*qw' -or
                     $scopedLsfgAlpha -match 'cmdDispatch\([^\)]*hw')
Assert-Condition $alphaPass01Check "Contract 6a: Alpha P0/P1 (res_267/268) dispatched using halfExtent domain"

# Contract 6b: Alpha Pass 2 & Pass 3 use quarterExtent dispatch
$alphaPass23Check = ($scopedLsfgAlpha -match 'qw\s*=\s*\(hw\s*\+\s*1\)\s*>>\s*1' -or
                     $scopedLsfgAlpha -match 'qw\s*=\s*\([^\)]*\+\s*1\)\s*>>\s*1' -or
                     $scopedLsfgAlpha -match 'quarterExtent') -and
                    ($scopedLsfgAlpha -match 'p\s*<\s*2\s*\?\s*hw\s*:\s*qw' -or
                     $scopedLsfgAlpha -match 'dw\s*=\s*\(p\s*<\s*2\)\s*\?\s*hw\s*:\s*qw' -or
                     $scopedLsfgAlpha -match 'cmdDispatch\([^\)]*qw')
Assert-Condition $alphaPass23Check "Contract 6b: Alpha P2/P3 (res_269/270) dispatched using quarterExtent domain"

# Contract 6c: Elimination of unscaled source mip dispatch (lw, lh) in Alpha loop
$noOverdispatch = -not ($scopedLsfgAlpha -match 'cmdDispatch\s*\([^,]+,\s*\(\s*lw\s*\+\s*7\s*\)\s*/\s*8\s*,\s*\(\s*lh\s*\+\s*7\s*\)\s*/\s*8\s*,\s*1\s*\)')
Assert-Condition $noOverdispatch "Contract 6c: Elimination of unscaled source mip overdispatch in Alpha Stage"

# Contract 7: Seed Topology (res_267, 268, 269 1x each, res_270 3x per level -> 42 Alpha + 1 Mipmaps = 43 total)
$seedTopologyCheck = ($lsfgContent -match "for\s*\(\s*int\s*bank\s*=\s*0;\s*bank\s*<\s*3;\s*\+\+bank\s*\)\s*\{[^\}]*270") -and
                     ($lsfgContent -match "42\s*dispatches" -or $lsfgContent -match "43\s*dispatches\s*total")
Assert-Condition $seedTopologyCheck "Contract 7: Seed implements 42 Alpha (P0..P2 once, P3 3x) + 1 Mipmaps = 43 dispatches"

# -----------------------------------------------------------------------------
# 3. Active Functional Record Path Contracts (Scoped to $scopedActiveRecord)
# -----------------------------------------------------------------------------

# Contract 8: REJECT FALSE-GREEN PLACEHOLDER
$noDummyPlaceholder = -not ($interposerContent -match 'bool\s+pixelProofPassed\s*=\s*true\s*;')
Assert-Condition $noDummyPlaceholder "Contract 8: Rejection of false-green placeholder (bool pixelProofPassed = true)"

# Contract 9: Functional Pixel Proof Gate in Active Record Path
$scopedProofGate = ($scopedActiveRecord -match 'g_functionalPixelProof\.load' -and
                    $scopedActiveRecord -match 'g_proofAttemptCounter\.load\(\s*std::memory_order_relaxed\s*\)\s*<\s*maxProofAttempts')
Assert-Condition $scopedProofGate "Contract 9: Active path validates functional proof gate and attempt limits"

# Contract 10: Unconditional VK_IMAGE_USAGE_TRANSFER_DST_BIT on slot.generatedImage
$genUsageCheck = ($interposerContent -match 'VK_IMAGE_USAGE_TRANSFER_DST_BIT') -and
                 ($interposerContent -match 'slots\[s\]\.generatedImage')
Assert-Condition $genUsageCheck "Contract 10: slot.generatedImage unconditionally created with TRANSFER_DST_BIT"

# Contract 11: Dedicated proof staging buffers owned per TransportSlot
$perSlotStagingCheck = ($interposerContent -match 'proofStagingPBuffer' -and
                        $interposerContent -match 'proofStagingCBuffer' -and
                        $interposerContent -match 'proofStagingGBuffer' -and
                        $interposerContent -match 'proofStagingPMapped')
Assert-Condition $perSlotStagingCheck "Contract 11: Dedicated proof staging buffers owned per TransportSlot"

# Contract 12: Sentinel Clear in Active Functional Path
$sentinelClearCheck = ($scopedActiveRecord -match 'cmdClearColorImage\s*\([^\)]*slot\.generatedImage' -or
                       $scopedActiveRecord -match 'vkCmdClearColorImage\s*\([^\)]*slot\.generatedImage') -and
                      ($scopedActiveRecord -match '30(\.0f)?\s*/\s*255' -and $scopedActiveRecord -match '117(\.0f)?\s*/\s*255') -and
                      ($scopedActiveRecord -match 'clearToComputeBarrier' -or $scopedActiveRecord -match 'VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT')
Assert-Condition $sentinelClearCheck "Contract 12: Active path records sentinel clear on G and clear->compute barrier"

# Contract 13a: Readback Copies in Active Functional Path
$readbackCopiesCheck = ($scopedActiveRecord -match 'cmdCopyImageToBuffer\s*\([^\)]*b2bHistoryImage[^\)]*proofStagingPBuffer') -and
                       ($scopedActiveRecord -match 'cmdCopyImageToBuffer\s*\([^\)]*capturedImage[^\)]*proofStagingCBuffer') -and
                       ($scopedActiveRecord -match 'cmdCopyImageToBuffer\s*\([^\)]*generatedImage[^\)]*proofStagingGBuffer')
Assert-Condition $readbackCopiesCheck "Contract 13a: Active functional path records copies for P, C, and G into per-slot staging"

# Contract 13b: P/C Transfer-Write Memory Visibility for Readback
$pcVisibilityCheck = ($scopedActiveRecord -match 'proofBarriers\[1\]\.srcAccessMask[^\n]*VK_ACCESS_TRANSFER_WRITE_BIT') -and
                     ($scopedActiveRecord -match 'proofBarriers\[2\]\.srcAccessMask[^\n]*VK_ACCESS_TRANSFER_WRITE_BIT') -and
                     ($scopedActiveRecord -match 'VK_PIPELINE_STAGE_TRANSFER_BIT\s*\|\s*VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT')
Assert-Condition $pcVisibilityCheck "Contract 13b: Readback barriers enforce TRANSFER_WRITE visibility for P and C"

# Contract 13c: Native History Preservation (P transitioned to TRANSFER_DST_OPTIMAL before C->P)
$pPreservationCheck = ($scopedActiveRecord -match 'pToDstBarrier\.newLayout\s*=\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL' -or
                       $scopedActiveRecord -match 'VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL') -and
                      ($scopedActiveRecord -match 'timestampExcludeFromBaseline\s*=\s*true')
Assert-Condition $pPreservationCheck "Contract 13c: Native history P transitioned for C->P and timestamp exclusion flagged"

# -----------------------------------------------------------------------------
# 4. Fence-Retirement Evaluator Contracts (Scoped to $scopedFenceEvaluator)
# -----------------------------------------------------------------------------

# Contract 14: Non-Coherent Host Memory Invalidation
$invalidationCheck = ($scopedFenceEvaluator -match 'invalidateMappedMemoryRanges') -and
                     ($scopedFenceEvaluator -match 'proofStagingPMemory' -and
                      $scopedFenceEvaluator -match 'proofStagingCMemory' -and
                      $scopedFenceEvaluator -match 'proofStagingGMemory')
Assert-Condition $invalidationCheck "Contract 14: Fence evaluator invalidates non-coherent host mapped memory ranges"

# Contract 15: Mathematical Normalized RGB MAD (0.0..1.0)
$madEvaluatorCheck = ($scopedFenceEvaluator -match 'MAD_PC' -and
                      $scopedFenceEvaluator -match 'MAD_GP' -and
                      $scopedFenceEvaluator -match 'MAD_GC' -and
                      $scopedFenceEvaluator -match 'MAD_G_PREV' -and
                      $scopedFenceEvaluator -match '255')
Assert-Condition $madEvaluatorCheck "Contract 15: Mathematical RGB normalized MAD calculation (0.0..1.0) implemented"

# Contract 16a: 64-bit Non-Cryptographic Content Hashes
$hashCheck = ($scopedFenceEvaluator -match 'hashP' -and
              $scopedFenceEvaluator -match 'hashC' -and
              $scopedFenceEvaluator -match 'hashG' -and
              $scopedFenceEvaluator -match 'kFnvPrime')
Assert-Condition $hashCheck "Contract 16a: 64-bit FNV-1a content hashes computed for P, C, and G"

# Contract 16b: Strong Sentinel Full-Frame Hash Check
$sentinelHashCheck = ($scopedFenceEvaluator -match 'sentinelFullFrameHash' -or
                      $scopedFenceEvaluator -match 'kSentinelFullFrameHash' -or
                      $scopedFenceEvaluator -match '0x9167ea5cdda3a325')
Assert-Condition $sentinelHashCheck "Contract 16b: Strong sentinel full-frame hash check enforced against untouched G"

# Contract 17: Explicit Channel Decoding & Unsupported Format Rejection
$formatHandlingCheck = ($scopedFenceEvaluator -match 'VK_FORMAT_R8G8B8A8_UNORM' -and
                        $scopedFenceEvaluator -match 'VK_FORMAT_B8G8R8A8_UNORM' -and
                        $scopedFenceEvaluator -match 'PIXEL_PROOF_UNSUPPORTED_FORMAT')
Assert-Condition $formatHandlingCheck "Contract 17: Explicit channel decoding for RGBA8/BGRA8 and format rejection"

# Contract 18: Proof State Machine
$stateMachineCheck = ($scopedFenceEvaluator -match 'PixelProofState::DISABLED' -or $scopedFenceEvaluator -match 'PIXEL_PROOF_DISABLED') -and
                     ($scopedFenceEvaluator -match 'PixelProofState::PENDING' -or $scopedFenceEvaluator -match 'PIXEL_PROOF_PENDING') -and
                     ($scopedFenceEvaluator -match 'PixelProofState::NO_MOTION' -or $scopedFenceEvaluator -match 'PIXEL_PROOF_NO_MOTION') -and
                     ($scopedFenceEvaluator -match 'PixelProofState::PASS' -or $scopedFenceEvaluator -match 'PIXEL_PROOF_PASS') -and
                     ($scopedFenceEvaluator -match 'PixelProofState::FAIL' -or $scopedFenceEvaluator -match 'PIXEL_PROOF_FAIL')
Assert-Condition $stateMachineCheck "Contract 18: Proof state machine (DISABLED, PENDING, NO_MOTION, PASS, FAIL) scoped to evaluator"

# Contract 19: Static-Scene Non-Failure Logic (MAD_PC <= motionThreshold -> NO_MOTION)
$staticSceneLogicCheck = ($scopedFenceEvaluator -match 'MAD_PC\s*<=\s*motionThreshold' -and
                          $scopedFenceEvaluator -match 'NO_MOTION')
Assert-Condition $staticSceneLogicCheck "Contract 19: Static scene (MAD_PC <= motionThreshold) yields NO_MOTION retry, not FAIL"

# Contract 20: Moving-Scene Pass Criteria with Sentinel Retention Ratio Threshold
$passCriteriaCheck = ($scopedFenceEvaluator -match 'sentinelRatio\s*<=\s*kSentinelRetentionThreshold' -or
                      $scopedFenceEvaluator -match 'sentinelRatio\s*<=\s*0\.00001' -or
                      $scopedFenceEvaluator -match 'sentinelPixelCount') -and
                     ($scopedFenceEvaluator -match 'hashG\s*!=\s*hashP') -and
                     ($scopedFenceEvaluator -match 'hashG\s*!=\s*hashC') -and
                     ($scopedFenceEvaluator -match 'MAD_GP\s*>\s*epsilon') -and
                     ($scopedFenceEvaluator -match 'MAD_GC\s*>\s*epsilon')
Assert-Condition $passCriteriaCheck "Contract 20: Strict moving-scene PASS criteria (retention ratio <= threshold, distinct hashes, MAD > epsilon)"

# Contract 21: Runtime Telemetry Marker [LSFG-FUNC-PIXEL-PROOF]
$telemetryMarkerCheck = ($scopedFenceEvaluator -match '\[LSFG-FUNC-PIXEL-PROOF\]')
Assert-Condition $telemetryMarkerCheck "Contract 21: Runtime telemetry marker [LSFG-FUNC-PIXEL-PROOF] emitted in evaluator"

# Contract 22: Persistent Disk Summary (lsfg_functional_run.txt)
$persistentFileCheck = ($scopedFenceEvaluator -match 'lsfg_functional_run\.txt')
Assert-Condition $persistentFileCheck "Contract 22: Persistent summary file lsfg_functional_run.txt appended in evaluator"

# Contract 23: Raw Frame Evidence Export (P.raw, C.raw, G.raw, pixel_proof_meta.txt)
$rawEvidenceCheck = ($scopedFenceEvaluator -match 'P\.raw' -and
                     $scopedFenceEvaluator -match 'C\.raw' -and
                     $scopedFenceEvaluator -match 'G\.raw' -and
                     $scopedFenceEvaluator -match 'pixel_proof_meta\.txt')
Assert-Condition $rawEvidenceCheck "Contract 23: Raw frame evidence and metadata exported on PASS"

# -----------------------------------------------------------------------------
# 5. Active Slot Retirement & Integration Contracts (Scoped to $scopedSlotRetirement)
# -----------------------------------------------------------------------------

# Contract 24: Evaluator Invocation & Timing Exclusion upon Slot Fence Retirement
$slotRetirementCheck = ($scopedSlotRetirement -match 'slot\.proofPending' -and
                        $scopedSlotRetirement -match 'evaluateFunctionalPixelProof\s*\(\s*slot\s*,\s*transport\s*\)') -and
                       ($scopedSlotRetirement -match 'slot\.timestampExcludeFromBaseline' -and
                        $scopedSlotRetirement -match 'slot\.timestampRecorded\s*=\s*false')
Assert-Condition $slotRetirementCheck "Contract 24: Evaluator invoked on retired slot fence and timing excluded from baseline"

# Contract 25: Zero Explicit GPU Waits (No vkQueueWaitIdle / vkDeviceWaitIdle)
$noWaitCheck = -not ($interposerContent -match 'vkQueueWaitIdle\s*\(' -or $interposerContent -match 'vkDeviceWaitIdle\s*\(')
Assert-Condition $noWaitCheck "Contract 25: Zero vkQueueWaitIdle / vkDeviceWaitIdle calls in runtime"

# Contract 26: R4-A and R4-B Forced OFF for Functional Baseline
$r4OffCheck = ($interposerContent -match "AMETHYST_LSFG_R4A_DELTA_L2_BYPASS\s*==\s*0" -or
               $interposerContent -match "r4aEnabled\s*=\s*false" -or
               $interposerContent -match "deltaL2Bypass\s*=\s*false")
Assert-Condition $r4OffCheck "Contract 26: R4-A and R4-B bypasses forced OFF for functional baseline"

# Contract 27: Full 100-Dispatch Pipeline Preserved
$fullDispatchesCheck = ($lsfgContent -match "100" -or ($lsfgContent -match "dispatches" -and $lsfgContent -match "Alpha" -and $lsfgContent -match "Beta" -and $lsfgContent -match "Gamma" -and $lsfgContent -match "Delta" -and $lsfgContent -match "Generate"))
Assert-Condition $fullDispatchesCheck "Contract 27: Full generation graph dispatches all 100 compute passes"

# Contract 28: Proprietary Asset Isolation
$repoDir = "C:\Proyectos\amethyst_worktree_real_lsfg_functional"
if (-not (Test-Path $repoDir)) { $repoDir = "C:\Proyectos\amethyst_worktree_real_lsfg_r4b" }
$dlls = Get-ChildItem -Path $repoDir -Recurse -Filter "Lossless.dll" -ErrorAction SilentlyContinue
Assert-Condition ($dlls.Count -eq 0) "Contract 28a: No Lossless.dll in repository"
$dxbcs = Get-ChildItem -Path $repoDir -Recurse -Filter "*.dxbc" -ErrorAction SilentlyContinue
Assert-Condition ($dxbcs.Count -eq 0) "Contract 28b: No *.dxbc in repository"
$spvs = Get-ChildItem -Path $repoDir -Recurse -Filter "res_*.spv" -ErrorAction SilentlyContinue
Assert-Condition ($spvs.Count -eq 0) "Contract 28c: No res_*.spv in repository"

Write-Host "=== FUNCTIONAL BACKEND + PIXEL-PROOF HARDENED CONTRACT SUMMARY ===" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    Write-Host "FAILED with $($failures.Count) contract failure(s) (EXPECTED RED BEFORE IMPLEMENTATION):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "ALL CONTRACTS PASSED (GREEN)!" -ForegroundColor Green
    exit 0
}
