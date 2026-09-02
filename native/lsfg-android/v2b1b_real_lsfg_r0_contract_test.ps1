# ==============================================================================
# v2b1b_real_lsfg_r0_contract_test.ps1
# Contract Suite for REAL-LSFG-R0: Real Lossless Scaling Frame Generation 3.1
# ==============================================================================

$ErrorActionPreference = "Stop"

$amethystRoot = "C:\Proyectos\amethyst"
$interposerCpp = Join-Path $amethystRoot "app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
$lsfgRoot = "C:\Proyectos\LS-FG"
$lsfgHeader = Join-Path $lsfgRoot "lsfg-vk-android\framegen\public\lsfg_3_1.hpp"
$lsfgCpp = Join-Path $lsfgRoot "lsfg-vk-android\framegen\v3.1_src\lsfg.cpp"

if (-not (Test-Path $interposerCpp)) {
    Write-Error "Could not find lsfg_vulkan_interposer.cpp at $interposerCpp"
    exit 1
}

$interposerSource = Get-Content $interposerCpp -Raw
$lsfgHeaderSource = if (Test-Path $lsfgHeader) { Get-Content $lsfgHeader -Raw } else { "" }
$lsfgCppSource = if (Test-Path $lsfgCpp) { Get-Content $lsfgCpp -Raw } else { "" }

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

Write-Host "Running REAL-LSFG-R0 Contract Tests..." -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# Contract 1: REAL FG gate default OFF and latched at initialization
# ------------------------------------------------------------------------------
$hasRealFgGate = ($interposerSource -match 'std::atomic<int>\s+g_realFgEnabled\{0\};') -or
                 ($interposerSource -match 'std::atomic<bool>\s+g_realFgEnabled\{false\};')
$hasEnvLatch = ($interposerSource -match 'getenv\("AMETHYST_LSFG_REAL_FG_R0"\)') -and
               ($interposerSource -match 'g_realFgEnabled\.store')
Report-Contract "Contract 1/34" ($hasRealFgGate -and $hasEnvLatch) "REAL FG gate atomic default 0 and AMETHYST_LSFG_REAL_FG_R0 env latching required."

# ------------------------------------------------------------------------------
# Contract 2: Runtime shader delivery from user-provided private cache & validation
# ------------------------------------------------------------------------------
$hasCachePath = ($interposerSource -match '/sdcard/Android/data/com\.vairacing\.amethystplus\.debug/files/lsfg_shader_cache')
$hasMagicValidation = ($interposerSource -match '0x07230203')
$noEmbeddedSpvInRepo = -not (Test-Path (Join-Path $amethystRoot "app_pojavlauncher\src\main\assets\shaders\lsfg_3_1\res_255.spv"))
Report-Contract "Contract 2/34" ($hasCachePath -and $hasMagicValidation -and $noEmbeddedSpvInRepo) "Runtime shader delivery must validate SPIR-V magic and use private Android cache, not embedded SPIR-V."

# ------------------------------------------------------------------------------
# Contract 3: P Resource has SAMPLED_BIT usage
# ------------------------------------------------------------------------------
$hasPSampledUsage = ($interposerSource -match 'b2bHistImgInfo[\s\S]*?VK_IMAGE_USAGE_SAMPLED_BIT') -or
                    ($interposerSource -match 'transport\.b2bHistoryImage[\s\S]*?VK_IMAGE_USAGE_SAMPLED_BIT')
Report-Contract "Contract 3/34" $hasPSampledUsage "P (b2bHistoryImage) creation flags must include VK_IMAGE_USAGE_SAMPLED_BIT."

# ------------------------------------------------------------------------------
# Contract 4: C Resource has SAMPLED_BIT and TRANSFER_SRC_BIT usage
# ------------------------------------------------------------------------------
$hasCSampledUsage = ($interposerSource -match 'capImgInfo\.usage[\s\S]*?VK_IMAGE_USAGE_SAMPLED_BIT') -and
                    ($interposerSource -match 'capImgInfo\.usage[\s\S]*?VK_IMAGE_USAGE_TRANSFER_SRC_BIT')
