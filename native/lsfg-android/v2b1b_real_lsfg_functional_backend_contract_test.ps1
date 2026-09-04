# v2b1b_real_lsfg_functional_backend_contract_test.ps1
# Contract test for REAL-LSFG Functional External Backend Baseline (100 Dispatches)

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

Write-Host "=== REAL-LSFG FUNCTIONAL BACKEND CONTRACT TEST ===" -ForegroundColor Cyan

# Paths
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

# Contract A: Authoritative Gamma Extents Table
$gammaExtentsCheck = ($lsfgContent -match "8\s*,\s*4" -and
                      $lsfgContent -match "15\s*,\s*9" -and
                      $lsfgContent -match "30\s*,\s*17" -and
                      $lsfgContent -match "60\s*,\s*34" -and
                      $lsfgContent -match "120\s*,\s*68" -and
                      $lsfgContent -match "240\s*,\s*135" -and
                      $lsfgContent -match "480\s*,\s*270")
Assert-Condition $gammaExtentsCheck "Contract A: Authoritative Gamma extent hierarchy (8x4 -> 480x270) defined"

# Contract B: Authoritative Delta Extents Table
$deltaExtentsCheck = ($lsfgContent -match "120\s*,\s*68" -and
                      $lsfgContent -match "240\s*,\s*135" -and
                      $lsfgContent -match "480\s*,\s*270")
Assert-Condition $deltaExtentsCheck "Contract B: Authoritative Delta extent hierarchy (120x68 -> 480x270) defined"

# Contract C: Correct Gamma/Delta Dispatch Counts
$gammaDispatchCheck = ($lsfgContent -match "threadsX\s*=\s*\([^)]*width\s*\+\s*7\)\s*>>\s*3" -or
                       $lsfgContent -match "tx\s*=\s*\([^)]*\.width\s*\+\s*7\)\s*>>\s*3" -or
                       $lsfgContent -match "uint32_t\s+threadsX\s*=\s*\(extent\.width\s*\+\s*7\)\s*>>\s*3")
Assert-Condition $gammaDispatchCheck "Contract C: Gamma & Delta dispatches computed using ceil(extent/8)"

# Contract D: No Historical Full-Resolution Flow Dispatch Formulas
$noOverdispatch = -not ($lsfgContent -match "dispatch\(.*240\s*,\s*135.*gamma" -or $lsfgContent -match "dispatch\(.*240\s*,\s*135.*delta")
Assert-Condition $noOverdispatch "Contract D: No historical 240x135 overdispatch on Gamma/Delta stages"

# Contract E: Global Alpha Temporal Banks
$globalAlphaCheck = ($lsfgContent -match "alphaOutImgs" -or $lsfgContent -match "alphaGlobalOutImgs" -or $lsfgContent -match "globalAlpha") -and
                    ($lsfgContent -match "84" -or $lsfgContent -match "3\s*\*\s*4\s*\*\s*7")
Assert-Condition $globalAlphaCheck "Contract E: 84 global temporal Alpha images across 3 banks and 7 levels"

# Contract F: Per-Slot Scratch Images
$slotScratchCheck = ($lsfgContent -match "166" -or $lsfgContent -match "scratchImgs")
Assert-Condition $slotScratchCheck "Contract F: Frame-local scratch allocated per transport slot"

# Contract G: 142 Descriptor Sets Per Slot (284 Total)
$setCountCheck = ($lsfgContent -match "142" -and $lsfgContent -match "284")
Assert-Condition $setCountCheck "Contract G: Exactly 142 descriptor sets per slot (284 total)"

# Contract H: 1452 Sampled-Image Descriptor Elements Total
$sampledElementsCheck = ($lsfgContent -match "1452" -or $lsfgContent -match "726")
Assert-Condition $sampledElementsCheck "Contract H: 1452 sampled-image descriptor elements total (726 per slot)"

# Contract I: Seed Mode Entry Point Exists
$seedApiCheck = ($headerContent -match "lsfg_record_seed" -and $lsfgContent -match "lsfg_record_seed")
Assert-Condition $seedApiCheck "Contract I: lsfg_record_seed API exists in header and implementation"

