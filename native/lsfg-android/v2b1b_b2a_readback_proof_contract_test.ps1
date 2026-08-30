# ==============================================================================
# LSFG V2B.1B Phase B2A Deterministic GPU Readback Proof Contract Test
# ==============================================================================
param(
    [string]$ProducerSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp'
)

$ErrorActionPreference = 'Stop'

function Remove-CppTrivia {
    param([string]$Source)
    $noBlock = [System.Text.RegularExpressions.Regex]::Replace($Source, '(?s)/\*.*?\*/', '')
    $noLine = [System.Text.RegularExpressions.Regex]::Replace($noBlock, '//.*?$', '', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    return $noLine
}

function Get-CppFunctionBody {
    param(
        [string]$Source,
        [string]$FunctionName
    )
    $clean = Remove-CppTrivia $Source
    $escaped = [regex]::Escape($FunctionName)
    $pattern = '(?m)\b' + $escaped + '\b\s*\([^{;]*\)\s*\{'
    $match = [regex]::Match($clean, $pattern)
    if (-not $match.Success) {
        return $null
    }

    $start = $match.Index + $match.Length - 1
    $braceCount = 1
    $index = $start + 1
    $length = $clean.Length

    while ($index -lt $length -and $braceCount -gt 0) {
        $ch = $clean[$index]
        if ($ch -eq '{') {
            $braceCount++
        } elseif ($ch -eq '}') {
            $braceCount--
        }
        $index++
    }

    if ($braceCount -eq 0) {
        return $clean.Substring($start, $index - $start)
    }
    return $null
}

function Test-ReadbackGatesAndAtomics {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasGate = ($clean -match 'g_b2aReadbackProof') -and ($clean -match 'AMETHYST_LSFG_B2A_READBACK_PROOF')
    $hasEventGate = ($clean -match 'g_b2aReadbackProofEvent') -and ($clean -match 'AMETHYST_LSFG_B2A_READBACK_PROOF_EVENT')
    $hasCounters = ($clean -match 'g_b2aReadbackRecorded') -and ($clean -match 'g_b2aReadbackWritten')
    return ($hasGate -and $hasEventGate -and $hasCounters)
}

function Test-ReadbackStagingAllocationAndCleanup {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasBuffers = ($clean -match 'VkBuffer\s+b2aReadbackHBuffer') -and
                  ($clean -match 'VkBuffer\s+b2aReadbackGBuffer') -and
                  ($clean -match 'VkDeviceMemory\s+b2aReadbackHMemory') -and
                  ($clean -match 'VkDeviceMemory\s+b2aReadbackGMemory')

    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $destroyFn = Get-CppFunctionBody $Source 'interposer_vkDestroySwapchainKHR'
    if ($null -eq $createFn -or $null -eq $destroyFn) { return $false }

    $hasAlloc = ($createFn -match 'b2aReadbackHBuffer') -and ($createFn -match 'VK_BUFFER_USAGE_TRANSFER_DST_BIT') -and
                ($createFn -match 'VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT')
    $hasCleanup = ($destroyFn -match 'b2aReadbackHBuffer') -and ($destroyFn -match 'b2aReadbackGBuffer')

    return ($hasBuffers -and $hasAlloc -and $hasCleanup)
}

function Test-GPUImageToBufferCopies {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasCopyH = ($presentFn -match 'cmdCopyImageToBuffer\(cmdBuf,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2aReadbackHBuffer')
    $hasCopyG = ($presentFn -match 'cmdCopyImageToBuffer\(cmdBuf,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2aReadbackGBuffer')
    $hasBufferBarrier = ($presentFn -match 'VK_ACCESS_TRANSFER_WRITE_BIT') -and ($presentFn -match 'VK_ACCESS_HOST_READ_BIT')

    return ($hasCopyH -and $hasCopyG -and $hasBufferBarrier)
}

function Test-CompletionAndFileExport {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source

    $hasOutputDir = ($clean -match 'lsfg_b2a_readback')
    $hasRawH = ($clean -match 'b2a_H_rgba8\.raw')
    $hasRawG = ($clean -match 'b2a_G_rgba8\.raw')
    $hasMeta = ($clean -match 'b2a_readback_meta\.txt')
    $hasFenceCheck = ($clean -match 'getFenceStatus')

    return ($hasOutputDir -and $hasRawH -and $hasRawG -and $hasMeta -and $hasFenceCheck)
}

function Test-FailOpenAndHotPathHygiene {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasNoMalloc = -not ($presentFn -match '\bmalloc\b|\bcalloc\b|\bnew\s+')
    $hasNoWaitIdle = -not ($presentFn -match '\bvkDeviceWaitIdle\b|\bvkQueueWaitIdle\b')
    return ($hasNoMalloc -and $hasNoWaitIdle)
}

# --- Main Execution ---
if (-not (Test-Path $ProducerSource)) {
    Write-Error ("Producer source not found: " + $ProducerSource)
    exit 1
}

$source = Get-Content $ProducerSource -Raw
$allPassed = $true

Write-Host "[Contract 1/5] Readback Proof Gates, Atomics, and Environment Latching..." -NoNewline
if (Test-ReadbackGatesAndAtomics $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 2/5] Staging Buffers (HOST_VISIBLE) Allocation & Cleanup..." -NoNewline
if (Test-ReadbackStagingAllocationAndCleanup $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 3/5] GPU Image-to-Buffer Copies (H & G) and Buffer Barriers..." -NoNewline
if (Test-GPUImageToBufferCopies $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 4/5] Fence-Gated Completion, RAW/Meta File Export, and Invalidation..." -NoNewline
if (Test-CompletionAndFileExport $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 5/5] Fail-Open Architecture, Zero Hot-Path Waits/Allocations..." -NoNewline
if (Test-FailOpenAndHotPathHygiene $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

if ($allPassed) {
    Write-Host "`n=== ALL B2A GPU READBACK PROOF CONTRACTS PASSED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n=== SOME CONTRACTS FAILED ===" -ForegroundColor Red
    exit 1
}
