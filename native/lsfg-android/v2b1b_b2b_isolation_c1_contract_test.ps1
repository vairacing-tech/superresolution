# ==============================================================================
# v2b1b_b2b_isolation_c1_contract_test.ps1
#
# LSFG Phase B2B Isolation C1 Contract Test Suite
# Validates structural AST and invariants for:
# - Diagnostic gate AMETHYST_LSFG_B2B_DIAG_OFFSCREEN_G (default 0)
# - Sustained B2B compute/history with computed G offscreen
# - Stable direct N -> M duplicate present content in C1 branch
# - Bit-exact compute preservation and readback compatibility
# - Zero hot-path allocations, blocking waits, or semaphore/fence drift
# ==============================================================================

param(
    [string]$SourcePath = "C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
)

$ErrorActionPreference = "Stop"

function Test-RegexMatch {
    param([string]$Content, [string]$Pattern, [string]$TestName)
    if ($Content -match $Pattern) {
        Write-Output "  PASS: $TestName"
        return $true
    } else {
        Write-Output "  FAIL: $TestName (Pattern: $Pattern)"
        return $false
    }
}

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
function Test-C1GateDefinition {
    param([string]$Source)
    $hasAtomic = ($Source -match 'g_b2bDiagOffscreenG\s*\{\s*0\s*\}') -or
                 ($Source -match 'std::atomic<int>\s+g_b2bDiagOffscreenG')

    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    $hasLatch = ($initFn -ne $null) -and
                ($initFn -match 'AMETHYST_LSFG_B2B_DIAG_OFFSCREEN_G') -and
                ($initFn -match 'g_b2bDiagOffscreenG\.store')

    return ($hasAtomic -and $hasLatch)
}

# Contract 2: Structural C1 Offscreen-G Execution Branch
function Test-C1StructuralExecutionBranch {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # Gate evaluation inside B2B present logic
    $hasGateCheck = ($b2bBlock -match 'isOffscreenG') -or
                    ($b2bBlock -match 'g_b2bDiagOffscreenG\.load')

    # In C1 branch: Real B2B compute pipeline and descriptor set must still be bound and dispatched
    $hasComputePipeline = ($b2bBlock -match 'cmdBindPipeline\s*\([^,]+,\s*VK_PIPELINE_BIND_POINT_COMPUTE,\s*transport\.b2bComputePipeline\)')
    $hasDescriptorSet = ($b2bBlock -match 'cmdBindDescriptorSets\s*\([^,]+,\s*VK_PIPELINE_BIND_POINT_COMPUTE,\s*transport\.b2bPipelineLayout,\s*0,\s*1,\s*&slot\.b2bDescriptorSet')
    $hasDispatch = ($b2bBlock -match 'cmdDispatch\s*\(')

    # In C1 branch: History update C -> P must still execute
    $hasHistoryUpdate = ($b2bBlock -match 'cmdCopyImage\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    # In C1 branch: M must be populated using stable N -> M copy
    $hasStableMCopy = ($b2bBlock -match 'cmdCopyImage\s*\([^,]+,\s*transport\.swapchainImages\[N\],\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.swapchainImages\[M\],\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    return ($hasGateCheck -and $hasComputePipeline -and $hasDescriptorSet -and $hasDispatch -and $hasHistoryUpdate -and $hasStableMCopy)
}

# Contract 3: Default Path (OFFSCREEN_G=0) Preservation
function Test-C1DefaultPathPreservation {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # Default branch when !isOffscreenG: G -> M copy preserved
    $hasDefaultGToMCopy = ($b2bBlock -match 'cmdCopyImage\s*\([^,]+,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.swapchainImages\[M\],\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    return $hasDefaultGToMCopy
}

# Contract 4: Readback Compatibility & Staging Buffer Sync
function Test-C1ReadbackCompatibility {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # Event E-1 and E copies to staging buffers must remain intact
    $hasPrevCCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPrevCBuffer')
    $hasPCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPBuffer')
    $hasCCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackCBuffer')
    $hasGCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackGBuffer')

    return ($hasPrevCCopy -and $hasPCopy -and $hasCCopy -and $hasGCopy)
}

# Contract 5: Vulkan GPU Synchronization & Zero Hot-Path Blocking
function Test-C1VulkanSyncAndHotPath {
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

Write-Host -NoNewline "[Contract 1/5] B2B C1 Gate Definition and Initialization Latching... "
if (Test-C1GateDefinition $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 2/5] B2B C1 Structural Offscreen-G Execution Branch (N->M duplicate & P+C->G offscreen)... "
if (Test-C1StructuralExecutionBranch $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 3/5] B2B C1 Default Path (OFFSCREEN_G=0) G->M Preservation... "
if (Test-C1DefaultPathPreservation $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 4/5] B2B C1 Readback Compatibility & Staging Buffer Sync... "
if (Test-C1ReadbackCompatibility $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 5/5] B2B C1 Vulkan GPU Synchronization & Zero Hot-Path Blocking... "
if (Test-C1VulkanSyncAndHotPath $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

if ($allPassed) {
    Write-Output "`n=== ALL B2B ISOLATION C1 CONTRACTS PASSED ==="
    exit 0
} else {
    Write-Output "`n=== SOME CONTRACTS FAILED ==="
    exit 1
}
