# ==============================================================================
# LSFG V2B.1B Phase B1A Compute-Solid-G Diagnostic Contract Test
# ==============================================================================
param(
    [string]$ProducerSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp',
    [string]$ShaderSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b1a_compute_proof.comp',
    [string]$SpirvHeader = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b1a_spirv.h'
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

function Test-ComputePathAndDispatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }
    $hasB1Path = ($presentFn -match 'isB1Active') -and ($presentFn -match 'g_b1ComputeDispatch')
    $hasDispatch = ($presentFn -match 'cmdDispatch\(cmdBuf,\s*groupCountX,\s*groupCountY,\s*1\)')
    return ($hasB1Path -and $hasDispatch)
}

function Test-ShaderSolidMagentaOutput {
    param([string]$CompSource, [string]$SpirvHeaderSource)
    if (-not (Test-Path $CompSource)) { return $false }
    $compText = Get-Content $CompSource -Raw
    $hasRgba8 = ($compText -match 'rgba8.*image2D.*outputImage')
    $hasLocalSize = ($compText -match 'local_size_x\s*=\s*8.*local_size_y\s*=\s*8')
    $hasBoundsCheck = ($compText -match 'coord\.x\s*>=\s*size\.x\s*\|\|\s*coord\.y\s*>=\s*size\.y')
    $hasSolidMagenta = ($compText -match 'imageStore\s*\(\s*outputImage\s*,\s*coord\s*,\s*vec4\s*\(\s*1\.0\s*,\s*0\.0\s*,\s*1\.0\s*,\s*1\.0\s*\)\s*\)')

    if (-not (Test-Path $SpirvHeaderSource)) { return $false }
    $spvText = Get-Content $SpirvHeaderSource -Raw
    $hasSpirvArray = ($spvText -match 'kB1AComputeProofSpirv') -and ($spvText -match 'kB1AComputeProofSpirvSize')

    return ($hasRgba8 -and $hasLocalSize -and $hasBoundsCheck -and $hasSolidMagenta -and $hasSpirvArray)
}

function Test-GResourceAndFormat {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    if ($null -eq $createFn) { return $false }
    $hasGFormat = ($createFn -match 'VK_FORMAT_R8G8B8A8_UNORM')
    $hasGUsage = ($createFn -match 'VK_IMAGE_USAGE_STORAGE_BIT\s*\|\s*VK_IMAGE_USAGE_TRANSFER_SRC_BIT')
    $hasSlotMembers = ($clean -match 'VkImage\s+generatedImage') -and
                      ($clean -match 'VkDeviceMemory\s+generatedImageMemory') -and
                      ($clean -match 'VkImageView\s+generatedImageView') -and
                      ($clean -match 'VkDescriptorSet\s+generatedDescriptorSet')
    return ($hasGFormat -and $hasGUsage -and $hasSlotMembers)
}

function Test-GToMCopyPreserved {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }
    $hasCopy = ($presentFn -match 'cmdCopyImage\(cmdBuf,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.swapchainImages\[M\],\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,\s*1,\s*&copyRegion\)')
    return $hasCopy
}

function Test-DualPresentAndOrderPreserved {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $mIdx = $presentFn.IndexOf('realFunc(queue, &presentM)')
    $nIdx = $presentFn.IndexOf('realFunc(queue, &presentN)')
    if ($mIdx -lt 0 -or $nIdx -lt 0 -or $mIdx -ge $nIdx) { return $false }

    $hasSemM = ($presentFn -match 'presentM\.pWaitSemaphores\s*=\s*&transport\.imagePresentation\[M\]\.generatedPresentReady')
    $hasSemN = ($presentFn -match 'presentN\.pWaitSemaphores\s*=\s*&transport\.imagePresentation\[N\]\.realPresentReady')
    return ($hasSemM -and $hasSemN)
}

function Test-NoHotPathBlockersAndBridgePreserved {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasNoMalloc = -not ($presentFn -match '\bmalloc\b|\bcalloc\b|\bnew\s+')
    $hasNoWaitIdle = -not ($presentFn -match '\bvkDeviceWaitIdle\b|\bvkQueueWaitIdle\b')
    $hasAcquireBridge = ($presentFn -match 'acquireReadySemaphore') -and ($presentFn -match 'extraAcquireSuccess')
    return ($hasNoMalloc -and $hasNoWaitIdle -and $hasAcquireBridge)
}

# --- Main Execution ---
if (-not (Test-Path $ProducerSource)) {
    Write-Error ("Producer source not found: " + $ProducerSource)
    exit 1
}

$source = Get-Content $ProducerSource -Raw
$allPassed = $true

Write-Host "[Contract 1/6] B1 Compute Path and Dispatch..." -NoNewline
if (Test-ComputePathAndDispatch $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 2/6] Shader Solid Magenta Output (vec4(1,0,1,1))..." -NoNewline
if (Test-ShaderSolidMagentaOutput $ShaderSource $SpirvHeader) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 3/6] G Resource, Format (R8G8B8A8_UNORM) and Storage/Transfer Usage..." -NoNewline
if (Test-GResourceAndFormat $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 4/6] G -> M vkCmdCopyImage Preserved..." -NoNewline
if (Test-GToMCopyPreserved $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 5/6] Dual Present and Order (Present M then Present N) Preserved..." -NoNewline
if (Test-DualPresentAndOrderPreserved $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 6/6] No Hot-Path Allocations/Waits and Production Acquire Bridge..." -NoNewline
if (Test-NoHotPathBlockersAndBridgePreserved $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

if ($allPassed) {
    Write-Host "`n=== ALL B1A COMPUTE-SOLID-G CONTRACTS PASSED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n=== SOME CONTRACTS FAILED ===" -ForegroundColor Red
    exit 1
}
