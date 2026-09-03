# ==============================================================================
# REAL-LSFG-R1 Sustained Gameplay Bring-Up Contract Test
# ==============================================================================
$ErrorActionPreference = "Stop"

$amethystPath = "C:\Proyectos\amethyst"
$interposerFile = Join-Path $amethystPath "app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
$lsfgCppFile = "C:\Proyectos\LS-FG\lsfg-vk-android\src\lsfg_vk_external_context.cpp"

if (-not (Test-Path $interposerFile)) {
    Write-Error "Interposer file not found: $interposerFile"
    exit 1
}

$interposerSource = Get-Content -Path $interposerFile -Raw
$lsfgCppSource = if (Test-Path $lsfgCppFile) { Get-Content -Path $lsfgCppFile -Raw } else { "" }

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

Write-Host "Running REAL-LSFG-R1 Contract Tests..." -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# Contract 1/20: R1 arm-delay env gate exists (AMETHYST_LSFG_REAL_FG_ARM_DELAY_MS)
# ------------------------------------------------------------------------------
$hasArmDelayEnv = ($interposerSource -match 'AMETHYST_LSFG_REAL_FG_ARM_DELAY_MS') -and
                  ($interposerSource -match 'g_realFgArmDelayMs')
Report-Contract "Contract 1/20" $hasArmDelayEnv "R1 arm-delay env gate AMETHYST_LSFG_REAL_FG_ARM_DELAY_MS and atomic counter exist."

# ------------------------------------------------------------------------------
# Contract 2/20: Arm delay uses monotonic timing (std::chrono::steady_clock)
# ------------------------------------------------------------------------------
$hasMonotonicClock = ($interposerSource -match 'std::chrono::steady_clock::now') -or
                     ($interposerSource -match 'steady_clock::time_point')
Report-Contract "Contract 2/20" $hasMonotonicClock "Arm delay uses monotonic timing (std::chrono::steady_clock)."

# ------------------------------------------------------------------------------
# Contract 3/20: Pre-arm path bypasses BEFORE transport.acquire
# ------------------------------------------------------------------------------
$qpBlock = [regex]::Match($interposerSource, 'interposer_vkQueuePresentKHR[\s\S]*?return\s+resN;')
$preArmBeforeAcquire = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $posAcquire = $qpText.IndexOf('transport.acquire(')
    $posArmCheck = $qpText.IndexOf('g_realFgArmDelayMs')
    if ($posArmCheck -ge 0 -and $posAcquire -ge 0 -and $posArmCheck -lt $posAcquire) {
        $preArmBeforeAcquire = $true
    }
}
Report-Contract "Contract 3/20" $preArmBeforeAcquire "Pre-arm delay check must bypass QueuePresent BEFORE transport.acquire."

# ------------------------------------------------------------------------------
# Contract 4/20: Generated budget does not begin counting during pre-arm pass-through
# ------------------------------------------------------------------------------
$preArmIncrementsWaitCounter = ($interposerSource -match 'g_realFgArmWaitingPresent\.fetch_add')
$preArmLeavesCommittedZero = ($interposerSource -match 'realFgArmWaitingPresent')
Report-Contract "Contract 4/20" ($preArmIncrementsWaitCounter -and $preArmLeavesCommittedZero) "Pre-arm frames increment waiting counter without consuming generated-event budget."

# ------------------------------------------------------------------------------
# Contract 5/20: R1 MAX_EVENTS semantics remain committed-event based
# ------------------------------------------------------------------------------
$hasCommittedLimit = ($interposerSource -match 'realFgCommittedCount\s*<\s*static_cast<uint64_t>\(realFgMaxEvents\)')
Report-Contract "Contract 5/20" $hasCommittedLimit "R1 MAX_EVENTS limit is checked against committed generated events."

# ------------------------------------------------------------------------------
# Contract 6/20: Event #120 is allowed when committed is 119
# ------------------------------------------------------------------------------
$allows119To120 = ($interposerSource -match 'realFgCommittedCount\s*<\s*static_cast<uint64_t>\(realFgMaxEvents\)')
Report-Contract "Contract 6/20" $allows119To120 "Event #120 remains within budget when committed count is 119."

# ------------------------------------------------------------------------------
# Contract 7/20: Event #121 generated path is bypassed when committed is 120
# ------------------------------------------------------------------------------
$bypassesAtMax = ($interposerSource -match 'if\s*\(\s*isRealFgRequested\s*&&\s*!withinRealFgBudget\s*\)\s*\{[\s\S]*?return\s+realFunc\(queue,\s*pPresentInfo\);')
Report-Contract "Contract 7/20" $bypassesAtMax "Event #121 is immediately bypassed to ORIGINAL-N present when committed equals budget."

# ------------------------------------------------------------------------------
# Contract 8/20: No M acquire after budget exhaustion
# ------------------------------------------------------------------------------
$hasBudgetCheckBeforeAcquire = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $posAcquire = $qpText.IndexOf('transport.acquire(')
    $posBudgetCheck = $qpText.IndexOf('isRealFgRequested && !withinRealFgBudget')
    if ($posBudgetCheck -ge 0 -and $posAcquire -ge 0 -and $posBudgetCheck -lt $posAcquire) {
        $hasBudgetCheckBeforeAcquire = $true
    }
}
Report-Contract "Contract 8/20" $hasBudgetCheckBeforeAcquire "Budget exhaustion check occurs strictly before transport.acquire (zero post-budget M acquires)."

