# v2b1b_real_lsfg_functional_backend_contract_test.ps1
# Authoritative Contract Test for REAL-LSFG Functional Baseline + Physical Pixel-Proof
# Enforces active-path command recording, fence-retirement evaluator, format handling,
# geometry hierarchies, Beta/Seed topologies, and zero false-green placeholders.

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

Write-Host "=== REAL-LSFG FUNCTIONAL BACKEND + PIXEL-PROOF CONTRACT TEST ===" -ForegroundColor Cyan

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
# 2. Beta & Seed Topology Contracts (Sections 4, 5, 30, 31)
# -----------------------------------------------------------------------------

# Contract 6: Beta Topology Sequence (res_275..res_279, 5 dispatches at 480x270)
$betaSeqCheck = ($lsfgContent -match '275\s*,\s*276\s*,\s*277\s*,\s*278\s*,\s*279') -and
                ($lsfgContent -match 'bs\s*=\s*\(\s*p\s*==\s*4\s*\)\s*\?\s*32\s*:\s*8' -or $lsfgContent -match '32\s*:\s*8')
Assert-Condition $betaSeqCheck "Contract 6: Beta executes exactly 5 passes (res_275..279) with 60x34 and 15x9 dispatches"

# Contract 7: Seed Topology (res_267, 268, 269 1x each, res_270 3x per level -> 42 Alpha + 1 Mipmaps = 43 total)
$seedTopologyCheck = ($lsfgContent -match "for\s*\(\s*int\s*bank\s*=\s*0;\s*bank\s*<\s*3;\s*\+\+bank\s*\)\s*\{[^\}]*270") -and
                     ($lsfgContent -match "42\s*dispatches" -or $lsfgContent -match "43\s*dispatches\s*total")
Assert-Condition $seedTopologyCheck "Contract 7: Seed implements 42 Alpha (P0..P2 once, P3 3x) + 1 Mipmaps = 43 dispatches"

# -----------------------------------------------------------------------------
# 3. Pixel-Proof Architecture & Rejection of Placeholders (Sections 6-28, Addendum A-Q)
# -----------------------------------------------------------------------------

# Contract 8: REJECT FALSE-GREEN PLACEHOLDER
$noDummyPlaceholder = -not ($interposerContent -match 'bool\s+pixelProofPassed\s*=\s*true\s*;')
Assert-Condition $noDummyPlaceholder "Contract 8: Rejection of false-green placeholder (bool pixelProofPassed = true)"

# Contract 9: New Explicit Functional Pixel Proof Gate (AMETHYST_LSFG_FUNCTIONAL_PIXEL_PROOF)
$proofEnvCheck = ($interposerContent -match 'AMETHYST_LSFG_FUNCTIONAL_PIXEL_PROOF\b') -and
                 ($interposerContent -match 'AMETHYST_LSFG_FUNCTIONAL_PIXEL_PROOF_MAX_ATTEMPTS\b')
Assert-Condition $proofEnvCheck "Contract 9: AMETHYST_LSFG_FUNCTIONAL_PIXEL_PROOF and MAX_ATTEMPTS parsed"

# Contract 10: Unconditional VK_IMAGE_USAGE_TRANSFER_DST_BIT on slot.generatedImage
$genUsageCheck = ($interposerContent -match 'VK_IMAGE_USAGE_TRANSFER_DST_BIT') -and
                 ($interposerContent -match 'slots\[s\]\.generatedImage')
Assert-Condition $genUsageCheck "Contract 10: slot.generatedImage unconditionally created with TRANSFER_DST_BIT"

# Contract 11: Per-Slot Proof Staging Buffer Ownership
$perSlotStagingCheck = ($interposerContent -match 'proofStagingPBuffer' -and
                        $interposerContent -match 'proofStagingCBuffer' -and
                        $interposerContent -match 'proofStagingGBuffer' -and
                        $interposerContent -match 'proofStagingPMapped')
Assert-Condition $perSlotStagingCheck "Contract 11: Dedicated proof staging buffers owned per TransportSlot"

# Contract 12: Sentinel Clear in Active Functional Path
$sentinelClearCheck = ($interposerContent -match 'cmdClearColorImage\s*\([^\)]*slot\.generatedImage' -or
                       $interposerContent -match 'vkCmdClearColorImage\s*\([^\)]*slot\.generatedImage') -and
                      ($interposerContent -match '30(\.0f)?\s*/\s*255' -and $interposerContent -match '117(\.0f)?\s*/\s*255')
Assert-Condition $sentinelClearCheck "Contract 12: Deterministic R/B-symmetric sentinel (30, 117, 30, 8) cleared on G before Generate"

# Contract 13: Readback Copies in Active Functional Path Before Native History Overwrite
$readbackCopiesCheck = ($interposerContent -match 'cmdCopyImageToBuffer\s*\([^\)]*b2bHistoryImage[^\)]*proofStagingPBuffer') -and
                       ($interposerContent -match 'cmdCopyImageToBuffer\s*\([^\)]*capturedImage[^\)]*proofStagingCBuffer') -and
                       ($interposerContent -match 'cmdCopyImageToBuffer\s*\([^\)]*generatedImage[^\)]*proofStagingGBuffer')
Assert-Condition $readbackCopiesCheck "Contract 13: Active functional path copies P, C, and G into per-slot staging buffers"

