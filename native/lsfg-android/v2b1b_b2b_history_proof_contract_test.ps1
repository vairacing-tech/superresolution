# ==============================================================================
# LSFG V2B.1B Phase B2B Two-Frame History Ingestion Proof Contract Test
# ==============================================================================
param(
    [string]$ProducerSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp',
    [string]$ShaderSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b2b_history_proof.comp',
    [string]$SpirvHeader = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b2b_spirv.h',
    [string]$B2aShaderSource = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b2a_real_frame_input.comp',
    [string]$B2aSpirvHeader = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\b2a_spirv.h'
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

function Test-B2BGatesAndAtomics {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasB2bGate = ($clean -match 'g_b2bHistoryProof') -and ($clean -match 'AMETHYST_LSFG_B2B_HISTORY_PROOF')
    $hasB2bMaxActive = ($clean -match 'g_b2bHistoryProofMaxActive') -and ($clean -match 'AMETHYST_LSFG_B2B_HISTORY_PROOF_MAX_ACTIVE')
    $hasB2bReadbackGate = ($clean -match 'g_b2bReadbackProof') -and ($clean -match 'AMETHYST_LSFG_B2B_READBACK_PROOF')
    $hasB2bReadbackEvent = ($clean -match 'g_b2bReadbackProofEvent') -and ($clean -match 'AMETHYST_LSFG_B2B_READBACK_PROOF_EVENT')
    $hasCounters = ($clean -match 'g_b2bEligible') -and ($clean -match 'g_b2bSeed') -and ($clean -match 'g_b2bDispatch') -and ($clean -match 'g_b2bHistoryUpdate')
    return ($hasB2bGate -and $hasB2bMaxActive -and $hasB2bReadbackGate -and $hasB2bReadbackEvent -and $hasCounters)
}

function Test-B2BShaderAndSpirv {
    param([string]$CompSource, [string]$SpirvHeaderSource, [string]$B2aComp, [string]$B2aSpv)
    if (-not (Test-Path $CompSource)) { return $false }
    $compText = Get-Content $CompSource -Raw
    $hasWriteonlyG = ($compText -match 'binding\s*=\s*0.*rgba8.*writeonly.*image2D.*outputImage')
    $hasReadonlyPrev = ($compText -match 'binding\s*=\s*1.*rgba8.*readonly.*image2D.*previousImage')
    $hasReadonlyCurr = ($compText -match 'binding\s*=\s*2.*rgba8.*readonly.*image2D.*currentImage')
    $hasLocalSize = ($compText -match 'local_size_x\s*=\s*8.*local_size_y\s*=\s*8')
    $hasBoundsCheck = ($compText -match 'coord\.x\s*>=\s*size\.x\s*\|\|\s*coord\.y\s*>=\s*size\.y')
    $hasTileCheck = ($compText -match 'tile\s*=\s*coord\s*/\s*32')
    $hasCheckerSelect = ($compText -match 'usePrevious\s*=\s*\(\s*\(\s*tile\.x\s*\+\s*tile\.y\s*\)\s*&\s*1\s*\)\s*==\s*0')
    $hasDualLoad = ($compText -match 'imageLoad\s*\(\s*previousImage\s*,\s*coord\s*\)') -and ($compText -match 'imageLoad\s*\(\s*currentImage\s*,\s*coord\s*\)')
    $hasImageStore = ($compText -match 'imageStore\s*\(\s*outputImage\s*,\s*coord\s*,\s*usePrevious\s*\?\s*previousPixel\s*:\s*currentPixel\s*\)')

    if (-not (Test-Path $SpirvHeaderSource)) { return $false }
    $spvText = Get-Content $SpirvHeaderSource -Raw
    $hasSpirvArray = ($spvText -match 'kB2BHistoryProofSpirv') -and ($spvText -match 'kB2BHistoryProofSpirvSize')

    $b2aPreserved = (Test-Path $B2aComp) -and (Test-Path $B2aSpv)

    return ($hasWriteonlyG -and $hasReadonlyPrev -and $hasReadonlyCurr -and $hasLocalSize -and $hasBoundsCheck -and $hasTileCheck -and $hasCheckerSelect -and $hasDualLoad -and $hasImageStore -and $hasSpirvArray -and $b2aPreserved)
}

function Test-DedicatedHistoryResourceAndDescriptors {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasHistoryImg = ($clean -match 'VkImage\s+b2bHistoryImage') -and
                     ($clean -match 'VkDeviceMemory\s+b2bHistoryImageMemory') -and
                     ($clean -match 'VkImageView\s+b2bHistoryImageView') -and
                     ($clean -match 'bool\s+b2bHistoryValid')
    $hasSlotB2bDesc = ($clean -match 'VkDescriptorSet\s+b2bDescriptorSet')
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    if ($null -eq $createFn) { return $false }
    $hasHistoryFormat = ($createFn -match 'b2bHistoryImage') -and ($createFn -match 'VK_FORMAT_R8G8B8A8_UNORM')
    $hasHistoryUsage = ($createFn -match 'b2bHistoryImage') -and ($createFn -match 'VK_IMAGE_USAGE_STORAGE_BIT') -and ($createFn -match 'VK_IMAGE_USAGE_TRANSFER_DST_BIT')
    $hasB2bPipeline = ($clean -match 'VkPipeline\s+b2bComputePipeline') -and ($clean -match 'VkPipelineLayout\s+b2bPipelineLayout')
    return ($hasHistoryImg -and $hasSlotB2bDesc -and $hasHistoryFormat -and $hasHistoryUsage -and $hasB2bPipeline)
}

function Test-FirstEventSeedAndHistorySequencing {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasSeedCheck = ($presentFn -match 'b2bHistoryValid') -and ($presentFn -match 'g_b2bSeed')
    $hasHistoryUpdate = ($presentFn -match 'cmdCopyImage\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')
    $hasHistoryUpdateCounter = ($presentFn -match 'g_b2bHistoryUpdate')

    # Ensure compute dispatch occurs BEFORE history update copy
    $dispatchIdx = $presentFn.IndexOf('cmdDispatch(cmdBuf')
    $histCopyIdx = $presentFn.IndexOf('transport.b2bHistoryImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')
    $orderCorrect = ($dispatchIdx -ge 0 -and $histCopyIdx -gt $dispatchIdx)

    return ($hasSeedCheck -and $hasHistoryUpdate -and $hasHistoryUpdateCounter -and $orderCorrect)
}

function Test-B2BReadbackProofAndFourFileExport {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasReadbackBuffers = ($clean -match 'b2bReadbackPrevCBuffer') -and
                          ($clean -match 'b2bReadbackPBuffer') -and
                          ($clean -match 'b2bReadbackCBuffer') -and
                          ($clean -match 'b2bReadbackGBuffer')

    $hasExportFiles = ($clean -match 'b2b_event499_current_rgba8\.raw') -and
                      ($clean -match 'b2b_event500_previous_rgba8\.raw') -and
                      ($clean -match 'b2b_event500_current_rgba8\.raw') -and
                      ($clean -match 'b2b_event500_G_rgba8\.raw') -and
                      ($clean -match 'b2b_readback_meta\.txt')

    return ($hasReadbackBuffers -and $hasExportFiles)
}

function Test-SynchronizationAndNoHotPathBlocking {
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

Write-Host "[Contract 1/6] B2B Diagnostic Gates and Counters..." -NoNewline
if (Test-B2BGatesAndAtomics $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 2/6] B2B 32x32 Checkerboard Shader & SPIR-V Header..." -NoNewline
if (Test-B2BShaderAndSpirv $ShaderSource $SpirvHeader $B2aShaderSource $B2aSpirvHeader) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 3/6] Dedicated Swapchain-Scoped History Image (P) Resource..." -NoNewline
if (Test-DedicatedHistoryResourceAndDescriptors $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 4/6] First-Event Seed & History Update Strictly After Compute..." -NoNewline
if (Test-FirstEventSeedAndHistorySequencing $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 5/6] Non-Blocking 4-File Readback Proof (C499, P500, C500, G500)..." -NoNewline
if (Test-B2BReadbackProofAndFourFileExport $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 6/6] Vulkan GPU Synchronization & Zero Hot-Path Blocking..." -NoNewline
if (Test-SynchronizationAndNoHotPathBlocking $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

if ($allPassed) {
    Write-Host "`n=== ALL B2B TWO-FRAME HISTORY INGESTION CONTRACTS PASSED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n=== SOME CONTRACTS FAILED ===" -ForegroundColor Red
    exit 1
}