# ==============================================================================
# REAL-LSFG-R2 Per-Stage GPU Profiling Contract Test
# ==============================================================================
$ErrorActionPreference = "Stop"

$amethystPath = "C:\Proyectos\amethyst"
$interposerFile = Join-Path $amethystPath "app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
$lsfgHppFile = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\public\lsfg_3_1.hpp"
$lsfgCppFile = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\v3.1_src\lsfg.cpp"

if (-not (Test-Path $interposerFile)) {
    Write-Error "Interposer file not found: $interposerFile"
    exit 1
}
if (-not (Test-Path $lsfgHppFile)) {
    Write-Error "LSFG header file not found: $lsfgHppFile"
    exit 1
}
if (-not (Test-Path $lsfgCppFile)) {
    Write-Error "LSFG source file not found: $lsfgCppFile"
    exit 1
}

$interposerSource = Get-Content -Path $interposerFile -Raw
$lsfgHppSource = Get-Content -Path $lsfgHppFile -Raw
$lsfgCppSource = Get-Content -Path $lsfgCppFile -Raw

$allPassed = $true

function Report-Contract {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Description
    )
    if ($Condition) {
        Write-Host "[$Name] PASS" -ForegroundColor Green
    } else {
        Write-Host "[$Name] FAIL: $Description" -ForegroundColor Red
        $script:allPassed = $false
    }
}

Write-Host "Running REAL-LSFG-R2 Contract Tests..." -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# Contract A: queryCount == 9 per TransportSlot
# ------------------------------------------------------------------------------
$hasQueryCount9 = ($interposerSource -match 'qpInfo\.queryCount\s*=\s*9;') -or
                  ($interposerSource -match 'queryCount\s*=\s*9;')
$hasReset9 = ($interposerSource -match 'cmdResetQueryPool\s*\(\s*cmdBuf\s*,\s*slot\.timestampQueryPool\s*,\s*0\s*,\s*9\s*\)')
$hasGet9 = ($interposerSource -match 'getQueryPoolResults\s*\([\s\S]*?slot\.timestampQueryPool\s*,\s*0\s*,\s*9\s*,')
$condA = $hasQueryCount9 -and $hasReset9 -and $hasGet9
Report-Contract "Contract A" $condA "Query pool created, reset, and retrieved with queryCount == 9 per slot."

# ------------------------------------------------------------------------------
# Contract B: Q0..Q6 emitted inside LS-FG
# ------------------------------------------------------------------------------
$hasQ0Inside = ($lsfgCppSource -match 'emitTimestamp\s*\(\s*0\s*\)') -or ($lsfgCppSource -match 'cmdWriteTimestamp[\s\S]*?qBase\s*\+\s*0')
$hasQ6Inside = ($lsfgCppSource -match 'emitTimestamp\s*\(\s*6\s*\)') -or ($lsfgCppSource -match 'cmdWriteTimestamp[\s\S]*?qBase\s*\+\s*6')
$noQ0ToQ6InAmethyst = -not ($interposerSource -match 'cmdWriteTimestamp[\s\S]*?slot\.timestampQueryPool\s*,\s*1[\s\S]*?cmdWriteTimestamp[\s\S]*?slot\.timestampQueryPool\s*,\s*2[\s\S]*?lsfg_record_generation')
$condB = $hasQ0Inside -and $hasQ6Inside -and $noQ0ToQ6InAmethyst
Report-Contract "Contract B" $condB "Q0..Q6 emitted internally by LS-FG dispatch graph; Amethyst does not reconstruct stages."

# ------------------------------------------------------------------------------
# Contract C: Q1..Q5 occur after EXISTING terminal stage barriers
# ------------------------------------------------------------------------------
$mipBarrierBeforeQ1 = ($lsfgCppSource -match 'emitComputeBarrier\(\);[\s\r\n]*emitTimestamp\(1\);') -or
                      ($lsfgCppSource -match 'cmdPipelineBarrier[\s\S]*?emitTimestamp\(1\);')
$deltaBarrierBeforeQ5 = ($lsfgCppSource -match 'emitComputeBarrier\(\);[\s\r\n]*\}[\s\r\n]*emitTimestamp\(5\);') -or
                        ($lsfgCppSource -match 'emitComputeBarrier\(\);[\s\S]*?emitTimestamp\(5\);')
