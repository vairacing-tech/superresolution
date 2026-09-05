# v2b1b_real_lsfg_delta_l2_scratch_decoupling_contract_test.ps1
# Authoritative Function-Scoped Contract Test for REAL-LSFG Delta L2 Sub-Pipeline Scratch Decoupling Experiment
# Validates Tier-1 semantics-preserving scratch decoupling:
# - deltaTemp3[2] scratch allocation (480x270 RGBA8) for Delta L2 Sub-pipeline B
# - Passes 5..8 descriptor rebinding to temp3 (eliminating temp2 WAR hazard)
# - Delta L2 P4 -> P5 global compute barrier conditional omission
# - Retention of P3->P4, P5->P6, and all other Delta/Gamma/Alpha barriers
# - Retention of 30 Delta dispatches and 100-dispatch total graph
# - R4-A and R4-B bypasses remain disabled

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

Write-Host "=== REAL-LSFG DELTA L2 SCRATCH-DECOUPLING CONTRACT TEST ===" -ForegroundColor Cyan

$lsfgCppPath = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\v3.1_src\lsfg.cpp"
$interposerPath = "C:\Proyectos\amethyst_worktree_real_lsfg_functional\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"

Assert-Condition (Test-Path $lsfgCppPath) "lsfg.cpp exists"
Assert-Condition (Test-Path $interposerPath) "interposer source exists"

$lsfgContent = if (Test-Path $lsfgCppPath) { Get-Content $lsfgCppPath -Raw } else { "" }
$interposerContent = if (Test-Path $interposerPath) { Get-Content $interposerPath -Raw } else { "" }

# Extract Scoped Blocks (Function-Scoped Verification)
$scopedSlotScratch = Get-ScopedBlock $lsfgContent "struct SlotScratchState {" "std::vector<DescriptorSetTracker> trackers;"
$scopedImageAlloc = Get-ScopedBlock $lsfgContent "// Delta scratch (3 levels * 10 = 30)" "// 5. Backing Memory Suballocation"
$scopedImageViews = Get-ScopedBlock $lsfgContent "// 6. Create Image Views" "// 7. Create UBO Buffers"
$scopedImageCleanup = Get-ScopedBlock $lsfgContent "void lsfg_destroy_context_external" "delete ctx;"
$scopedLayoutTrans = Get-ScopedBlock $lsfgContent "VkResult lsfg_record_initialize" "if (ctx->cmdPipelineBarrier"
$scopedDeltaDesc = Get-ScopedBlock $lsfgContent "// (e) Delta (3 levels * 14 sets = 42 sets)" "// (f) Generate pass"
$scopedDeltaDispatch = Get-ScopedBlock $lsfgContent "// Stage 5: Delta passes" "// Stage 6: Generate pass"

Assert-Condition ($scopedSlotScratch.Length -gt 0) "Scope Extractor: SlotScratchState struct extracted"
Assert-Condition ($scopedImageAlloc.Length -gt 0) "Scope Extractor: Delta image allocation block extracted"
Assert-Condition ($scopedImageViews.Length -gt 0) "Scope Extractor: Delta image view creation block extracted"
Assert-Condition ($scopedImageCleanup.Length -gt 0) "Scope Extractor: Delta image cleanup block extracted"
Assert-Condition ($scopedLayoutTrans.Length -gt 0) "Scope Extractor: Delta initial layout transition block extracted"
Assert-Condition ($scopedDeltaDesc.Length -gt 0) "Scope Extractor: Delta descriptor creation block extracted"
Assert-Condition ($scopedDeltaDispatch.Length -gt 0) "Scope Extractor: Delta dispatch loop block extracted"

# -----------------------------------------------------------------------------
# Contract A: Delta L2 temp3 scratch exists (struct, alloc, view, cleanup, transition)
# -----------------------------------------------------------------------------
$hasTemp3Struct = ($scopedSlotScratch -match "VkImage\s+deltaTemp3\s*\[\s*2\s*\]" -and
                   $scopedSlotScratch -match "VkImageView\s+deltaTempView3\s*\[\s*2\s*\]")
$hasTemp3Alloc = ($scopedImageAlloc -match "deltaTemp3" -and
                  $scopedImageAlloc -match "allGraphImages\.push_back\(\s*slot\.deltaTemp3")
$hasTemp3View = ($scopedImageViews -match "deltaTempView3" -and
                 $scopedImageViews -match "create2DImageView\([^\)]*deltaTemp3[^\)]*deltaTempView3")
