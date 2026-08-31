# ==============================================================================
# v2b1b_b2b_isolation_c4_contract_test.ps1
# Contract Suite for LSFG B2B Isolation C4: Two-Hop Generated Output G -> D -> M
# ==============================================================================

$ErrorActionPreference = "Stop"

$repoRoot = "C:\Proyectos\amethyst"
$interposerCpp = Join-Path $repoRoot "app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"

if (-not (Test-Path $interposerCpp)) {
    Write-Error "Could not find lsfg_vulkan_interposer.cpp at $interposerCpp"
    exit 1
}

$source = Get-Content $interposerCpp -Raw

$allPassed = $true

function Report-Contract {
    param (
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ""
    )
    if ($Passed) {
        Write-Host "[$Name] PASS" -ForegroundColor Green
    } else {
        Write-Host "[$Name] FAIL: $Details" -ForegroundColor Red
        $script:allPassed = $false
    }
}

# ------------------------------------------------------------------------------
# Contract 1: C4 Gate Definition and Initialization Latching
# ------------------------------------------------------------------------------
$hasGateAtomic = ($source -match 'std::atomic<int>\s+g_b2bDiagGViaDToM\{0\};')
$hasEnvLatch = ($source -match 'AMETHYST_LSFG_B2B_DIAG_G_VIA_D_TO_M') -and
               ($source -match 'g_b2bDiagGViaDToM\.store\(1,\s*std::memory_order_relaxed\);')
$hasInitLog = ($source -match '\[LSFG-VK\]\s+B2B diagnostic G-via-D-to-M gate:')

Report-Contract "Contract 1/7" ($hasGateAtomic -and $hasEnvLatch -and $hasInitLog) "C4 gate atomic, env latching or logging missing."

# ------------------------------------------------------------------------------
# Contract 2: D Resource Usage Flags and Allocation Invariants
# ------------------------------------------------------------------------------
$hasDummyUsageC4 = ($source -match 'VK_IMAGE_USAGE_TRANSFER_DST_BIT\s*\|\s*VK_IMAGE_USAGE_TRANSFER_SRC_BIT') -or
                   ($source -match 'VK_IMAGE_USAGE_TRANSFER_DST_BIT\s*\|\s*\(isGViaDToM\s*\?\s*VK_IMAGE_USAGE_TRANSFER_SRC_BIT\s*:\s*0\)')
$hasReqsLog = ($source -match '\[LSFG-VK\]\s+B2B.*dummy.*memory requirements') -or
              ($source -match 'devStateCopy\.getImageMemoryRequirements\(device,\s*transport\.slots\[s\]\.dummyImage,\s*&dummyMemReq\)')
$noHotPathDAlloc = -not ($source -match 'interposer_vkQueuePresentKHR[\s\S]*?devStateCopy\.createImage\([\s\S]*?dummyImage')

Report-Contract "Contract 2/7" ($hasDummyUsageC4 -and $hasReqsLog -and $noHotPathDAlloc) "D resource must support TRANSFER_DST and TRANSFER_SRC and be allocated outside hot path."

# ------------------------------------------------------------------------------
# Contract 3: Structural C4 Execution Pipeline (N->C, P+C->G, G->D, D->M, C->P)
# ------------------------------------------------------------------------------
$c4BranchMatch = [regex]::Match($source, 'if\s*\(\s*isGViaDToM\s*\)\s*\{([\s\S]*?)\}\s*else\s+if\s*\(\s*isGToDummy\s*\)')
$hasC4Branch = $c4BranchMatch.Success

$c4ValidPipeline = $false
if ($hasC4Branch) {
    $c4Code = $c4BranchMatch.Groups[1].Value
    
    # Must capture N -> C
    $hasCaptureNtoC = ($c4Code -match 'transport\.cmdCopyImage\([^;]*?transport\.swapchainImages\[N\][^;]*?slot\.capturedImage')
    # Must NOT capture N -> M in any single copy call
    $noNtoM = -not ($c4Code -match 'transport\.cmdCopyImage\([^;]*?transport\.swapchainImages\[N\][^;]*?transport\.swapchainImages\[M\]')
    # Must NOT directly copy G -> M in any single copy call
    $noGtoM = -not ($c4Code -match 'transport\.cmdCopyImage\([^;]*?slot\.generatedImage[^;]*?transport\.swapchainImages\[M\]')
    
    # Must dispatch compute
    $hasCompute = ($c4Code -match 'transport\.cmdDispatch\(')
    
    # Must copy G -> D
    $hasGtoD = ($c4Code -match 'transport\.cmdCopyImage\([^;]*?slot\.generatedImage[^;]*?slot\.dummyImage')
    
    # Must copy D -> M
    $hasDtoM = ($c4Code -match 'transport\.cmdCopyImage\([^;]*?slot\.dummyImage[^;]*?transport\.swapchainImages\[M\]')
    
    # Must update history C -> P
    $hasHistUpdate = ($c4Code -match 'transport\.cmdCopyImage\([^;]*?slot\.capturedImage[^;]*?transport\.b2bHistoryImage')
    
    $c4ValidPipeline = $hasCaptureNtoC -and $noNtoM -and $noGtoM -and $hasCompute -and $hasGtoD -and $hasDtoM -and $hasHistUpdate
}