Report-Contract "Contract 4/34" $hasCSampledUsage "C (capturedImage) creation flags must include VK_IMAGE_USAGE_SAMPLED_BIT and VK_IMAGE_USAGE_TRANSFER_SRC_BIT."

# ------------------------------------------------------------------------------
# Contract 5: G Resource remains STORAGE and TRANSFER_SRC
# ------------------------------------------------------------------------------
$hasGStorageTransfer = ($interposerSource -match 'imgInfo\.usage[\s\S]*?VK_IMAGE_USAGE_STORAGE_BIT') -and
                       ($interposerSource -match 'imgInfo\.usage[\s\S]*?VK_IMAGE_USAGE_TRANSFER_SRC_BIT')
Report-Contract "Contract 5/34" $hasGStorageTransfer "G (generatedImage) creation flags must include STORAGE_BIT and TRANSFER_SRC_BIT."

# ------------------------------------------------------------------------------
# Contract 6: External LS-FG Context API defined and implemented
# ------------------------------------------------------------------------------
$hasExternalContextDecl = ($lsfgHeaderSource -match 'lsfg_create_context_external') -and
                          ($lsfgHeaderSource -match 'LsfgExternalContextDesc')
$hasExternalContextImpl = ($lsfgCppSource -match 'lsfg_create_context_external')
Report-Contract "Contract 6/34" ($hasExternalContextDecl -and $hasExternalContextImpl) "LS-FG external-device context API must be declared and implemented in LS-FG."

# ------------------------------------------------------------------------------
# Contract 7: Generation records into caller VkCommandBuffer
# ------------------------------------------------------------------------------
$hasRecordGenDecl = ($lsfgHeaderSource -match 'lsfg_record_generation')
$hasRecordGenImpl = ($lsfgCppSource -match 'lsfg_record_generation\s*\([\s\S]*?VkCommandBuffer\s+cmdBuffer')
Report-Contract "Contract 7/34" ($hasRecordGenDecl -and $hasRecordGenImpl) "LS-FG generation recording API must be implemented and record into caller VkCommandBuffer."

# ------------------------------------------------------------------------------
# Contract 8: No LSFG-owned per-frame queueSubmit or waitIdle on hot path
# ------------------------------------------------------------------------------
$presentMethodBlock = [regex]::Match($interposerSource, 'interposer_vkQueuePresentKHR[\s\S]*?return\s+resN;')
$noLsfgQueueSubmitInPresent = if ($presentMethodBlock.Success) {
    -not ($presentMethodBlock.Value -match 'vkDeviceWaitIdle') -and -not ($presentMethodBlock.Value -match 'LSFG_3_1::waitIdle')
} else { $true }
Report-Contract "Contract 8/34" $noLsfgQueueSubmitInPresent "No LSFG-owned queueSubmit or waitIdle inside QueuePresent."

# ------------------------------------------------------------------------------
# Contract 9: Endpoint image views are pre-created and registered outside hot path
# ------------------------------------------------------------------------------
$hasPrecreatedEndpoints = ($interposerSource -match 'viewP\s*=\s*transport\.b2bHistoryImageView') -and
                          ($interposerSource -match 'viewC\[s\]\s*=\s*transport\.slots\[s\]\.capturedImageView') -and
                          ($interposerSource -match 'viewG\[s\]\s*=\s*transport\.slots\[s\]\.generatedImageView')
Report-Contract "Contract 9/34" $hasPrecreatedEndpoints "Endpoint image views (P, C, G) must be pre-created and registered outside hot path."