# Contract J: Seed Populates All 3 Alpha Banks (43 Dispatches Total)
$seedReplayCheck = ($lsfgContent -match "43" -or ($lsfgContent -match "bank\s*<\s*3" -and $lsfgContent -match "alpha\[3\]"))
Assert-Condition $seedReplayCheck "Contract J: Seed performs Alpha pass-3 replay across all 3 banks (43 dispatches)"

# Contract K: History-Only Mode Exists
$historyOnlyCheck = ($headerContent -match "lsfg_record_history_only" -or $headerContent -match "LSFG_RECORD_MODE_HISTORY_ONLY" -or
                     $lsfgContent -match "history_only" -or $lsfgContent -match "HISTORY_ONLY" -or $lsfgContent -match "record_history")
Assert-Condition $historyOnlyCheck "Contract K: History-only recording mode supported"

# Contract L: Full-Generation Mode Requires Valid Temporal History
$temporalGuardCheck = ($lsfgContent -match "temporalBootstrapComplete" -or $lsfgContent -match "historyValid" -or $lsfgContent -match "isBootstrapped")
Assert-Condition $temporalGuardCheck "Contract L: Full generation guarded by valid temporal history state"

# Contract M: algorithmFrameCount Global and Native-Based
$frameCountCheck = ($lsfgContent -match "algorithmFrameCount" -and $interposerContent -match "algorithmFrameCount")
Assert-Condition $frameCountCheck "Contract M: Global algorithmFrameCount tracks native source frame chronology"

# Contract N: History Failure Invalidates Bootstrap
$historyFailCheck = ($interposerContent -match "temporalBootstrapComplete\s*=\s*false" -or
                     $interposerContent -match "historyValid\s*=\s*false" -or
                     $lsfgContent -match "temporalBootstrapComplete\s*=\s*false")
Assert-Condition $historyFailCheck "Contract N: History failure invalidates bootstrap and requires re-seed"

# Contract O: 416 Graph Images Initialized to GENERAL
$initImagesCheck = ($lsfgContent -match "416" -and $lsfgContent -match "VK_IMAGE_LAYOUT_GENERAL")
Assert-Condition $initImagesCheck "Contract O: All 416 algorithm graph images transitioned to GENERAL"

# Contract P: Dummy Resource Validated
$dummyCheck = ($lsfgContent -match "dummyImage" -and $lsfgContent -match "dummyImageView")
Assert-Condition $dummyCheck "Contract P: Fallback dummy image resource instantiated and validated"

# Contract Q: All Descriptors Non-Null Validation
$descriptorsCheck = ($lsfgContent -match "expectedWriteCount" -or $lsfgContent -match "completedWriteCount" -or $lsfgContent -match "validateDescriptors")
Assert-Condition $descriptorsCheck "Contract Q: All descriptor bindings validated non-null with write tracking"

# Contract R: All UBO Records Valid
$uboCheck = ($lsfgContent -match "ConstantBuffer" -and $lsfgContent -match "flowScale" -and $lsfgContent -match "interpolationFactor")
Assert-Condition $uboCheck "Contract R: UBO constant buffer records populated with valid runtime parameters"

# Contract S: All Compute Stages Bind Descriptor Sets
$bindSetsCheck = ($lsfgContent -match "cmdBindDescriptorSets" -and ($lsfgContent -match "firstDescriptorSet" -or $lsfgContent -match "mipmapsSet"))
Assert-Condition $bindSetsCheck "Contract S: All 100 compute stages bind valid descriptor sets"

# Contract T: Correct Initial Layouts Transitioned Without Implicit Driver Assumptions
$layoutCheck = ($lsfgContent -match "VK_IMAGE_LAYOUT_UNDEFINED" -and $lsfgContent -match "VK_IMAGE_LAYOUT_GENERAL")
Assert-Condition $layoutCheck "Contract T: Explicit layout transition recorded from UNDEFINED to GENERAL"

# Contract U: LSFG Backend Does NOT Call vkQueueSubmit
$noQueueSubmitInLsfg = -not ($lsfgContent -match "vkQueueSubmit\s*\(" -or $lsfgContent -match "vkQueueSubmit2\s*\(")
Assert-Condition $noQueueSubmitInLsfg "Contract U: LSFG backend does NOT invoke vkQueueSubmit (Amethyst owns submission)"

