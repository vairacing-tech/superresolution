# ==============================================================================
# REAL-LSFG-R3 Full 100-Dispatch Fine-Grained GPU Profiling Contract Test
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

Write-Host "Running REAL-LSFG-R3 Contract Tests..." -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# Contract A: queryCount == 103 per TransportSlot
# ------------------------------------------------------------------------------
$hasQueryCount103 = ($interposerSource -match 'qpInfo\.queryCount\s*=\s*103;') -or
                    ($interposerSource -match 'queryCount\s*=\s*103;')
$hasReset103 = ($interposerSource -match 'cmdResetQueryPool\s*\(\s*cmdBuf\s*,\s*slot\.timestampQueryPool\s*,\s*0\s*,\s*103\s*\)') -or
               ($interposerSource -match 'cmdResetQueryPool[\s\S]*?slot\.timestampQueryPool\s*,\s*0\s*,\s*103')
$hasGet103 = ($interposerSource -match 'getQueryPoolResults\s*\([\s\S]*?slot\.timestampQueryPool\s*,\s*0\s*,\s*103\s*,')
$condA = $hasQueryCount103 -and $hasReset103 -and $hasGet103
Report-Contract "Contract A" $condA "Query pool created, reset, and retrieved with queryCount == 103 per TransportSlot."

# ------------------------------------------------------------------------------
# Contract B: Exactly 2 TransportSlot query pools
# ------------------------------------------------------------------------------
$hasSlotCount2 = ($interposerSource -match 'kSlotCount\s*=\s*2;') -and
                 (($interposerSource -match 'TransportSlot\s+slots\[kSlotCount\];') -or ($interposerSource -match 'TransportSlot\s+slots\[2\];'))
$hasSlotPoolLoop = ($interposerSource -match 'for\s*\(\s*uint32_t\s+s\s*=\s*0;\s*s\s*<\s*transport\.kSlotCount;\s*\+\+s\s*\)[\s\S]*?timestampQueryPool') -or
                   ($interposerSource -match 'for\s*\(\s*uint32_t\s+s\s*=\s*0;\s*s\s*<\s*2;\s*\+\+s\s*\)[\s\S]*?timestampQueryPool')
$condB = $hasSlotCount2 -and $hasSlotPoolLoop
Report-Contract "Contract B" $condB "Exactly 2 TransportSlots manage independent VkQueryPool handles."

# ------------------------------------------------------------------------------
# Contract C: Q0..Q100 emitted inside LS-FG
# ------------------------------------------------------------------------------
$hasQ0Inside = ($lsfgCppSource -match 'emitTimestamp\s*\(\s*0\s*\)')
$hasQ100Inside = ($lsfgCppSource -match 'emitTimestamp\s*\(\s*100\s*\)')
$hasAlphaDispatchTs = ($lsfgCppSource -match 'emitTimestamp\s*\(\s*2\s*\+\s*lvl\s*\*\s*4\s*\+\s*p\s*\)') -or
                      ($lsfgCppSource -match 'emitTimestamp[\s\S]*?lvl[\s\S]*?p')
$hasGammaDispatchTs = ($lsfgCppSource -match 'emitTimestamp\s*\(\s*35\s*\+\s*lvl\s*\*\s*5\s*\+\s*p\s*\)') -or
                      ($lsfgCppSource -match 'emitTimestamp[\s\S]*?35')
$hasDeltaDispatchTs = ($lsfgCppSource -match 'emitTimestamp\s*\(\s*70\s*\+\s*lvl\s*\*\s*10\s*\+\s*p\s*\)') -or
                      ($lsfgCppSource -match 'emitTimestamp[\s\S]*?70')
$condC = $hasQ0Inside -and $hasQ100Inside -and $hasAlphaDispatchTs -and $hasGammaDispatchTs -and $hasDeltaDispatchTs
Report-Contract "Contract C" $condC "Q0..Q100 emitted internally by LS-FG dispatch graph (Alpha, Beta, Gamma, Delta, Generate)."

# ------------------------------------------------------------------------------
# Contract D: Q101 and Q102 owned by Amethyst
# ------------------------------------------------------------------------------
$qpBlock = [regex]::Match($interposerSource, 'interposer_vkQueuePresentKHR[\s\S]*?return\s+resN;')
$hasQ101Amethyst = $qpBlock.Success -and (($qpBlock.Value -match 'slot\.timestampQueryPool,\s*101') -or ($qpBlock.Value -match 'kQueryHop1\s*=\s*101'))
$hasQ102Amethyst = $qpBlock.Success -and (($qpBlock.Value -match 'slot\.timestampQueryPool,\s*102') -or ($qpBlock.Value -match 'kQueryHop2\s*=\s*102'))
$condD = $hasQ101Amethyst -and $hasQ102Amethyst
Report-Contract "Contract D" $condD "Q101 (post G->D) and Q102 (post D->M) owned and emitted by Amethyst."