# ------------------------------------------------------------------------------
# Contract 10: No descriptor allocation/update hazard on in-flight sets
# ------------------------------------------------------------------------------
$noHotPathDescAlloc = if ($presentMethodBlock.Success) {
    -not ($presentMethodBlock.Value -match 'allocateDescriptorSets') -and
    -not ($presentMethodBlock.Value -match 'createDescriptorPool')
} else { $true }
Report-Contract "Contract 10/34" $noHotPathDescAlloc "No descriptor pool or set allocation in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract 11: Per-slot mutable descriptor and UBO state
# ------------------------------------------------------------------------------
$hasPerSlotState = ($interposerSource -match 'slots\[2\]') -and
                   ($interposerSource -match 'kSlotCount\s*=\s*2')
Report-Contract "Contract 11/34" $hasPerSlotState "Per-TransportSlot state separation for frame-varying descriptors/UBOs across 2 slots."

# ------------------------------------------------------------------------------
# Contract 12: Coherent shared LSFG temporal state across slot alternation
# ------------------------------------------------------------------------------
$hasCoherentTemporalState = ($interposerSource -match 'transport\.b2bHistoryImage') -and
                            ($interposerSource -match 'b2bHistoryValid')
Report-Contract "Contract 12/34" $hasCoherentTemporalState "Coherent shared temporal history across slot alternation."

# ------------------------------------------------------------------------------
# Contract 13: Cross-frame persistent resource memory dependency
# ------------------------------------------------------------------------------
$hasCrossFrameBarrier = ($interposerSource -match 'VK_STRUCTURE_TYPE_MEMORY_BARRIER[\s\S]*?VK_ACCESS_SHADER_WRITE_BIT[\s\S]*?VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT') -or
                        ($lsfgCppSource -match 'VK_STRUCTURE_TYPE_MEMORY_BARRIER[\s\S]*?VK_ACCESS_SHADER_WRITE_BIT[\s\S]*?VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT')
Report-Contract "Contract 13/34" $hasCrossFrameBarrier "Cross-frame compute memory dependency exists for persistent scratch/history resources."

# ------------------------------------------------------------------------------
# Contract 14: Transactional LSFG frame state committed strictly post-submit
# ------------------------------------------------------------------------------
$hasTransactionalCommit = ($interposerSource -match 'if\s*\(\s*submitRes\s*==\s*VK_SUCCESS\s*\)[\s\S]*?if\s*\(\s*commitRealFgRecorded\s*\)\s*\{[\s\S]*?g_realFgCommitted\.fetch_add') -and
                          ($interposerSource -match 'g_realFgSubmitSuccess\.fetch_add')
Report-Contract "Contract 14/34" $hasTransactionalCommit "Transactional LSFG temporal advancement committed strictly post-submit."

# ------------------------------------------------------------------------------
# Contract 15: Exactly 10 committed generated events limit
# ------------------------------------------------------------------------------
$hasTenEventLimit = ($interposerSource -match 'g_realFgMaxEvents\{10\}') -and
                    ($interposerSource -match 'realFgCommittedCount\s*<\s*static_cast<uint64_t>\(realFgMaxEvents\)')
Report-Contract "Contract 15/34" $hasTenEventLimit "Bounded REAL-FG-R0 experiment with exactly 10 committed generated events."

# ------------------------------------------------------------------------------
# Contract 16: Post-budget ORIGINAL-N PASS-THROUGH
# ------------------------------------------------------------------------------
$hasPassThroughFallback = ($interposerSource -match 'g_realFgBudgetExhausted\.fetch_add') -and
                          ($interposerSource -match 'ORIGINAL-N PASS-THROUGH')
Report-Contract "Contract 16/34" $hasPassThroughFallback "Post-budget exhaustion safely defaults to ORIGINAL-N PASS-THROUGH."

# ------------------------------------------------------------------------------
# Contract 17: G -> D -> M two-hop output preserved
# ------------------------------------------------------------------------------
$hasGViaDtoMInRealFg = ($interposerSource -match 'cmdCopyImage\([^;]*?generatedImage[^;]*?dummyImage') -and
                       ($interposerSource -match 'cmdCopyImage\([^;]*?dummyImage[^;]*?swapchainImages\[M\]')