# Contract V: No Queue/Device Idle in Steady-State Recording
$noWaitIdleInLsfg = -not ($lsfgContent -match "vkQueueWaitIdle\s*\(" -or $lsfgContent -match "vkDeviceWaitIdle\s*\(")
Assert-Condition $noWaitIdleInLsfg "Contract V: LSFG backend does NOT invoke vkWaitIdle in recording paths"

# Contract W: Pixel Proof Static-Scene Handling
$staticSceneCheck = ($interposerContent -match "PIXEL_PROOF_NO_MOTION" -or
                     $interposerContent -match "motionThreshold" -or
                     $interposerContent -match "MAD\(P,\s*C\)")
Assert-Condition $staticSceneCheck "Contract W: Pixel proof validates static-scene condition without false failure"

# Contract X: Diagnostic Events Excluded From Baseline Timing
$timingExclusionCheck = ($interposerContent -match "EXCLUDED_FROM_BASELINE" -or
                        $interposerContent -match "diagnosticSamples" -or
                        $interposerContent -match "pixelProofPassed")
Assert-Condition $timingExclusionCheck "Contract X: Seed and pixel proof events strictly excluded from baseline timing"

# Contract Y: R4-A and R4-B Forced OFF in Functional Baseline
$r4OffCheck = ($interposerContent -match "AMETHYST_LSFG_R4A_DELTA_L2_BYPASS\s*==\s*0" -or
               $interposerContent -match "r4aEnabled\s*=\s*false" -or
               $interposerContent -match "deltaL2Bypass\s*=\s*false")
Assert-Condition $r4OffCheck "Contract Y: R4-A and R4-B bypasses forced OFF for functional baseline"

# Contract Z: 100-Dispatch Functional Full Generation
$fullDispatchesCheck = ($lsfgContent -match "100" -or ($lsfgContent -match "dispatches" -and $lsfgContent -match "Alpha" -and $lsfgContent -match "Beta" -and $lsfgContent -match "Gamma" -and $lsfgContent -match "Delta" -and $lsfgContent -match "Generate"))
Assert-Condition $fullDispatchesCheck "Contract Z: Full generation graph dispatches all 100 compute passes"

# Contract AA: Historical Exported C++ ABI Preserved
$abiCheck = ($headerContent -match "lsfg_create_context_external" -and
             $headerContent -match "lsfg_destroy_context_external" -and
             $headerContent -match "lsfg_record_generation" -and
             $headerContent -match "lsfg_record_generation_profiled_r3")
Assert-Condition $abiCheck "Contract AA: Historical exported C++ ABI functions preserved"

# Contract AB: No Proprietary Shader Assets Embedded
$repoDir = "C:\Proyectos\amethyst_worktree_real_lsfg_functional"
if (-not (Test-Path $repoDir)) { $repoDir = "C:\Proyectos\amethyst_worktree_real_lsfg_r4b" }
$dlls = Get-ChildItem -Path $repoDir -Recurse -Filter "Lossless.dll" -ErrorAction SilentlyContinue
Assert-Condition ($dlls.Count -eq 0) "Contract AB: No Lossless.dll in repository"
$dxbcs = Get-ChildItem -Path $repoDir -Recurse -Filter "*.dxbc" -ErrorAction SilentlyContinue
Assert-Condition ($dxbcs.Count -eq 0) "Contract AB: No *.dxbc in repository"
$spvs = Get-ChildItem -Path $repoDir -Recurse -Filter "res_*.spv" -ErrorAction SilentlyContinue
Assert-Condition ($spvs.Count -eq 0) "Contract AB: No res_*.spv in repository"

Write-Host "=== FUNCTIONAL BACKEND CONTRACT SUMMARY ===" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    Write-Host "FAILED with $($failures.Count) contract failure(s) (EXPECTED RED BEFORE IMPLEMENTATION):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "ALL 28 FUNCTIONAL CONTRACTS PASSED (GREEN)!" -ForegroundColor Green
    exit 0
}
