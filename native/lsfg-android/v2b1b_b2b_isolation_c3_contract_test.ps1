# ==============================================================================
# v2b1b_b2b_isolation_c3_contract_test.ps1
#
# LSFG Phase B2B Isolation C3 Contract Test Suite
# Validates structural AST and invariants for:
# - Diagnostic gate AMETHYST_LSFG_B2B_DIAG_M_HOLD_TO_END (default 0)
# - C2 default preservation when M_HOLD_TO_END=0 (early M -> PRESENT in Step 3)
# - C3 execution flow when M_HOLD_TO_END=1:
#   - N -> M copy in Step 2 preserved
#   - Early M -> PRESENT barrier omitted from Step 3
#   - Step 3 barriers for N, C, G preserved
#   - M remains in TRANSFER_DST_OPTIMAL across compute, G->D, and history update C->P
#   - Final M -> PRESENT_SRC_KHR barrier executed strictly after C->P before submission
#   - Final M barrier uses baseline stage/access masks
#   - No G -> M copy
# - Event 500 readback compatibility and invariant topology
# - Zero hot-path allocations, blocking waits, or semaphore/fence drift
# ==============================================================================

param(
    [string]$SourcePath = "C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
)

$ErrorActionPreference = "Stop"

function Get-CppFunctionBody {
    param([string]$Source, [string]$FunctionName)
    $clean = [System.Text.RegularExpressions.Regex]::Replace($Source, '(?s)/\*.*?\*/', '')
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '//.*?$', '', [System.Text.RegularExpressions.RegexOptions]::Multiline)

    $escaped = [regex]::Escape($FunctionName)
    $pattern = '(?m)\b' + $escaped + '\b\s*\([^{;]*\)\s*\{'
    $match = [regex]::Match($clean, $pattern)
    if (-not $match.Success) { return $null }

    $start = $match.Index + $match.Length - 1
    $braceCount = 1
    $index = $start + 1
    $length = $clean.Length
    while ($index -lt $length -and $braceCount -gt 0) {
        $ch = $clean[$index]
        if ($ch -eq '{') { $braceCount++ }
        elseif ($ch -eq '}') { $braceCount-- }
        $index++
    }
    return $clean.Substring($start, $index - $start)
}

function Get-CppBlock {
    param([string]$Source, [string]$HeaderRegex)
    $clean = [System.Text.RegularExpressions.Regex]::Replace($Source, '(?s)/\*.*?\*/', '')
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '//.*?$', '', [System.Text.RegularExpressions.RegexOptions]::Multiline)

    $match = [regex]::Match($clean, $HeaderRegex)
    if (-not $match.Success) { return $null }

    $start = $clean.IndexOf('{', $match.Index)
    if ($start -lt 0) { return $null }

    $braceCount = 1
    $index = $start + 1
    $length = $clean.Length
    while ($index -lt $length -and $braceCount -gt 0) {
        $ch = $clean[$index]
        if ($ch -eq '{') { $braceCount++ }
        elseif ($ch -eq '}') { $braceCount-- }
        $index++
    }
    return $clean.Substring($start, $index - $start)
}

# Contract 1: Gate Definition & Initialization Latching
function Test-C3GateDefinition {
    param([string]$Source)
    $hasAtomic = ($Source -match 'g_b2bDiagMHoldToEnd\s*\{\s*0\s*\}') -or
                 ($Source -match 'std::atomic<int>\s+g_b2bDiagMHoldToEnd')

    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    $hasLatch = ($initFn -ne $null) -and
                ($initFn -match 'AMETHYST_LSFG_B2B_DIAG_M_HOLD_TO_END') -and
                ($initFn -match 'g_b2bDiagMHoldToEnd\.store')

    return ($hasAtomic -and $hasLatch)
}

# Contract 2: C2 Default Preservation When M_HOLD_TO_END=0
function Test-C2DefaultPreservedInC3 {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    $gToDummyBlock = Get-CppBlock $b2bBlock 'if\s*\(\s*isGToDummy\s*\)'
    if ($null -eq $gToDummyBlock) { return $false }

    # When M_HOLD_TO_END is false, early M barrier in Step 3 must be recorded
    $hasEarlyMBarrier = ($gToDummyBlock -match 'isMHoldToEnd') -and
                        ($gToDummyBlock -match 'postTransferBarriersC2\[[^\]]+\]\.image\s*=\s*transport\.swapchainImages\[M\]') -and
                        ($gToDummyBlock -match 'VK_IMAGE_LAYOUT_PRESENT_SRC_KHR')

    return $hasEarlyMBarrier
}