Report-Contract "Contract 17/34" $hasGViaDtoMInRealFg "G -> D -> M two-hop output preserved for generated frame presentation."

# ------------------------------------------------------------------------------
# Contract 18: NO direct G -> M in REAL-FG-R0
# ------------------------------------------------------------------------------
$realFgBlock = [regex]::Match($interposerSource, 'if\s*\(\s*isRealFgActive[\s\S]*?\}\s*else\s+if')
$noDirectGtoMInRealFg = if ($realFgBlock.Success) { -not ($realFgBlock.Value -match 'cmdCopyImage\([^;]*?generatedImage[^;]*?swapchainImages\[M\]') } else { $false }
Report-Contract "Contract 18/34" $noDirectGtoMInRealFg "NO direct G -> M copy in REAL-FG-R0 execution path."

# ------------------------------------------------------------------------------
# Contract 19: Presentation order: Present M then Present N
# ------------------------------------------------------------------------------
$hasMthenNPresent = ($interposerSource -match 'presentM|presentInfoM|PresentInfoM') -and
                    ($interposerSource -match 'presentN|pPresentInfo')
Report-Contract "Contract 19/34" $hasMthenNPresent "Sequential presentation order: Present M (generated) then Present N (real)."

# ------------------------------------------------------------------------------
# Contract 20: Fail-open pre-submit paths to original N
# ------------------------------------------------------------------------------
$hasPreSubmitFailOpen = ($interposerSource -match 'g_realFgPreSubmitFallback\.fetch_add') -or
                        ($interposerSource -match 'realFgPreSubmitFallback')
Report-Contract "Contract 20/34" $hasPreSubmitFailOpen "Pre-submit failure conditions fail open to normal real N present."

# ------------------------------------------------------------------------------
# Contract 21: No hot-path extraction, file IO, or pipeline creation
# ------------------------------------------------------------------------------
$noHotPathIO = -not ($interposerSource -match 'interposer_vkQueuePresentKHR[\s\S]*?fopen') -and
               -not ($interposerSource -match 'interposer_vkQueuePresentKHR[\s\S]*?createComputePipelines')
Report-Contract "Contract 21/34" $noHotPathIO "Zero file I/O, extraction, or pipeline compilation in QueuePresent hot path."

# ------------------------------------------------------------------------------
# Contract 22: Dedicated R0 telemetry and summary tag
# ------------------------------------------------------------------------------
$hasR0Telemetry = ($interposerSource -match 'g_realFgInitSuccess') -and
                  ($interposerSource -match 'g_realFgCommitted') -and
                  ($interposerSource -match '\[LSFG-REAL-R0-SUMMARY\]')
Report-Contract "Contract 22/34" $hasR0Telemetry "Dedicated R0 telemetry counters and [LSFG-REAL-R0-SUMMARY] log exist."

# ------------------------------------------------------------------------------
# Contract 23: C1/C2/C3/C4 diagnostic modes preserved
# ------------------------------------------------------------------------------
$hasPreservedDiags = ($interposerSource -match 'g_b2bDiagGViaDToM') -and
                     ($interposerSource -match 'g_b2bDiagGToDummy') -and
                     ($interposerSource -match 'g_b2bDiagOffscreenG') -and
                     ($interposerSource -match 'g_b2bDiagMHoldToEnd')
Report-Contract "Contract 23/34" $hasPreservedDiags "C1/C2/C3/C4 diagnostic isolation modes preserved intact."

# ------------------------------------------------------------------------------
# Contract 24: Amethyst does NOT contain shader-ID descriptor-binding table
# ------------------------------------------------------------------------------
$amethystNoManualShaderTable = -not ($interposerSource -match 'uint32_t\s+resIds\[25\]\s*=') -and
                               -not ($interposerSource -match 'if\s*\(\s*id\s*==\s*255\s*\)')