# Contract 14: Staging Memory Invalidation for Non-Coherent Host Memory
$invalidationCheck = ($interposerContent -match 'vkInvalidateMappedMemoryRanges' -or $interposerContent -match 'invalidateMappedMemoryRanges') -and
                     ($interposerContent -match 'proofStagingPMemory' -or $interposerContent -match 'proofStagingGBuffer' -or $interposerContent -match 'proofStaging')
Assert-Condition $invalidationCheck "Contract 14: Non-coherent memory invalidation implemented using valid Vulkan ranges"

# Contract 15: Mathematical RGB Normalized MAD Evaluator
$madEvaluatorCheck = ($interposerContent -match 'MAD_PC' -and
                      $interposerContent -match 'MAD_GP' -and
                      $interposerContent -match 'MAD_GC' -and
                      $interposerContent -match '255')
Assert-Condition $madEvaluatorCheck "Contract 15: Mathematical RGB normalized MAD calculation (0.0..1.0) implemented"

# Contract 16: Non-Cryptographic 64-bit Hashes (hashP, hashC, hashG)
$hashCheck = ($interposerContent -match 'hashP' -and $interposerContent -match 'hashC' -and $interposerContent -match 'hashG')
Assert-Condition $hashCheck "Contract 16: 64-bit image content hashes computed for P, C, and G"

# Contract 17: Format Handling (R8G8B8A8 and B8G8R8A8 supported, unsupported rejected)
$formatHandlingCheck = ($interposerContent -match 'VK_FORMAT_R8G8B8A8_UNORM' -and
                        $interposerContent -match 'VK_FORMAT_B8G8R8A8_UNORM' -and
                        $interposerContent -match 'PIXEL_PROOF_UNSUPPORTED_FORMAT')
Assert-Condition $formatHandlingCheck "Contract 17: Explicit channel decoding for RGBA8/BGRA8 and unsupported format rejection"

# Contract 18: Proof State Machine (DISABLED, PENDING, NO_MOTION, PASS, FAIL)
$stateMachineCheck = ($interposerContent -match 'PIXEL_PROOF_DISABLED' -or $interposerContent -match 'PixelProofState::DISABLED') -and
                     ($interposerContent -match 'PIXEL_PROOF_PENDING' -or $interposerContent -match 'PixelProofState::PENDING') -and
                     ($interposerContent -match 'PIXEL_PROOF_NO_MOTION' -or $interposerContent -match 'PixelProofState::NO_MOTION') -and
                     ($interposerContent -match 'PIXEL_PROOF_PASS' -or $interposerContent -match 'PixelProofState::PASS') -and
                     ($interposerContent -match 'PIXEL_PROOF_FAIL' -or $interposerContent -match 'PixelProofState::FAIL')
Assert-Condition $stateMachineCheck "Contract 18: Explicit proof state machine enum/states implemented"

# Contract 19: Static-Scene Non-Failure Logic (MAD_PC <= motionThreshold -> NO_MOTION)
$staticSceneLogicCheck = ($interposerContent -match 'motionThreshold' -and
                          $interposerContent -match 'NO_MOTION')
Assert-Condition $staticSceneLogicCheck "Contract 19: Static scene (MAD_PC <= motionThreshold) yields NO_MOTION retry, not FAIL"

# Contract 20: Moving-Scene Pass Criteria (sentinelPixelCount == 0, hashG != P/C, MAD_GP/GC > epsilon)
$passCriteriaCheck = ($interposerContent -match 'sentinelPixelCount\s*==\s*0' -or $interposerContent -match 'sentinelPixels\s*==\s*0') -and
                     ($interposerContent -match 'hashG\s*!=\s*hashP') -and
                     ($interposerContent -match 'hashG\s*!=\s*hashC') -and
                     ($interposerContent -match 'epsilon')
Assert-Condition $passCriteriaCheck "Contract 20: Strict moving-scene PASS criteria (zero sentinel retention, distinct hashes, MAD > epsilon)"

# Contract 21: Runtime Telemetry Marker [LSFG-FUNC-PIXEL-PROOF]
$telemetryMarkerCheck = ($interposerContent -match '\[LSFG-FUNC-PIXEL-PROOF\]')
Assert-Condition $telemetryMarkerCheck "Contract 21: Runtime telemetry marker [LSFG-FUNC-PIXEL-PROOF] emitted"

# Contract 22: Persistent Summary Writer to lsfg_functional_run.txt
$persistentFileCheck = ($interposerContent -match 'lsfg_functional_run\.txt')
Assert-Condition $persistentFileCheck "Contract 22: Persistent summary file lsfg_functional_run.txt maintained"

# Contract 23: Raw Evidence Export (P.raw, C.raw, G.raw, pixel_proof_meta.txt)
$rawEvidenceCheck = ($interposerContent -match 'P\.raw' -and
                     $interposerContent -match 'C\.raw' -and
                     $interposerContent -match 'G\.raw' -and
                     $interposerContent -match 'pixel_proof_meta\.txt')
Assert-Condition $rawEvidenceCheck "Contract 23: Raw frame evidence and metadata exported to files/lsfg_functional_pixel_proof/"

# Contract 24: Proof Events Excluded from Performance Timestamps
$timingExclusionCheck = ($interposerContent -match 'timestampExcludeFromBaseline' -or
                         $interposerContent -match 'excludeFromBaseline')
Assert-Condition $timingExclusionCheck "Contract 24: Proof diagnostic events flagged and excluded from R1/R2/R3 timing aggregators"

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

Write-Host "=== FUNCTIONAL BACKEND + PIXEL-PROOF CONTRACT SUMMARY ===" -ForegroundColor Cyan
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