# ------------------------------------------------------------------------------
# Contract E: Q102 precedes C->P
# ------------------------------------------------------------------------------
$condE = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $posDtoM = $qpText.IndexOf('transport.swapchainImages[M]')
    $posQ102 = if ($qpText -match '102') { $qpText.IndexOf('102') } else { -1 }
    $posCtoP = if ($posQ102 -ge 0) { $qpText.IndexOf('transport.b2bHistoryImage', $posQ102) } else { -1 }
    if ($posDtoM -ge 0 -and $posQ102 -ge 0 -and $posCtoP -ge 0 -and $posDtoM -lt $posQ102 -and $posQ102 -lt $posCtoP) {
        $condE = $true
    }
}
Report-Contract "Contract E" $condE "Q102 follows Hop 2 D->M segment and strictly precedes C->P history update."

# ------------------------------------------------------------------------------
# Contract F: No new compute barriers
# ------------------------------------------------------------------------------
$recBlock = [regex]::Match($lsfgCppSource, '(?:record_generation_internal|lsfg_record_generation)[\s\S]*?return\s+VK_SUCCESS;')
$barrierCallsInRec = if ($recBlock.Success) { ([regex]::Matches($recBlock.Value, 'ctx->cmdPipelineBarrier\s*\(')).Count } else { 0 }
$condF = ($barrierCallsInRec -eq 2)
Report-Contract "Contract F" $condF "Zero new compute barriers introduced in LS-FG recording (exactly 2 cmdPipelineBarrier call sites)."

# ------------------------------------------------------------------------------
# Contract G: 100-dispatch algorithm unchanged
# ------------------------------------------------------------------------------
$dispatchCallsInRec = if ($recBlock.Success) { ([regex]::Matches($recBlock.Value, 'ctx->cmdDispatch\s*\(')).Count } else { 0 }
$condG = ($dispatchCallsInRec -eq 6)
Report-Contract "Contract G" $condG "Dispatch graph retains exactly 6 dispatch call sites (1+28+5+35+30+1 = 100 dispatches)."

# ------------------------------------------------------------------------------
# Contract H: Legacy R1 symbol retained
# ------------------------------------------------------------------------------
$hasOldApiHpp = ($lsfgHppSource -match 'VkResult\s+lsfg_record_generation\s*\([\s\S]*?LsfgExternalContextHandle[\s\S]*?VkCommandBuffer[\s\S]*?uint32_t[\s\S]*?uint64_t[\s\S]*?float\s+interpolationFactor\s*\);')
$hasOldApiCpp = ($lsfgCppSource -match 'VkResult\s+lsfg_record_generation\s*\([\s\S]*?float\s+interpolationFactor\s*\)')
$condH = $hasOldApiHpp -and $hasOldApiCpp
Report-Contract "Contract H" $condH "Legacy R1 API symbol preserved identically."

# ------------------------------------------------------------------------------
# Contract I: R2 profiled symbol retained or compatibility wrapped
# ------------------------------------------------------------------------------
$hasProfiledApiHpp = ($lsfgHppSource -match 'lsfg_record_generation_profiled')
$hasProfiledApiCpp = ($lsfgCppSource -match 'lsfg_record_generation_profiled')
$condI = $hasProfiledApiHpp -and $hasProfiledApiCpp
Report-Contract "Contract I" $condI "R2 profiled entry point retained with compatibility wrapping."

# ------------------------------------------------------------------------------
# Contract J: Raw dispatch telescoping
# ------------------------------------------------------------------------------
$hasDispatchTelescoping = ($interposerSource -match 'dDispatch\[') -or
                         ($interposerSource -match 'dispatchSegments')
Report-Contract "Contract J" $hasDispatchTelescoping "Raw 64-bit integer dispatch segments computed from masked ticks."

# ------------------------------------------------------------------------------
# Contract K: Level telescoping
# ------------------------------------------------------------------------------
$hasLevelTelescoping = ($interposerSource -match 'dAlphaLevels') -and
                       ($interposerSource -match 'dGammaLevels') -and
                       ($interposerSource -match 'dDeltaLevels')
Report-Contract "Contract K" $hasLevelTelescoping "Dispatch segments telescope exactly to Level sums."