$condC = $mipBarrierBeforeQ1 -and $deltaBarrierBeforeQ5
Report-Contract "Contract C" $condC "Stage boundary timestamps Q1..Q5 occur after existing terminal stage barriers."

# ------------------------------------------------------------------------------
# Contract D: No new compute barriers added
# ------------------------------------------------------------------------------
$recBlock = [regex]::Match($lsfgCppSource, '(?:record_generation_internal|lsfg_record_generation)[\s\S]*?return\s+VK_SUCCESS;')
$barrierCallsInRec = if ($recBlock.Success) { ([regex]::Matches($recBlock.Value, 'ctx->cmdPipelineBarrier\s*\(')).Count } else { 0 }
$condD = ($barrierCallsInRec -eq 2)
Report-Contract "Contract D" $condD "Zero new compute barriers introduced in LS-FG recording (exactly 2 cmdPipelineBarrier call sites)."

# ------------------------------------------------------------------------------
# Contract E: Dispatch graph remains 100 dispatches
# ------------------------------------------------------------------------------
$dispatchCallsInRec = if ($recBlock.Success) { ([regex]::Matches($recBlock.Value, 'ctx->cmdDispatch\s*\(')).Count } else { 0 }
$condE = ($dispatchCallsInRec -eq 6)
Report-Contract "Contract E" $condE "Dispatch graph retains exactly 6 dispatch call sites (1+28+5+35+30+1 = 100 dispatches)."

# ------------------------------------------------------------------------------
# Contract F: Q7 follows G->D segment
# ------------------------------------------------------------------------------
$qpBlock = [regex]::Match($interposerSource, 'interposer_vkQueuePresentKHR[\s\S]*?return\s+resN;')
$condF = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $posGtoD = $qpText.IndexOf('slot.generatedImage')
    $posQ7 = $qpText.IndexOf('slot.timestampQueryPool, 7')
    if ($posGtoD -ge 0 -and $posQ7 -ge 0 -and $posGtoD -lt $posQ7) {
        $condF = $true
    }
}
Report-Contract "Contract F" $condF "Q7 timestamp immediately follows Hop 1 G->D copy segment."

# ------------------------------------------------------------------------------
# Contract G: Q8 follows D->M segment and precedes C->P history update
# ------------------------------------------------------------------------------
$condG = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $posDtoM = $qpText.IndexOf('transport.swapchainImages[M]')
    $posQ8 = $qpText.IndexOf('slot.timestampQueryPool, 8')
    $posCtoP = if ($posQ8 -ge 0) { $qpText.IndexOf('transport.b2bHistoryImage', $posQ8) } else { -1 }
    if ($posDtoM -ge 0 -and $posQ8 -ge 0 -and $posCtoP -ge 0 -and $posDtoM -lt $posQ8 -and $posQ8 -lt $posCtoP) {
        $condG = $true
    }
}
Report-Contract "Contract G" $condG "Q8 timestamp follows Hop 2 D->M segment and strictly precedes C->P history update."

# ------------------------------------------------------------------------------
# Contract H: Integer telescoping invariants
# ------------------------------------------------------------------------------
$hasLsfgTelescoping = ($interposerSource -match 'dMip\s*\+\s*dAlpha\s*\+\s*dBeta\s*\+\s*dGamma\s*\+\s*dDelta\s*\+\s*dGen\s*==\s*dLsfg') -or
                      ($interposerSource -match 'dMip[\s\S]*?dAlpha[\s\S]*?dBeta[\s\S]*?dGamma[\s\S]*?dDelta[\s\S]*?dGen[\s\S]*?==\s*dLsfg')
$hasTotalTelescoping = ($interposerSource -match 'dLsfg\s*\+\s*dGtoDSegment\s*\+\s*dDtoMSegment\s*==\s*dComparableTotal') -or
                       ($interposerSource -match 'dLsfg[\s\S]*?dGtoDSegment[\s\S]*?dDtoMSegment[\s\S]*?==\s*dComparableTotal')
$hasViolationCounter = ($interposerSource -match 'g_r2TelescopingViolations')
$condH = $hasLsfgTelescoping -and $hasTotalTelescoping -and $hasViolationCounter
Report-Contract "Contract H" $condH "Integer raw tick telescoping invariants implemented with violation tracking."

# ------------------------------------------------------------------------------
# Contract I: No VK_QUERY_RESULT_WAIT_BIT
# ------------------------------------------------------------------------------
$noQueryResultWaitBit = -not ($interposerSource -match 'VK_QUERY_RESULT_WAIT_BIT')
Report-Contract "Contract I" $noQueryResultWaitBit "Query result retrieval must NOT use VK_QUERY_RESULT_WAIT_BIT."