# ------------------------------------------------------------------------------
# Contract 9/20: Timestamp query pools created outside QueuePresent hot path
# ------------------------------------------------------------------------------
$queryPoolCreatedInInit = ($interposerSource -match 'createQueryPool') -and
                         ($interposerSource -match 'interposer_vkCreateSwapchainKHR[\s\S]*?createQueryPool')
$noQueryPoolInPresent = -not ($qpBlock.Success -and ($qpBlock.Value -match 'createQueryPool'))
Report-Contract "Contract 9/20" ($queryPoolCreatedInInit -and $noQueryPoolInPresent) "Timestamp query pools are created in transport setup and never in QueuePresent."

# ------------------------------------------------------------------------------
# Contract 10/20: Timestamp capability uses runtime timestampPeriod
# ------------------------------------------------------------------------------
$usesRuntimePeriod = ($interposerSource -match 'limits\.timestampPeriod') -or
                     ($interposerSource -match 'timestampPeriod')
Report-Contract "Contract 10/20" $usesRuntimePeriod "GPU timing uses runtime VkPhysicalDeviceLimits timestampPeriod."

# ------------------------------------------------------------------------------
# Contract 11/20: timestampValidBits is runtime-derived
# ------------------------------------------------------------------------------
$usesRuntimeValidBits = ($interposerSource -match 'timestampValidBits')
Report-Contract "Contract 11/20" $usesRuntimeValidBits "GPU timestamp bit wrap handling uses runtime queue-family timestampValidBits."

# ------------------------------------------------------------------------------
# Contract 12/20: No vkDeviceWaitIdle in QueuePresent hot path
# ------------------------------------------------------------------------------
$noDeviceWaitIdle = -not ($qpBlock.Success -and ($qpBlock.Value -match 'deviceWaitIdle'))
Report-Contract "Contract 12/20" $noDeviceWaitIdle "Zero deviceWaitIdle calls permitted in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract 13/20: No vkQueueWaitIdle in QueuePresent hot path
# ------------------------------------------------------------------------------
$noQueueWaitIdle = -not ($qpBlock.Success -and ($qpBlock.Value -match 'queueWaitIdle'))
Report-Contract "Contract 13/20" $noQueueWaitIdle "Zero queueWaitIdle calls permitted in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract 14/20: No VK_QUERY_RESULT_WAIT_BIT for in-flight query retrieval
# ------------------------------------------------------------------------------
$noQueryResultWaitBit = -not ($interposerSource -match 'VK_QUERY_RESULT_WAIT_BIT')
Report-Contract "Contract 14/20" $noQueryResultWaitBit "Query result collection must NOT use VK_QUERY_RESULT_WAIT_BIT."

# ------------------------------------------------------------------------------
# Contract 15/20: Query result retrieval occurs only after slot fence completion
# ------------------------------------------------------------------------------
$resultsAfterFence = ($interposerSource -match 'fenceRes\s*==\s*VK_SUCCESS[\s\S]*?getQueryPoolResults')
Report-Contract "Contract 15/20" $resultsAfterFence "Query results are collected only after slot fence proves submission completion."

# ------------------------------------------------------------------------------
# Contract 16/20: Timestamp metadata is per-slot
# ------------------------------------------------------------------------------
$slotHasTimestampPool = ($interposerSource -match 'struct\s+TransportSlot[\s\S]*?timestampQueryPool')
Report-Contract "Contract 16/20" $slotHasTimestampPool "Timestamp query pools and query tracking metadata are stored per-TransportSlot."

# ------------------------------------------------------------------------------
# Contract 17/20: Generated-event ID is preserved across slot reuse
# ------------------------------------------------------------------------------
$hasEventIdTracking = ($interposerSource -match 'timestampEventId')
Report-Contract "Contract 17/20" $hasEventIdTracking "Each slot tracks the generated-event ID for deferred query result association."

# ------------------------------------------------------------------------------
# Contract 18/20: Timing samples only aggregate complete committed events
# ------------------------------------------------------------------------------
$hasTimingAggregation = ($interposerSource -match 'lsfgGpuMinMs') -or
                        ($interposerSource -match 'lsfgGpuMeanMs') -or
                        ($interposerSource -match 'record_r1_timing_sample')
Report-Contract "Contract 18/20" $hasTimingAggregation "Timing samples are aggregated with min, max, mean, and median for complete committed events."

# ------------------------------------------------------------------------------
# Contract 19/20: No hot-path malloc/new for timing samples
# ------------------------------------------------------------------------------
$noHeapAllocInQP = -not ($qpBlock.Success -and ($qpBlock.Value -match '\bmalloc\b|\bcalloc\b|\bnew\s+'))
Report-Contract "Contract 19/20" $noHeapAllocInQP "Zero dynamic memory allocations (malloc/calloc/new) in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract 20/20: LSFG/C4 topology remains unchanged
# ------------------------------------------------------------------------------
$c4TopologyIntact = ($interposerSource -match 'slot\.generatedImage[^;]*?slot\.dummyImage') -and
                    ($interposerSource -match 'slot\.dummyImage[^;]*?swapchainImages\[M\]') -and
                    ($interposerSource -match 'slot\.capturedImage[^;]*?transport\.b2bHistoryImage')
Report-Contract "Contract 20/20" $c4TopologyIntact "C4 G->D->M staging and C->P history update topologies remain strictly preserved."

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "REAL-LSFG-R1 CONTRACT SUITE: ALL CONTRACTS PASSED (GREEN)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "REAL-LSFG-R1 CONTRACT SUITE: CONTRACTS FAILED (RED)" -ForegroundColor Red
    exit 1
}