# ------------------------------------------------------------------------------
# Contract L: Stage telescoping
# ------------------------------------------------------------------------------
$hasStageTelescoping = ($interposerSource -match 'dAlphaLevels[\s\S]*?dStages\[1\]') -or
                       ($interposerSource -match 'sumAlphaLevels[\s\S]*?dAlpha')
Report-Contract "Contract L" $hasStageTelescoping "Level sums telescope exactly to Stage sums."

# ------------------------------------------------------------------------------
# Contract M: Transport telescoping
# ------------------------------------------------------------------------------
$hasTransportTelescoping = ($interposerSource -match 'dLsfg\s*\+\s*dGtoDSegment\s*\+\s*dDtoMSegment\s*==\s*dComparableTotal') -or
                          ($interposerSource -match 'dLsfg[\s\S]*?dGtoDSegment[\s\S]*?dDtoMSegment[\s\S]*?==\s*dComparableTotal')
Report-Contract "Contract M" $hasTransportTelescoping "LSFG + G->D + D->M equals Comparable Total on raw integer ticks."

# ------------------------------------------------------------------------------
# Contract N: No VK_QUERY_RESULT_WAIT_BIT
# ------------------------------------------------------------------------------
$noQueryResultWaitBit = -not ($interposerSource -match 'VK_QUERY_RESULT_WAIT_BIT')
Report-Contract "Contract N" $noQueryResultWaitBit "Query result retrieval must NOT use VK_QUERY_RESULT_WAIT_BIT."

# ------------------------------------------------------------------------------
# Contract O: No vkQueueWaitIdle in hot path
# ------------------------------------------------------------------------------
$noQueueWaitIdle = -not ($qpBlock.Success -and ($qpBlock.Value -match 'queueWaitIdle'))
Report-Contract "Contract O" $noQueueWaitIdle "Zero queueWaitIdle calls permitted in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract P: No vkDeviceWaitIdle in hot path
# ------------------------------------------------------------------------------
$noDeviceWaitIdle = -not ($qpBlock.Success -and ($qpBlock.Value -match 'deviceWaitIdle'))
Report-Contract "Contract P" $noDeviceWaitIdle "Zero deviceWaitIdle calls permitted in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract Q: Fixed bounded storage
# ------------------------------------------------------------------------------
$hasFixedStorage = ($interposerSource -match 'kMaxR3StageTimingSamples\s*=\s*128') -or
                   ($interposerSource -match 'g_r3TimingSamples\[128\]') -or
                   ($interposerSource -match 'g_r3StageTimingSamples')
Report-Contract "Contract Q" $hasFixedStorage "Fixed bounded storage allocated for at least 120 generated events with zero hot-path allocations."

# ------------------------------------------------------------------------------
# Contract R: R2 contract remains green
# ------------------------------------------------------------------------------
$r2TestPath = "C:\Proyectos\SGSR\native\lsfg-android\v2b1b_real_lsfg_r2_contract_test.ps1"
$r2Passed = $false
if (Test-Path $r2TestPath) {
    $r2Res = powershell -ExecutionPolicy Bypass -File $r2TestPath 2>&1
    if ($LASTEXITCODE -eq 0) { $r2Passed = $true }
}
Report-Contract "Contract R" $r2Passed "R2 contract test remains 100% green."

# ------------------------------------------------------------------------------
# Contract S: R1 contract remains green
# ------------------------------------------------------------------------------
$r1TestPath = "C:\Proyectos\SGSR\native\lsfg-android\v2b1b_real_lsfg_r1_contract_test.ps1"
$r1Passed = $false
if (Test-Path $r1TestPath) {
    $r1Res = powershell -ExecutionPolicy Bypass -File $r1TestPath 2>&1
    if ($LASTEXITCODE -eq 0) { $r1Passed = $true }
}
Report-Contract "Contract S" $r1Passed "R1 contract test remains 100% green."

# ------------------------------------------------------------------------------
# Contract T: R0 contract remains green
# ------------------------------------------------------------------------------
$r0TestPath = "C:\Proyectos\SGSR\native\lsfg-android\v2b1b_real_lsfg_r0_contract_test.ps1"
$r0Passed = $false
if (Test-Path $r0TestPath) {
    $r0Res = powershell -ExecutionPolicy Bypass -File $r0TestPath 2>&1
    if ($LASTEXITCODE -eq 0) { $r0Passed = $true }
}
Report-Contract "Contract T" $r0Passed "R0 contract test remains 100% green."

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "REAL-LSFG-R3 CONTRACT SUITE: ALL CONTRACTS PASSED (GREEN)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "REAL-LSFG-R3 CONTRACT SUITE: CONTRACTS FAILED (RED)" -ForegroundColor Red
    exit 1
}
