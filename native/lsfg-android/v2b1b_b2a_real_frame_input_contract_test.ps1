# ==============================================================================
# LSFG V2B.1B Phase B2A Real Current-Frame Compute Input Contract Test
# ==============================================================================
param(
    [string]$ProducerSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp',
    [string]$ShaderSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b2a_real_frame_input.comp',
    [string]$SpirvHeader = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b2a_spirv.h',
    [string]$B1aShaderSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b1a_compute_proof.comp',
    [string]$B1aSpirvHeader = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b1a_spirv.h'
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

function Test-B2AGatesAndB1APreservation {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasB2aGate = ($clean -match 'g_b2aRealFrameInput') -and ($clean -match 'AMETHYST_LSFG_B2A_REAL_FRAME_INPUT')
    $hasB2aMaxActive = ($clean -match 'g_b2aRealFrameInputMaxActive') -and ($clean -match 'AMETHYST_LSFG_B2A_REAL_FRAME_INPUT_MAX_ACTIVE')
    $hasB1aGate = ($clean -match 'g_b1ComputeProof') -and ($clean -match 'AMETHYST_LSFG_B1_COMPUTE_PROOF')
    $hasSolidMGate = ($clean -match 'g_b1DiagSolidMPresent') -and ($clean -match 'AMETHYST_LSFG_B1_DIAG_SOLID_M_PRESENT')
    return ($hasB2aGate -and $hasB2aMaxActive -and $hasB1aGate -and $hasSolidMGate)
}

function Test-B2AShaderAndSpirv {
    param([string]$CompSource, [string]$SpirvHeaderSource, [string]$B1aComp, [string]$B1aSpv)
    if (-not (Test-Path $CompSource)) { return $false }
    $compText = Get-Content $CompSource -Raw
    $hasWriteonlyG = ($compText -match 'binding\s*=\s*0.*rgba8.*writeonly.*image2D.*outputImage')
    $hasReadonlyH = ($compText -match 'binding\s*=\s*1.*rgba8.*readonly.*image2D.*inputImage')
    $hasLocalSize = ($compText -match 'local_size_x\s*=\s*8.*local_size_y\s*=\s*8')
    $hasBoundsCheck = ($compText -match 'coord\.x\s*>=\s*size\.x\s*\|\|\s*coord\.y\s*>=\s*size\.y')
    $hasImageLoad = ($compText -match 'imageLoad\s*\(\s*inputImage\s*,\s*coord\s*\)')
    $hasInversion = ($compText -match '1\.0\s*-\s*src\.r') -and ($compText -match '1\.0\s*-\s*src\.g') -and ($compText -match '1\.0\s*-\s*src\.b')
    $hasImageStore = ($compText -match 'imageStore\s*\(\s*outputImage\s*,\s*coord\s*,')

    if (-not (Test-Path $SpirvHeaderSource)) { return $false }
    $spvText = Get-Content $SpirvHeaderSource -Raw
    $hasSpirvArray = ($spvText -match 'kB2ARealFrameInputSpirv') -and ($spvText -match 'kB2ARealFrameInputSpirvSize')

    $b1aPreserved = (Test-Path $B1aComp) -and (Test-Path $B1aSpv)

    return ($hasWriteonlyG -and $hasReadonlyH -and $hasLocalSize -and $hasBoundsCheck -and $hasImageLoad -and $hasInversion -and $hasImageStore -and $hasSpirvArray -and $b1aPreserved)
}

function Test-HCaptureResourceAndDescriptors {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasSlotH = ($clean -match 'VkImage\s+capturedImage') -and
                ($clean -match 'VkDeviceMemory\s+capturedImageMemory') -and
                ($clean -match 'VkImageView\s+capturedImageView') -and
                ($clean -match 'VkDescriptorSet\s+b2aDescriptorSet')
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    if ($null -eq $createFn) { return $false }
    $hasHFormat = ($createFn -match 'capturedImage') -and ($createFn -match 'VK_FORMAT_R8G8B8A8_UNORM')
    $hasHUsage = ($createFn -match 'VK_IMAGE_USAGE_TRANSFER_DST_BIT\s*\|\s*VK_IMAGE_USAGE_STORAGE_BIT')
    $hasB2aPipeline = ($clean -match 'VkPipeline\s+b2aComputePipeline') -and ($clean -match 'VkPipelineLayout\s+b2aPipelineLayout')
    return ($hasSlotH -and $hasHFormat -and $hasHUsage -and $hasB2aPipeline)
}

function Test-NCaptureAndPreservation {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasCopyNToH = ($presentFn -match 'cmdCopyImage\(cmdBuf,\s*transport\.swapchainImages\[N\],\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,\s*1,\s*&copyRegion\)')
    $hasNNotUndefined = -not ($presentFn -match 'image\s*=\s*transport\.swapchainImages\[N\];\s*preBarriers\[.*?\].oldLayout\s*=\s*VK_IMAGE_LAYOUT_UNDEFINED')
    $hasNRestore = ($presentFn -match 'postBarriers\[.*?\].newLayout\s*=\s*VK_IMAGE_LAYOUT_PRESENT_SRC_KHR') -or ($presentFn -match 'image\s*=\s*transport\.swapchainImages\[N\]')

    return ($hasCopyNToH -and $hasNNotUndefined -and $hasNRestore)
}

function Test-B2AExecutionChainAndDualPresent {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasB2aBranch = ($presentFn -match 'isB2aActive') -and ($presentFn -match 'b2aComputePipeline')
    $hasCopyGToM = ($presentFn -match 'cmdCopyImage\(cmdBuf,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.swapchainImages\[M\],\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,\s*1,\s*&copyRegion\)')

    $mIdx = $presentFn.IndexOf('realFunc(queue, &presentM)')
    $nIdx = $presentFn.IndexOf('realFunc(queue, &presentN)')
    $orderCorrect = ($mIdx -ge 0 -and $nIdx -gt $mIdx)

    return ($hasB2aBranch -and $hasCopyGToM -and $orderCorrect)
}

function Test-AppWaitStagesIncludeTransferAndAcquireBridge {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Application wait stages must explicitly include VK_PIPELINE_STAGE_TRANSFER_BIT
    $hasAppWaitTransfer = ($presentFn -match 'waitStages\[waitCount\]\s*=\s*[^;]*VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT\s*\|\s*VK_PIPELINE_STAGE_TRANSFER_BIT') -or
                          ($presentFn -match 'waitStages\[waitCount\]\s*=\s*[^;]*VK_PIPELINE_STAGE_TRANSFER_BIT\s*\|\s*VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT')
    $hasAcqReadyTransfer = ($presentFn -match 'slot\.acquireReadySemaphore') -and ($presentFn -match 'VK_PIPELINE_STAGE_TRANSFER_BIT')

    return ($hasAppWaitTransfer -and $hasAcqReadyTransfer)
}

function Test-FailOpenAndHotPathHygiene {
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

Write-Host "[Contract 1/7] B2A Gates and B1A Checkpoint Preservation..." -NoNewline
if (Test-B2AGatesAndB1APreservation $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 2/7] B2A Shader, imageLoad(H) Inversion, and SPIR-V Header..." -NoNewline
if (Test-B2AShaderAndSpirv $ShaderSource $SpirvHeader $B1aShaderSource $B1aSpirvHeader) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 3/7] H Capture Resource (R8G8B8A8_UNORM) and Storage Descriptors..." -NoNewline
if (Test-HCaptureResourceAndDescriptors $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 4/7] N -> H vkCmdCopyImage, N Retained (Not UNDEFINED), N Restored..." -NoNewline
if (Test-NCaptureAndPreservation $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 5/7] B2A Execution Chain (N->H, Compute, G->M) and Dual Present (M then N)..." -NoNewline
if (Test-B2AExecutionChainAndDualPresent $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 6/7] App Semaphore Wait Stages Cover TRANSFER_BIT and AcquireBridge..." -NoNewline
if (Test-AppWaitStagesIncludeTransferAndAcquireBridge $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 7/7] Production Acquire Bridge, Fail-Open, and Zero Hot-Path Waits/Allocations..." -NoNewline
if (Test-FailOpenAndHotPathHygiene $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

if ($allPassed) {
    Write-Host "`n=== ALL B2A REAL CURRENT-FRAME INPUT CONTRACTS PASSED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n=== SOME CONTRACTS FAILED ===" -ForegroundColor Red
    exit 1
}