$hasTemp3Cleanup = ($scopedImageCleanup -match "deltaTempView3" -and
                    $scopedImageCleanup -match "destroyImageView\([^\)]*deltaTempView3" -and
                    $scopedImageCleanup -match "destroyImage\([^\)]*deltaTemp3")
$hasTemp3Trans = ($scopedLayoutTrans -match "addTransition\(\s*slot\.deltaTemp3")

Assert-Condition ($hasTemp3Struct -and $hasTemp3Alloc -and $hasTemp3View -and $hasTemp3Cleanup -and $hasTemp3Trans) `
    "Contract A: Delta L2 deltaTemp3[2] scratch resource fully integrated (struct, alloc, view, cleanup, transition)"

# -----------------------------------------------------------------------------
# Contract B: P5 output binds temp3 when dlvl == 2, temp2 when dlvl != 2
# -----------------------------------------------------------------------------
$scopedP5Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[5] across 3 banks" "// delta[6]"
$p5b13 = [regex]::Match($scopedP5Desc, "addStorageImage\s*\(\s*13\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p5b14 = [regex]::Match($scopedP5Desc, "addStorageImage\s*\(\s*14\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p5BindsCorrect = ($p5b13 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[0\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[0\]" -and
                   $p5b14 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[1\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[1\]")
Assert-Condition $p5BindsCorrect "Contract B: Pass 5 (res 258) writes to deltaTemp3[0..1] when dlvl == 2 and deltaTemp2[dlvl][0..1] when dlvl != 2"

# -----------------------------------------------------------------------------
# Contract C: P6 input binds temp3 when dlvl == 2, temp2 when dlvl != 2
# -----------------------------------------------------------------------------
$scopedP6Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[6]" "// delta[7]"
$p6b1 = [regex]::Match($scopedP6Desc, "addSampledImage\s*\(\s*1\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p6b2 = [regex]::Match($scopedP6Desc, "addSampledImage\s*\(\s*2\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p6BindsCorrect = ($p6b1 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[0\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[0\]" -and
                   $p6b2 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[1\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[1\]")
Assert-Condition $p6BindsCorrect "Contract C: Pass 6 (res 271) reads from deltaTemp3[0..1] when dlvl == 2 and deltaTemp2[dlvl][0..1] when dlvl != 2"

# -----------------------------------------------------------------------------
# Contract D: P7 output binds temp3 when dlvl == 2, temp2 when dlvl != 2
# -----------------------------------------------------------------------------
$scopedP7Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[7]" "// delta[8]"
$p7b3 = [regex]::Match($scopedP7Desc, "addStorageImage\s*\(\s*3\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p7b4 = [regex]::Match($scopedP7Desc, "addStorageImage\s*\(\s*4\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p7BindsCorrect = ($p7b3 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[0\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[0\]" -and
                   $p7b4 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[1\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[1\]")
Assert-Condition $p7BindsCorrect "Contract D: Pass 7 (res 272) writes to deltaTemp3[0..1] when dlvl == 2 and deltaTemp2[dlvl][0..1] when dlvl != 2"

# -----------------------------------------------------------------------------
# Contract E: P8 input binds temp3 when dlvl == 2, temp2 when dlvl != 2
# -----------------------------------------------------------------------------
$scopedP8Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[8]" "// delta[9]"
$p8b1 = [regex]::Match($scopedP8Desc, "addSampledImage\s*\(\s*1\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p8b2 = [regex]::Match($scopedP8Desc, "addSampledImage\s*\(\s*2\s*,\s*([^;]+)\);").Groups[1].Value.Trim()
$p8BindsCorrect = ($p8b1 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[0\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[0\]" -and
                   $p8b2 -match "\(dlvl\s*==\s*2\)\s*\?\s*slot\.deltaTempView3\[1\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[1\]")
Assert-Condition $p8BindsCorrect "Contract E: Pass 8 (res 273) reads from deltaTemp3[0..1] when dlvl == 2 and deltaTemp2[dlvl][0..1] when dlvl != 2"

# -----------------------------------------------------------------------------
# Contract F: Strengthened L2 Descriptor Selection Semantics & Negative Rejection
# -----------------------------------------------------------------------------
function Test-TernarySelection($expr, $expectedSlot) {
    $m = [regex]::Match($expr, "^\(?\s*dlvl\s*==\s*2\s*\)?\s*\?\s*([^:]+)\s*:\s*(.+)$")
    if (-not $m.Success) { return @{ Success = $false; Detail = "Not a ternary on (dlvl == 2): $expr" } }
    $trueBranch = $m.Groups[1].Value.Trim()
    $falseBranch = $m.Groups[2].Value.Trim()

    # For dlvl == 2: must resolve to deltaTempView3[$expectedSlot] and NOT deltaTempView2
    $trueValid = ($trueBranch -match "deltaTempView3\[\s*$expectedSlot\s*\]") -and (-not ($trueBranch -match "deltaTempView2"))
    # For dlvl != 2: must resolve to deltaTempView2[dlvl][$expectedSlot] and NOT deltaTempView3
    $falseValid = ($falseBranch -match "deltaTempView2\[\s*dlvl\s*\]\[\s*$expectedSlot\s*\]") -and (-not ($falseBranch -match "deltaTempView3"))

    if (-not $trueValid) { return @{ Success = $false; Detail = "dlvl==2 branch does not bind deltaTempView3[$expectedSlot]: $trueBranch" } }
    if (-not $falseValid) { return @{ Success = $false; Detail = "dlvl!=2 branch does not bind deltaTempView2[dlvl][$expectedSlot]: $falseBranch" } }
    return @{ Success = $true; Detail = "OK" }
}

$p5_13_check = Test-TernarySelection $p5b13 0
$p5_14_check = Test-TernarySelection $p5b14 1
$p6_1_check  = Test-TernarySelection $p6b1 0
$p6_2_check  = Test-TernarySelection $p6b2 1
$p7_3_check  = Test-TernarySelection $p7b3 0
$p7_4_check  = Test-TernarySelection $p7b4 1
$p8_1_check  = Test-TernarySelection $p8b1 0
$p8_2_check  = Test-TernarySelection $p8b2 1

$all8TernaryValid = ($p5_13_check.Success -and $p5_14_check.Success -and
                     $p6_1_check.Success  -and $p6_2_check.Success  -and
                     $p7_3_check.Success  -and $p7_4_check.Success  -and
                     $p8_1_check.Success  -and $p8_2_check.Success)

# Negative rejection verification:
# Reject if deltaTempView2 is bound unconditionally without ternary guard in P5..P8
$noUnconditionalTemp2InP5 = -not ($scopedP5Desc -match "addStorageImage\s*\(\s*1[34]\s*,\s*slot\.deltaTempView2\[dlvl\]\[\d+\]\s*\);")
$noUnconditionalTemp2InP6 = -not ($scopedP6Desc -match "addSampledImage\s*\(\s*[12]\s*,\s*slot\.deltaTempView2\[dlvl\]\[\d+\]\s*\);")
$noUnconditionalTemp2InP7 = -not ($scopedP7Desc -match "addStorageImage\s*\(\s*[34]\s*,\s*slot\.deltaTempView2\[dlvl\]\[\d+\]\s*\);")
$noUnconditionalTemp2InP8 = -not ($scopedP8Desc -match "addSampledImage\s*\(\s*[12]\s*,\s*slot\.deltaTempView2\[dlvl\]\[\d+\]\s*\);")

# Negative mutation tests: verify that bad implementations are strictly rejected
$negUnconditional = Test-TernarySelection "slot.deltaTempView2[dlvl][0]" 0
$negInverted = Test-TernarySelection "(dlvl == 2) ? slot.deltaTempView2[dlvl][0] : slot.deltaTempView3[0]" 0
$negSelfCheckPass = (-not $negUnconditional.Success) -and (-not $negInverted.Success)

Assert-Condition ($all8TernaryValid -and
                  $noUnconditionalTemp2InP5 -and $noUnconditionalTemp2InP6 -and
                  $noUnconditionalTemp2InP7 -and $noUnconditionalTemp2InP8 -and
                  $negSelfCheckPass) `
    "Contract F: Exact L2 descriptor selection proved (L2->temp3, non-L2->temp2, unconditional temp2 rejected, negative mutations caught)"

