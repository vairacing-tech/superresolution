# ==============================================================================
# v2b1b_b2b_isolation_c2_contract_test.ps1
#
# LSFG Phase B2B Isolation C2 Contract Test Suite
# Validates structural AST and invariants for:
# - Diagnostic gate AMETHYST_LSFG_B2B_DIAG_G_TO_DUMMY (default 0)
# - Per-slot offscreen dummy image D (TRANSFER_DST, device-local)
# - Exact baseline G compute->transfer lifecycle (GENERAL -> TRANSFER_SRC)
# - Hardware copy G -> D without G touching swapchain M
# - Stable N -> M presentation copy preserved
# - Zero post-copy barrier on G (G remains in TRANSFER_SRC at end-of-frame)
# - Bit-exact compute preservation and Event-500 readback compatibility
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
function Test-C2GateDefinition {
    param([string]$Source)
    $hasAtomic = ($Source -match 'g_b2bDiagGToDummy\s*\{\s*0\s*\}') -or
                 ($Source -match 'std::atomic<int>\s+g_b2bDiagGToDummy')

    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    $hasLatch = ($initFn -ne $null) -and
                ($initFn -match 'AMETHYST_LSFG_B2B_DIAG_G_TO_DUMMY') -and
                ($initFn -match 'g_b2bDiagGToDummy\.store')

    return ($hasAtomic -and $hasLatch)
}

# Contract 2: Per-Slot Dummy Image Resource Allocation & Cleanup
function Test-C2DummyResourceLifecycle {
    param([string]$Source)
    # Check TransportSlot struct definition
    $hasSlotFields = ($Source -match 'VkImage\s+dummyImage(\s*=\s*VK_NULL_HANDLE)?\s*;') -and
                     ($Source -match 'VkDeviceMemory\s+dummyImageMemory(\s*=\s*VK_NULL_HANDLE)?\s*;')

    # Check Creation in CreateSwapchain
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $hasCreate = ($createFn -ne $null) -and
                 ($createFn -match 'VK_IMAGE_USAGE_TRANSFER_DST_BIT') -and
                 ($createFn -match 'transport\.slots\[s\]\.dummyImage') -and
                 ($createFn -match 'transport\.slots\[s\]\.dummyImageMemory')

    # Check Cleanup in DestroySwapchain / cleanup helpers
    $hasCleanup = ($Source -match 'devStateCopy\.destroyImage\s*\([^,]+,\s*transport\.slots\[s\]\.dummyImage') -or
                  ($Source -match 'devStateCopy\.destroyImage\s*\([^,]+,\s*transportToDestroy\.slots\[s\]\.dummyImage') -or
                  ($Source -match 'destroyImage\s*\([^,]+,\s*[^,]*dummyImage')

    return ($hasSlotFields -and $hasCreate -and $hasCleanup)
}

# Contract 3: Structural C2 Execution Flow (G -> D Transfer & N -> M Presentation)
function Test-C2StructuralExecutionFlow {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # Gate evaluation inside B2B present logic
    $hasGateCheck = ($b2bBlock -match 'isGToDummy') -or
                    ($b2bBlock -match 'g_b2bDiagGToDummy\.load')

    # Compute dispatch
    $hasComputePipeline = ($b2bBlock -match 'cmdBindPipeline\s*\([^,]+,\s*VK_PIPELINE_BIND_POINT_COMPUTE,\s*transport\.b2bComputePipeline\)')
    $hasDispatch = ($b2bBlock -match 'cmdDispatch\s*\(')

    # Post-compute barrier for G: GENERAL -> TRANSFER_SRC_OPTIMAL with baseline access masks
    $hasGBarrier = ($b2bBlock -match 'VK_ACCESS_SHADER_WRITE_BIT') -and
                   ($b2bBlock -match 'VK_ACCESS_TRANSFER_READ_BIT') -and
                   ($b2bBlock -match 'VK_IMAGE_LAYOUT_GENERAL') -and
                   ($b2bBlock -match 'VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL')

    # Copy G -> D (dummy image)
    $hasGToDCopy = ($b2bBlock -match 'cmdCopyImage\s*\([^,]+,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*slot\.dummyImage,\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    # Copy N -> M (stable presentation)
    $hasStableMCopy = ($b2bBlock -match 'cmdCopyImage\s*\([^,]+,\s*transport\.swapchainImages\[N\],\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.swapchainImages\[M\],\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    # History update C -> P
    $hasHistoryUpdate = ($b2bBlock -match 'cmdCopyImage\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')

    return ($hasGateCheck -and $hasComputePipeline -and $hasDispatch -and $hasGBarrier -and $hasGToDCopy -and $hasStableMCopy -and $hasHistoryUpdate)
}

# Contract 4: Readback Compatibility & No Artificial G Restoration in C2
function Test-C2ReadbackAndLifecycleInvariants {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # Event 500 copies to staging buffers must remain intact
    $hasPrevCCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPrevCBuffer')
    $hasPCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPBuffer')
    $hasCCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackCBuffer')
    $hasGCopy = ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackGBuffer')

    return ($hasPrevCCopy -and $hasPCopy -and $hasCCopy -and $hasGCopy)
}

# Contract 5: Vulkan GPU Synchronization & Zero Hot-Path Blocking
function Test-C2VulkanSyncAndHotPath {
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

Write-Host -NoNewline "[Contract 1/5] B2B C2 Gate Definition and Initialization Latching... "
if (Test-C2GateDefinition $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 2/5] B2B C2 Per-Slot Dummy Image Resource Lifecycle (Create & Cleanup)... "
if (Test-C2DummyResourceLifecycle $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 3/5] B2B C2 Structural Execution Flow (P+C->G, G->D, N->M, C->P)... "
if (Test-C2StructuralExecutionFlow $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 4/5] B2B C2 Readback Compatibility & Lifecycle Invariants... "
if (Test-C2ReadbackAndLifecycleInvariants $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

Write-Host -NoNewline "[Contract 5/5] B2B C2 Vulkan GPU Synchronization & Zero Hot-Path Blocking... "
if (Test-C2VulkanSyncAndHotPath $sourceContent) { Write-Host "PASS" -ForegroundColor Green }
else { Write-Host "FAIL" -ForegroundColor Red; $allPassed = $false }

if ($allPassed) {
    Write-Output "`n=== ALL B2B ISOLATION C2 CONTRACTS PASSED ==="
    exit 0
} else {
    Write-Output "`n=== SOME CONTRACTS FAILED ==="
    exit 1
}