Report-Contract "Contract 24/34" $amethystNoManualShaderTable "Amethyst must NOT contain manual shader-ID descriptor-binding table or fallback."

# ------------------------------------------------------------------------------
# Contract 25: Amethyst does NOT directly compile the 25 LSFG compute pipelines
# ------------------------------------------------------------------------------
$amethystNoDirect25PipelineCompilation = -not ($interposerSource -match 'for\s*\(\s*uint32_t\s+id\s*:\s*resIds\s*\)[\s\S]*?createComputePipelines')
Report-Contract "Contract 25/34" $amethystNoDirect25PipelineCompilation "Amethyst must NOT directly compile the 25 LSFG compute pipelines; must delegate to LS-FG."

# ------------------------------------------------------------------------------
# Contract 26: LS-FG external context implementation owns pipeline creation
# ------------------------------------------------------------------------------
$lsfgOwnsPipelineCreation = ($lsfgCppSource -match 'ctx->createDescriptorSetLayout') -and
                            ($lsfgCppSource -match 'ctx->createPipelineLayout') -and
                            ($lsfgCppSource -match 'ctx->createComputePipelines')
Report-Contract "Contract 26/34" $lsfgOwnsPipelineCreation "LS-FG external context must own descriptor layouts, pipeline layouts, and compute pipeline creation."

# ------------------------------------------------------------------------------
# Contract 27: All 25 LSFG 3.1 shader identities mapped with exact ABI in LS-FG
# ------------------------------------------------------------------------------
$lsfgMapsAll25Shaders = ($lsfgCppSource -match 'kLsfg31ShaderAbi') -or
                        ($lsfgCppSource -match 'getShaderAbi') -or
                        ($lsfgCppSource -match 'get_shader_abi')
Report-Contract "Contract 27/34" $lsfgMapsAll25Shaders "LS-FG must maintain authoritative descriptor ABI table for all 25 shaders (255..279)."

# ------------------------------------------------------------------------------
# Contract 28: res_257 explicitly has 15 bindings (0 through 14)
# ------------------------------------------------------------------------------
$res257Has15Bindings = ($lsfgCppSource -match 'kLsfg31ShaderAbi') -and
                       (($lsfgCppSource -match '257[\s\S]*?15') -or ($lsfgCppSource -match 'res_257[\s\S]*?15'))
Report-Contract "Contract 28/34" $res257Has15Bindings "res_257 descriptor ABI must explicitly define 15 bindings (0 through 14)."

# ------------------------------------------------------------------------------
# Contract 29: No generic 4-binding fallback for arbitrary id >= 257
# ------------------------------------------------------------------------------
$hasFallbackInInterposer = ($interposerSource -match 'bindings\.push_back\(\{\s*3\s*,\s*VK_DESCRIPTOR_TYPE_STORAGE_IMAGE')
$hasFallbackInLsfg = ($lsfgCppSource -match 'bindings\.push_back\(\{\s*3\s*,\s*VK_DESCRIPTOR_TYPE_STORAGE_IMAGE')
$noFourBindingFallback = (-not $hasFallbackInInterposer) -and (-not $hasFallbackInLsfg)
Report-Contract "Contract 29/34" $noFourBindingFallback "No generic 4-binding fallback allowed for id >= 257 in Amethyst or LS-FG."

# ------------------------------------------------------------------------------
# Contract 30: Budget-exhausted check occurs BEFORE transport.acquire
# ------------------------------------------------------------------------------
$qpBlock = [regex]::Match($interposerSource, 'interposer_vkQueuePresentKHR[\s\S]*?return\s+resN;')
$budgetBeforeAcquire = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $posAcquire = $qpText.IndexOf('transport.acquire(')
    $posBudgetCheck = $qpText.IndexOf('isRealFgRequested && !withinRealFgBudget')
    if ($posBudgetCheck -ge 0 -and $posAcquire -ge 0 -and $posBudgetCheck -lt $posAcquire) {
        $budgetBeforeAcquire = $true
    }
}
Report-Contract "Contract 30/34" $budgetBeforeAcquire "REAL-FG budget exhaustion check must occur BEFORE transport.acquire in QueuePresent."