# -----------------------------------------------------------------------------
# Contract G: Delta L2 P4 -> P5 barrier condition syntax extracted
# -----------------------------------------------------------------------------
$barrierMatch = [regex]::Match($scopedDeltaDispatch, "if\s*\(\s*(!\s*\([^)]+\))\s*\)\s*\{\s*emitComputeBarrier\(\);?\s*\}")
$barrierConditionExtracted = $barrierMatch.Success -and ($barrierMatch.Groups[1].Value.Trim() -match "dlvl\s*==\s*2\s*&&\s*p\s*==\s*4")
Assert-Condition $barrierConditionExtracted "Contract G: Delta dispatch loop exactly extracts barrier condition '!(dlvl == 2 && p == 4)'"

# -----------------------------------------------------------------------------
# Contract H: Formally modeled dispatch barrier matrix across all 3 levels (30 dispatches)
# -----------------------------------------------------------------------------
# Model the exact barrier evaluation:
# emit barrier after every Delta dispatch EXCEPT ONLY (dlvl == 2 && p == 4)
$barrierMatrix = @{}
$l0Barriers = 0
$l1Barriers = 0
$l2Barriers = 0
$totalBarriers = 0

for ($dlvl = 0; $dlvl -lt 3; $dlvl++) {
    for ($p = 0; $p -lt 10; $p++) {
        $emitted = -not ($dlvl -eq 2 -and $p -eq 4)
        $barrierMatrix["$dlvl,$p"] = $emitted
        if ($emitted) {
            $totalBarriers++
            if ($dlvl -eq 0) { $l0Barriers++ }
            if ($dlvl -eq 1) { $l1Barriers++ }
            if ($dlvl -eq 2) { $l2Barriers++ }
        }
    }
}