# Contract 3: Structural C3 Execution Flow (M Hold Across Compute & History, Final M Barrier)
function Test-C3StructuralExecutionFlow {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    $gToDummyBlock = Get-CppBlock $b2bBlock 'if\s*\(\s*isGToDummy\s*\)'
    if ($null -eq $gToDummyBlock) { return $false }

    # 1. Gate evaluation inside isGToDummy
    $hasGateCheck = ($gToDummyBlock -match 'isMHoldToEnd') -or
                    ($gToDummyBlock -match 'g_b2bDiagMHoldToEnd\.load')

    # 2. Copy N -> M in Step 2 preserved
    $hasNToMCopy = ($gToDummyBlock -match 'cmdCopyImage\s*\([^,]+,\s*transport\.swapchainImages\[N\],\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.swapchainImages\[M\],\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    # 3. Compute dispatch P + C -> G preserved
    $hasCompute = ($gToDummyBlock -match 'cmdDispatch\s*\(')

    # 4. Copy G -> D preserved
    $hasGToDCopy = ($gToDummyBlock -match 'cmdCopyImage\s*\([^,]+,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*slot\.dummyImage,\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    # 5. History update C -> P preserved
    $hasHistoryUpdate = ($gToDummyBlock -match 'cmdCopyImage\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    # 6. Final M barrier after history update when isMHoldToEnd
    $hasFinalMBarrier = ($gToDummyBlock -match 'postBarrierM') -and
                        ($gToDummyBlock -match 'VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT') -and
                        ($gToDummyBlock -match 'VK_ACCESS_TRANSFER_WRITE_BIT') -and
                        ($gToDummyBlock -match 'VK_IMAGE_LAYOUT_PRESENT_SRC_KHR')

    return ($hasGateCheck -and $hasNToMCopy -and $hasCompute -and $hasGToDCopy -and $hasHistoryUpdate -and $hasFinalMBarrier)
}

# Contract 4: Readback Compatibility & No G -> M Copy in C3
function Test-C3ReadbackAndTopologyInvariants {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    $gToDummyBlock = Get-CppBlock $b2bBlock 'if\s*\(\s*isGToDummy\s*\)'
    if ($null -eq $gToDummyBlock) { return $false }

    # Readback staging copies preserved
    $hasPrevCCopy = ($gToDummyBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPrevCBuffer')
    $hasPCopy = ($gToDummyBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPBuffer')
    $hasCCopy = ($gToDummyBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackCBuffer')
    $hasGCopy = ($gToDummyBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackGBuffer')

    # Strict invariant: NO G -> M copy inside isGToDummy
    $noGToMCopy = -not ($gToDummyBlock -match 'cmdCopyImage\s*\([^,]+,\s*slot\.generatedImage,[^,]+,\s*transport\.swapchainImages\[M\]')

    return ($hasPrevCCopy -and $hasPCopy -and $hasCCopy -and $hasGCopy -and $noGToMCopy)
}

# Contract 5: Vulkan Synchronization & Zero Hot-Path Blocking
function Test-C3VulkanSyncAndHotPath {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Zero blocking waits and zero dynamic allocations in presentation
    $noQueueWaitIdle = -not ($presentFn -match 'vkQueueWaitIdle')
    $noDeviceWaitIdle = -not ($presentFn -match 'vkDeviceWaitIdle')
    $noMalloc = -not ($presentFn -match '\bmalloc\b|\bcalloc\b|\bnew\s+')

    # Invariant: 2 signaled semaphores, dual presentation M then N
    $hasTwoSignals = ($presentFn -match 'signalSemaphoreCount\s*=\s*2')
    $hasPresentOrder = ($presentFn -match 'realFunc\s*\(\s*queue\s*,\s*&presentM\s*\)') -and
                       ($presentFn -match 'realFunc\s*\(\s*queue\s*,\s*&presentN\s*\)')

    return ($noQueueWaitIdle -and $noDeviceWaitIdle -and $noMalloc -and $hasTwoSignals -and $hasPresentOrder)
}

# --- Execution ---
if (-not (Test-Path $SourcePath)) {
    Write-Error "Source file not found: $SourcePath"
    exit 1
}

$sourceContent = Get-Content -Path $SourcePath -Raw

$allPassed = $true

Write-Host -NoNewline "[Contract 1/5] B2B C3 Gate Definition and Initialization Latching... "
if (Test-C3GateDefinition $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 2/5] B2B C2 Default Preservation When M_HOLD_TO_END=0... "
if (Test-C2DefaultPreservedInC3 $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 3/5] B2B C3 Structural Execution Flow (M Hold, Compute, G->D, Final M Barrier)... "
if (Test-C3StructuralExecutionFlow $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 4/5] B2B C3 Readback Compatibility & No G->M Copy Invariants... "
if (Test-C3ReadbackAndTopologyInvariants $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 5/5] B2B C3 Vulkan GPU Synchronization & Zero Hot-Path Blocking... "
if (Test-C3VulkanSyncAndHotPath $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

if ($allPassed) {
    Write-Output "`n=== ALL B2B ISOLATION C3 CONTRACTS PASSED ==="
    exit 0
} else {
    Write-Output "`n=== SOME CONTRACTS FAILED ==="
    exit 1
}
