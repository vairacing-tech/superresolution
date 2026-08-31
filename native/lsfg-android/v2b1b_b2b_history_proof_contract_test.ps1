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

function Get-CppBlock {
    param(
        [string]$Source,
        [string]$HeaderRegex
    )
    $match = [regex]::Match($Source, $HeaderRegex)
    if (-not $match.Success) {
        return $null
    }
    $start = $Source.IndexOf('{', $match.Index)
    if ($start -lt 0) { return $null }

    $braceCount = 1
    $index = $start + 1
    $length = $Source.Length

    while ($index -lt $length -and $braceCount -gt 0) {
        $ch = $Source[$index]
        if ($ch -eq '{') {
            $braceCount++
        } elseif ($ch -eq '}') {
            $braceCount--
        }
        $index++
    }

    if ($braceCount -eq 0) {
        return $Source.Substring($start, $index - $start)
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
    $hasCounters = ($clean -match 'g_b2bEligible') -and ($clean -match 'g_b2bSeed') -and
                   ($clean -match 'g_b2bDispatch') -and ($clean -match 'g_b2bHistoryUpdate') -and
                   ($clean -match 'g_b2bReadbackRequested') -and ($clean -match 'g_b2bReadbackRecorded') -and
                   ($clean -match 'g_b2bReadbackCompleted') -and ($clean -match 'g_b2bReadbackWritten') -and
                   ($clean -match 'g_b2bReadbackFailure')
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

function Test-B2BSpecificDispatchAndOrdering {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # Structurally verify B2B pipeline bind and dispatch inside the B2B block
    $bindPipelineMatch = $b2bBlock -match 'cmdBindPipeline\s*\([^,]+,\s*VK_PIPELINE_BIND_POINT_COMPUTE,\s*transport\.b2bComputePipeline\)'
    $bindDescMatch = $b2bBlock -match 'cmdBindDescriptorSets\s*\([^,]+,\s*VK_PIPELINE_BIND_POINT_COMPUTE,\s*transport\.b2bPipelineLayout,\s*0,\s*1,\s*&slot\.b2bDescriptorSet'
    $dispatchMatch = $b2bBlock -match 'cmdDispatch\s*\([^,]+,\s*groupCountX,\s*groupCountY,\s*1\)'

    if (-not ($bindPipelineMatch -and $bindDescMatch -and $dispatchMatch)) {
        return $false
    }

    # Verify strict intra-event ordering:
    # 1. Capture real frame N -> C (cmdCopyImage with swapchainImages[N] -> slot.capturedImage)
    # 2. B2B Compute Dispatch
    # 3. Output G -> M (cmdCopyImage with slot.generatedImage -> swapchainImages[M])
    # 4. History Update C -> P (cmdCopyImage with slot.capturedImage -> transport.b2bHistoryImage)
    $idxCapture = $b2bBlock.IndexOf('slot.capturedImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')
    $idxDispatch = $b2bBlock.IndexOf('transport.b2bComputePipeline')
    $idxOutputG = $b2bBlock.IndexOf('transport.swapchainImages[M], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')
    $idxUpdateP = if ($idxDispatch -ge 0) { $b2bBlock.IndexOf('transport.b2bHistoryImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL', $idxDispatch) } else { -1 }

    $orderingOk = ($idxCapture -ge 0) -and ($idxDispatch -gt $idxCapture) -and
                  ($idxOutputG -gt $idxDispatch) -and ($idxUpdateP -gt $idxOutputG)

    return $orderingOk
}

function Test-TemporalReadbackCaptureAndFenceExport {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # 1. Event E-1 Capture: captures C into b2bReadbackPrevCBuffer when event == targetEvent - 1
    $hasE1Check = ($b2bBlock -match 'targetB2bEvent\s*-\s*1') -and
                  ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPrevCBuffer')

    # 2. Event E Capture: captures P, C, G into their respective staging buffers
    $hasECheck = ($b2bBlock -match 'targetB2bEvent') -and
                 ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*transport\.b2bHistoryImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackPBuffer') -and
                 ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.capturedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackCBuffer') -and
                 ($b2bBlock -match 'cmdCopyImageToBuffer\s*\([^,]+,\s*slot\.generatedImage,\s*VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,\s*transport\.b2bReadbackGBuffer')

    # 3. Fence-gated readback export in QueuePresent: must poll b2bReadbackPending and call exportB2BReadbackFiles
    $hasFenceExport = ($presentFn -match 'transport\.b2bReadbackPending') -and
                      ($presentFn -match 'exportB2BReadbackFiles\s*\(') -and
                      ($presentFn -match 'g_b2bReadbackWritten\.fetch_add') -and
                      ($presentFn -match 'g_b2bReadbackFailure\.fetch_add')

    # 4. exportB2BReadbackFiles: bool return, dynamic format filenames, and runtime metadata
    $exportFn = Get-CppFunctionBody $Source 'exportB2BReadbackFiles'
    $hasDynamicFilenames = ($exportFn -ne $null) -and
                           ($exportFn -match 'b2b_event%u_current_rgba8\.raw') -and
                           ($exportFn -match 'b2b_event%u_previous_rgba8\.raw') -and
                           ($exportFn -match 'b2b_event%u_G_rgba8\.raw')
    $hasRuntimeMeta = ($exportFn -ne $null) -and
                      ($exportFn -match 'targetEvent') -and
                      ($exportFn -match 'prevEvent') -and
                      ($exportFn -match 'slotPrev') -and
                      ($exportFn -match 'slotCurrent') -and
                      ($exportFn -match 'committed_dispatch_counter')

    return ($hasE1Check -and $hasECheck -and $hasFenceExport -and $hasDynamicFilenames -and $hasRuntimeMeta)
}

function Test-PostSubmitCommitSemantics {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $b2bBlock = Get-CppBlock $presentFn 'else\s+if\s*\(\s*isB2bActive\s*\)'
    if ($null -eq $b2bBlock) { return $false }

    # Recording branch must NOT directly mutate persistent state/counters
    $noSeedMutationInRecording = -not ($b2bBlock -match '\b(?<!commit)b2bHistoryValid\s*=\s*true')
    $noDispatchIncrementInRecording = -not ($b2bBlock -match '\bg_b2bDispatch\.fetch_add')
    $noPendingMutationInRecording = -not ($b2bBlock -match '\b(?<!commit)b2bReadbackPending\s*=\s*true')

    # Post-submit success block (submitRes == VK_SUCCESS) must commit state and advance counters
    $postSubmitBlock = Get-CppBlock $presentFn 'if\s*\(\s*submitRes\s*==\s*VK_SUCCESS\s*\)'
    if ($null -eq $postSubmitBlock) { return $false }

    $hasSeedCommit = ($postSubmitBlock -match 'commitB2bSeed') -and ($postSubmitBlock -match 'b2bHistoryValid\s*=\s*true') -and ($postSubmitBlock -match 'g_b2bSeed\.fetch_add')
    $hasDispatchCommit = ($postSubmitBlock -match 'commitB2bDispatch') -and ($postSubmitBlock -match 'g_b2bDispatch\.fetch_add')
    $hasHistUpdateCommit = ($postSubmitBlock -match 'commitB2bHistoryUpdate') -and ($postSubmitBlock -match 'g_b2bHistoryUpdate\.fetch_add')
    $hasReadbackCommit = ($postSubmitBlock -match 'commitB2bReadbackPending') -and ($postSubmitBlock -match 'b2bReadbackPending\s*=\s*true') -and ($postSubmitBlock -match 'g_b2bReadbackRecorded\.fetch_add')

    return ($noSeedMutationInRecording -and $noDispatchIncrementInRecording -and $noPendingMutationInRecording -and
            $hasSeedCommit -and $hasDispatchCommit -and $hasHistUpdateCommit -and $hasReadbackCommit)
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

Write-Host "[Contract 1/7] B2B Diagnostic Gates and Counters..." -NoNewline
if (Test-B2BGatesAndAtomics $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 2/7] B2B 32x32 Checkerboard Shader & SPIR-V Header..." -NoNewline
if (Test-B2BShaderAndSpirv $ShaderSource $SpirvHeader $B2aShaderSource $B2aSpirvHeader) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 3/7] Dedicated Swapchain-Scoped History Image (P) Resource..." -NoNewline
if (Test-DedicatedHistoryResourceAndDescriptors $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 4/7] B2B-Specific Dispatch & Strict History Update Ordering..." -NoNewline
if (Test-B2BSpecificDispatchAndOrdering $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 5/7] Temporal E-1/E Capture & Fence-Gated 4-File Readback Export..." -NoNewline
if (Test-TemporalReadbackCaptureAndFenceExport $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 6/7] Post-Submit Commit Semantics (Zero Pre-Commit Mutation)..." -NoNewline
if (Test-PostSubmitCommitSemantics $source) {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "[Contract 7/7] Vulkan GPU Synchronization & Zero Hot-Path Blocking..." -NoNewline
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