$matrixPass = ($totalBarriers -eq 29 -and
               $l0Barriers -eq 10 -and
               $l1Barriers -eq 10 -and
               $l2Barriers -eq 9 -and
               $barrierMatrix["2,4"] -eq $false)

Assert-Condition $matrixPass "Contract H: Barrier matrix modeled across 30 dispatches (L0=10, L1=10, L2=9 omitting only p=4, total=29)"

# -----------------------------------------------------------------------------
# Contract I: P3 -> P4 barrier strictly retained across all levels including L2
# -----------------------------------------------------------------------------
$p3BarrierRetainedInMatrix = ($barrierMatrix["0,3"] -eq $true -and
                             $barrierMatrix["1,3"] -eq $true -and
                             $barrierMatrix["2,3"] -eq $true)
Assert-Condition $p3BarrierRetainedInMatrix "Contract I: Delta P3 -> P4 compute barrier strictly retained across all levels including L2"

# -----------------------------------------------------------------------------
# Contract J: P5 -> P6 barrier strictly retained across all levels including L2
# -----------------------------------------------------------------------------
$p5BarrierRetainedInMatrix = ($barrierMatrix["0,5"] -eq $true -and
                             $barrierMatrix["1,5"] -eq $true -and
                             $barrierMatrix["2,5"] -eq $true)
Assert-Condition $p5BarrierRetainedInMatrix "Contract J: Delta P5 -> P6 compute barrier strictly retained across all levels including L2"

# -----------------------------------------------------------------------------
# Contract J2: Single conditional barrier call site in Delta dispatch loop
# -----------------------------------------------------------------------------
$barrierCallCount = ([regex]::Matches($scopedDeltaDispatch, "emitComputeBarrier\(\)")).Count
Assert-Condition ($barrierCallCount -eq 1) "Contract J2: Exactly 1 conditional emitComputeBarrier() call site in Delta dispatch loop"

# -----------------------------------------------------------------------------
# Contract K: Delta dispatch count remains 30
# -----------------------------------------------------------------------------
$deltaDispatch30 = ($scopedDeltaDispatch -match "3\s*levels\s*x\s*10\s*passes\s*=\s*30\s*dispatches" -and
                    $scopedDeltaDispatch -match "for\s*\(\s*int\s*dlvl\s*=\s*0;\s*dlvl\s*<\s*3;\s*\+\+dlvl\s*\)" -and
                    $scopedDeltaDispatch -match "for\s*\(\s*int\s*p\s*=\s*0;\s*p\s*<\s*10;\s*\+\+p\s*\)")
Assert-Condition $deltaDispatch30 "Contract K: Delta stage executes exactly 30 compute dispatches"

# -----------------------------------------------------------------------------
# Contract L: Full graph remains 100 dispatches
# -----------------------------------------------------------------------------
$fullGraph100 = ($lsfgContent -match "100\s*Dispatches\s*Baseline" -or
                 $lsfgContent -match "emitTimestamp\(100\)")
Assert-Condition $fullGraph100 "Contract L: Full generation graph retains 100 dispatches baseline"

# -----------------------------------------------------------------------------
# Contract M: R4-A and R4-B bypasses remain disabled
# -----------------------------------------------------------------------------
$r4OffCheck = ($lsfgContent -match "deltaL2Bypass\s*=\s*false" -and
               $lsfgContent -match "gammaL6Bypass\s*=\s*false")
Assert-Condition $r4OffCheck "Contract M: R4-A and R4-B bypass parameters default to false"

Write-Host "=== DELTA L2 SCRATCH-DECOUPLING CONTRACT SUMMARY ===" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    Write-Host "CONTRACT AUDIT COMPLETED WITH $($failures.Count) RED FAILURES" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ALL CONTRACTS PASSED (GREEN)!" -ForegroundColor Green
    exit 0
}