# ------------------------------------------------------------------------------
# Contract J: No vkQueueWaitIdle in hot path
# ------------------------------------------------------------------------------
$noQueueWaitIdle = -not ($qpBlock.Success -and ($qpBlock.Value -match 'queueWaitIdle'))
Report-Contract "Contract J" $noQueueWaitIdle "Zero queueWaitIdle calls permitted in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract K: No vkDeviceWaitIdle in hot path
# ------------------------------------------------------------------------------
$noDeviceWaitIdle = -not ($qpBlock.Success -and ($qpBlock.Value -match 'deviceWaitIdle'))
Report-Contract "Contract K" $noDeviceWaitIdle "Zero deviceWaitIdle calls permitted in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract L: Existing R1 API/symbol retained and new profiled entry point present
# ------------------------------------------------------------------------------
$hasOldApiHpp = ($lsfgHppSource -match 'VkResult\s+lsfg_record_generation\s*\([\s\S]*?LsfgExternalContextHandle[\s\S]*?VkCommandBuffer[\s\S]*?uint32_t[\s\S]*?uint64_t[\s\S]*?float\s+interpolationFactor\s*\);')
$hasNewApiHpp = ($lsfgHppSource -match 'VkResult\s+lsfg_record_generation_profiled\s*\([\s\S]*?const\s+LsfgStageProfilingInfo\s*\*\s*profiling\s*\);')
$hasOldApiCpp = ($lsfgCppSource -match 'VkResult\s+lsfg_record_generation\s*\([\s\S]*?float\s+interpolationFactor\s*\)')
$hasNewApiCpp = ($lsfgCppSource -match 'VkResult\s+lsfg_record_generation_profiled\s*\([\s\S]*?const\s+LsfgStageProfilingInfo\s*\*\s*profiling\s*\)')
$condL = $hasOldApiHpp -and $hasNewApiHpp -and $hasOldApiCpp -and $hasNewApiCpp
Report-Contract "Contract L" $condL "Existing R1 API symbol preserved exactly, and lsfg_record_generation_profiled added."

# ------------------------------------------------------------------------------
# Contract M: Profiling-disabled LSFG graph remains unchanged
# ------------------------------------------------------------------------------
$disabledCheck = ($lsfgCppSource -match 'bool\s+profileActive\s*=\s*\(profiling\s*!=\s*nullptr\s*&&\s*profiling->enabled') -or
                 ($lsfgCppSource -match 'if\s*\(\s*profileActive\b') -or
                 ($lsfgCppSource -match 'bool\s+active\s*=\s*\(profiling\s*!=\s*nullptr\s*&&\s*profiling->enabled')
Report-Contract "Contract M" $disabledCheck "When profiling is disabled or null, zero timestamp commands are recorded."

# ------------------------------------------------------------------------------
# Contract N: R0 contract green
# ------------------------------------------------------------------------------
$r0TestPath = "C:\Proyectos\SGSR\native\lsfg-android\v2b1b_real_lsfg_r0_contract_test.ps1"
$r0Passed = $false
if (Test-Path $r0TestPath) {
    $r0Res = powershell -ExecutionPolicy Bypass -File $r0TestPath 2>&1
    if ($LASTEXITCODE -eq 0) { $r0Passed = $true }
}
Report-Contract "Contract N" $r0Passed "R0 contract test remains 100% green."

# ------------------------------------------------------------------------------
# Contract O: R1 contract green
# ------------------------------------------------------------------------------
$r1TestPath = "C:\Proyectos\SGSR\native\lsfg-android\v2b1b_real_lsfg_r1_contract_test.ps1"
$r1Passed = $false
if (Test-Path $r1TestPath) {
    $r1Res = powershell -ExecutionPolicy Bypass -File $r1TestPath 2>&1
    if ($LASTEXITCODE -eq 0) { $r1Passed = $true }
}
Report-Contract "Contract O" $r1Passed "R1 contract test remains 100% green."

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "REAL-LSFG-R2 CONTRACT SUITE: ALL CONTRACTS PASSED (GREEN)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "REAL-LSFG-R2 CONTRACT SUITE: CONTRACTS FAILED (RED)" -ForegroundColor Red
    exit 1
}