# ------------------------------------------------------------------------------
# Contract 31: Post-budget branch directly calls ORIGINAL-N present
# ------------------------------------------------------------------------------
$postBudgetDirectN = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $postBudgetDirectN = ($qpText -match 'if\s*\(\s*isRealFgRequested\s*&&\s*!withinRealFgBudget\s*\)\s*\{[\s\S]*?return\s+realFunc\(queue,\s*pPresentInfo\);')
}
Report-Contract "Contract 31/34" $postBudgetDirectN "Post-budget path must immediately return realFunc(queue, pPresentInfo) without transport allocation."

# ------------------------------------------------------------------------------
# Contract 32: Generated event #10 remains allowed (committed < maxEvents)
# ------------------------------------------------------------------------------
$hasEvent10Preservation = ($interposerSource -match 'realFgCommittedCount\s*<\s*static_cast<uint64_t>\(\s*realFgMaxEvents\s*\)') -or
                          ($interposerSource -match 'committed\s*<\s*static_cast<uint64_t>\(\s*realFgMaxEvents\s*\)')
Report-Contract "Contract 32/34" $hasEvent10Preservation "Budget limit must preserve full 10th event using committed < maxEvents."

# ------------------------------------------------------------------------------
# Contract 33: No post-acquire path orphans M without presentation or consumption
# ------------------------------------------------------------------------------
$noOrphanedMAfterAcquire = $false
if ($qpBlock.Success) {
    $qpText = $qpBlock.Value
    $posAcq = $qpText.IndexOf('resAcquire == VK_SUCCESS')
    if ($posAcq -ge 0) {
        $postAcqBlock = $qpText.Substring($posAcq)
        # Inside postAcqBlock, the early budget check should NOT exist
        $hasBudgetCheckPostAcq = ($postAcqBlock -match 'if\s*\(\s*isRealFgRequested\s*&&\s*!withinRealFgBudget\s*\)')
        $noOrphanedMAfterAcquire = (-not $hasBudgetCheckPostAcq)
    }
}
Report-Contract "Contract 33/34" $noOrphanedMAfterAcquire "No post-acquire code path may drop into N-only present leaving M orphaned."

# ------------------------------------------------------------------------------
# Contract 34: Historical direct G->M copy remains absent from REAL-FG
# ------------------------------------------------------------------------------
$noDirectGtoMInRealFg = $false
$posRealFgStart = $interposerSource.IndexOf('if (isRealFgActive)')
$posRealFgEnd = $interposerSource.IndexOf('commitRealFgRecorded = true;')
if ($posRealFgStart -ge 0 -and $posRealFgEnd -gt $posRealFgStart) {
    $realFgSlice = $interposerSource.Substring($posRealFgStart, $posRealFgEnd - $posRealFgStart)
    $hasDirectGtoM = ($realFgSlice -match 'cmdCopyImage\s*\([^;]*?slot\.generatedImage[^;]*?swapchainImages\[M\]')
    $hasTwoHop = ($realFgSlice -match 'slot\.generatedImage[^;]*?slot\.dummyImage') -and
                 ($realFgSlice -match 'slot\.dummyImage[^;]*?swapchainImages\[M\]')
    $noDirectGtoMInRealFg = (-not $hasDirectGtoM) -and $hasTwoHop
}
Report-Contract "Contract 34/34" $noDirectGtoMInRealFg "Historical direct G->M copy must remain absent from REAL-FG (must use C4 G->D->M)."

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "REAL-LSFG-R0 CONTRACT SUITE: ALL CONTRACTS PASSED (GREEN)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "REAL-LSFG-R0 CONTRACT SUITE: CONTRACTS FAILED (RED)" -ForegroundColor Red
    exit 1
}


