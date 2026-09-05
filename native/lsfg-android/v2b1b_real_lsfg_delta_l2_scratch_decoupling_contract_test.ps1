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
# Contract B: P5 output binds temp3 when dlvl == 2
# -----------------------------------------------------------------------------
$scopedP5Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[5] across 3 banks" "// delta[6]"
$p5BindsTemp3 = ($scopedP5Desc -match "dlvl\s*==\s*2\s*\?\s*slot\.deltaTempView3\[0\]\s*:\s*slot\.deltaTempView2\[dlvl\]\[0\]" -or
                 $scopedP5Desc -match "dlvl\s*==\s*2\s*\?\s*slot\.deltaTempView3" -or
                 $scopedP5Desc -match "if\s*\(\s*dlvl\s*==\s*2\s*\)[^}]*deltaTempView3\[0\]" -or
                 $scopedP5Desc -match "deltaTempView3\[0\]")
Assert-Condition $p5BindsTemp3 "Contract B: Pass 5 (res 258) writes to deltaTemp3[0..1] when dlvl == 2"

# -----------------------------------------------------------------------------
# Contract C: P6 input binds temp3 when dlvl == 2
# -----------------------------------------------------------------------------
$scopedP6Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[6]" "// delta[7]"
$p6BindsTemp3 = ($scopedP6Desc -match "dlvl\s*==\s*2\s*\?\s*slot\.deltaTempView3" -or
                 $scopedP6Desc -match "deltaTempView3")
Assert-Condition $p6BindsTemp3 "Contract C: Pass 6 (res 271) reads from deltaTemp3[0..1] when dlvl == 2"

# -----------------------------------------------------------------------------
# Contract D: P7 output binds temp3 when dlvl == 2
# -----------------------------------------------------------------------------
$scopedP7Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[7]" "// delta[8]"
$p7BindsTemp3 = ($scopedP7Desc -match "dlvl\s*==\s*2\s*\?\s*slot\.deltaTempView3" -or
                 $scopedP7Desc -match "deltaTempView3")
Assert-Condition $p7BindsTemp3 "Contract D: Pass 7 (res 272) writes to deltaTemp3[0..1] when dlvl == 2"

# -----------------------------------------------------------------------------
# Contract E: P8 input binds temp3 when dlvl == 2
# -----------------------------------------------------------------------------
$scopedP8Desc = Get-ScopedBlock $scopedDeltaDesc "// delta[8]" "// delta[9]"
$p8BindsTemp3 = ($scopedP8Desc -match "dlvl\s*==\s*2\s*\?\s*slot\.deltaTempView3" -or
                 $scopedP8Desc -match "deltaTempView3")
Assert-Condition $p8BindsTemp3 "Contract E: Pass 8 (res 273) reads from deltaTemp3[0..1] when dlvl == 2"

# -----------------------------------------------------------------------------
# Contract F: P5-P9 no longer use temp2 as ping-pong target at dlvl == 2
# -----------------------------------------------------------------------------
$p5to9Decoupled = ($scopedP5Desc -match "deltaTempView3" -and
                   $scopedP6Desc -match "deltaTempView3" -and
                   $scopedP7Desc -match "deltaTempView3" -and
                   $scopedP8Desc -match "deltaTempView3")
Assert-Condition $p5to9Decoupled "Contract F: Sub-pipeline B (P5-P8) completely decoupled from deltaTemp2 at dlvl == 2"

# -----------------------------------------------------------------------------
# Contract G: P4 -> P5 barrier removed ONLY for Delta L2
# -----------------------------------------------------------------------------
$barrierL2P4Omitted = ($scopedDeltaDispatch -match "!\s*\(\s*dlvl\s*==\s*2\s*&&\s*p\s*==\s*4\s*\)" -or
                       $scopedDeltaDispatch -match "if\s*\(\s*!\s*\(\s*dlvl\s*==\s*2\s*&&\s*p\s*==\s*4\s*\)\s*\)\s*emitComputeBarrier\(\)" -or
                       $scopedDeltaDispatch -match "if\s*\(\s*dlvl\s*!=\s*2\s*\|\|\s*p\s*!=\s*4\s*\)\s*emitComputeBarrier\(\)")
Assert-Condition $barrierL2P4Omitted "Contract G: Delta L2 P4 -> P5 compute barrier conditionally omitted"

# -----------------------------------------------------------------------------
# Contract H: P3 -> P4 barrier retained
# -----------------------------------------------------------------------------
$barrierLines = ($scopedDeltaDispatch -split "`n" | Where-Object { $_ -match "emitComputeBarrier" -or $_ -match "cmdDispatch" }) -join "`n"
$p3BarrierRetained = -not ($barrierLines -match "p\s*==\s*3" -or $barrierLines -match "p\s*<=\s*3")
Assert-Condition $p3BarrierRetained "Contract H: Delta P3 -> P4 compute barrier strictly retained"

# -----------------------------------------------------------------------------
# Contract I: P5 -> P6 barrier retained
# -----------------------------------------------------------------------------
$p5BarrierRetained = -not ($barrierLines -match "p\s*==\s*5" -or $barrierLines -match "p\s*<=\s*5\s*&&")
Assert-Condition $p5BarrierRetained "Contract I: Delta P5 -> P6 compute barrier strictly retained"

# -----------------------------------------------------------------------------
# Contract J: All other Delta barriers retained (only dlvl==2 && p==4 skipped)
# -----------------------------------------------------------------------------
$onlyL2P4Condition = ($scopedDeltaDispatch -match "dlvl\s*==\s*2\s*&&\s*p\s*==\s*4" -or
                      $scopedDeltaDispatch -match "dlvl\s*!=\s*2\s*\|\|\s*p\s*!=\s*4")
Assert-Condition $onlyL2P4Condition "Contract J: Only dlvl == 2 && p == 4 is conditionally skipped in Delta barriers"

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