Report-Contract "Contract 3/7" $c4ValidPipeline "C4 pipeline must execute N->C, compute, G->D, D->M, C->P without N->M or G->M copies."

# ------------------------------------------------------------------------------
# Contract 4: D Intermediate Transfer Dependency
# ------------------------------------------------------------------------------
$hasDTransferBarrier = $false
if ($hasC4Branch) {
    $c4Code = $c4BranchMatch.Groups[1].Value
    # D barrier transitioning TRANSFER_DST_OPTIMAL to TRANSFER_SRC_OPTIMAL between Hop 1 and Hop 2
    $hasDTransferBarrier = ($c4Code -match 'VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL') -and
                           ($c4Code -match 'VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL') -and
                           ($c4Code -match 'VK_ACCESS_TRANSFER_WRITE_BIT') -and
                           ($c4Code -match 'VK_ACCESS_TRANSFER_READ_BIT') -and
                           ($c4Code -match 'slot\.dummyImage')
}

Report-Contract "Contract 4/7" $hasDTransferBarrier "D intermediate transfer barrier (TRANSFER_DST -> TRANSFER_SRC) missing or invalid."

# ------------------------------------------------------------------------------
# Contract 5: Baseline-Equivalent M Lifecycle
# ------------------------------------------------------------------------------
$hasBaselineMLifecycle = $false
if ($hasC4Branch) {
    $c4Code = $c4BranchMatch.Groups[1].Value
    # Pre-capture barriers block must not touch M
    $preCaptureBlock = [regex]::Match($c4Code, 'preCaptureBarriersC4\[3\][\s\S]*?cmdPipelineBarrier\([^;]*?preCaptureBarriersC4\);')
    $preCaptureNoM = $preCaptureBlock.Success -and (-not ($preCaptureBlock.Value -match 'transport\.swapchainImages\[M\]'))
    
    # Post-capture barriers block must not touch M
    $postCaptureBlock = [regex]::Match($c4Code, 'postCaptureBarriersC4\[3\][\s\S]*?cmdPipelineBarrier\([^;]*?postCaptureBarriersC4\);')
    $postCaptureNoM = $postCaptureBlock.Success -and (-not ($postCaptureBlock.Value -match 'transport\.swapchainImages\[M\]'))
    
    # M must transition UNDEFINED -> TRANSFER_DST at output stage
    $mInitialBarrier = ($c4Code -match 'VK_IMAGE_LAYOUT_UNDEFINED') -and
                       ($c4Code -match 'VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL') -and
                       ($c4Code -match 'transport\.swapchainImages\[M\]')
    # Final M barrier after history update
    $mFinalBarrier = ($c4Code -match 'VK_IMAGE_LAYOUT_PRESENT_SRC_KHR') -and
                     ($c4Code -match 'VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT')
    
    $hasBaselineMLifecycle = $preCaptureNoM -and $postCaptureNoM -and $mInitialBarrier -and $mFinalBarrier
}

Report-Contract "Contract 5/7" $hasBaselineMLifecycle "M lifecycle in C4 must match baseline timing and barrier structure."

# ------------------------------------------------------------------------------
# Contract 6: Event 500 Compatibility & Committed Post-Submit Telemetry
# ------------------------------------------------------------------------------
$hasC4Counter = ($source -match 'std::atomic<uint64_t>\s+g_b2bGViaDToM\{0\};')
$hasPostSubmitCommit = ($source -match 'if\s*\(\s*commitB2bGViaDToM\s*\)\s*\{\s*g_b2bGViaDToM\.fetch_add\(1')
$hasSummaryC4 = ($source -match '\[LSFG-B2B-SUMMARY\][\s\S]*?b2bGViaDToM=%') -and
                ($source -match 'g_b2bGViaDToM\.load\(')

Report-Contract "Contract 6/7" ($hasC4Counter -and $hasPostSubmitCommit -and $hasSummaryC4) "C4 post-submit committed telemetry and summary reporting missing."

# ------------------------------------------------------------------------------
# Contract 7: Synchronization and Hot-Path Invariants
# ------------------------------------------------------------------------------
$noHotPathBlockingWaits = -not ($source -match 'interposer_vkQueuePresentKHR[\s\S]*?(vkQueueWaitIdle|vkDeviceWaitIdle|vkWaitForFences)')
$hasSingleSubmit = ($source -match 'transport\.queueSubmit\(queue,\s*1,\s*&submitInfo')
$hasDualPresentOrder = ($source -match 'realFunc\(queue,\s*&presentM\)') -and
                       ($source -match 'realFunc\(queue,\s*&presentN\)')

Report-Contract "Contract 7/7" ($noHotPathBlockingWaits -and $hasSingleSubmit -and $hasDualPresentOrder) "Vulkan synchronization or presentation invariants violated."

if ($allPassed) {
    Write-Host "`n=== ALL B2B ISOLATION C4 CONTRACTS PASSED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n=== SOME CONTRACTS FAILED ===" -ForegroundColor Red
    exit 1
}
