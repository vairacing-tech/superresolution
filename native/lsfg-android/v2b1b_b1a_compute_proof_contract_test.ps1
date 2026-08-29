# ==============================================================================
# LSFG V2B.1B Phase B1A Vulkan Generated-Image Compute Proof Contract Test
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

function Test-B1AGateDefinition {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasProofGate = ($clean -match 'AMETHYST_LSFG_B1_COMPUTE_PROOF') -and ($clean -match 'g_b1ComputeProof|g_b1aComputeProof')
    $hasMaxActive = ($clean -match 'AMETHYST_LSFG_B1_COMPUTE_PROOF_MAX_ACTIVE') -and ($clean -match 'g_b1ComputeProofMaxActive|g_b1aComputeProofMaxActive')
    $hasCounters = ($clean -match 'g_b1ComputeEligible|g_b1ComputeDispatch|g_b1ComputeCopyToM')
    return ($hasProofGate -and $hasMaxActive -and $hasCounters)
}

function Test-B1APerSlotGeneratedImageResource {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $destroyFn = Get-CppFunctionBody $Source 'interposer_vkDestroySwapchainKHR'
    if ($null -eq $createFn -or $null -eq $destroyFn) { return $false }

    $hasSlotMembers = ($clean -match 'VkImage\s+generatedImage') -and
                      ($clean -match 'VkDeviceMemory\s+generatedImageMemory') -and
                      ($clean -match 'VkImageView\s+generatedImageView')
    
    $hasUsage = ($clean -match 'VK_IMAGE_USAGE_STORAGE_BIT\s*\|\s*VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT\s*\|\s*VK_IMAGE_USAGE_STORAGE_BIT')
    $hasPerSlotLoop = ($createFn -match 'slots\[s\]\.generatedImage|transport\.slots\[s\]\.generatedImage|slot\.generatedImage')
    $hasDestroyLoop = ($destroyFn -match 'slots\[s\]\.generatedImage|transport\.slots\[s\]\.generatedImage|slot\.generatedImage')

    return ($hasSlotMembers -and $hasUsage -and $hasPerSlotLoop -and $hasDestroyLoop)
}

function Test-B1AComputePipelineAndTopology {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $destroyFn = Get-CppFunctionBody $Source 'interposer_vkDestroySwapchainKHR'
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $createFn -or $null -eq $destroyFn -or $null -eq $presentFn) { return $false }

    $hasPipelineCreation = ($createFn -match 'vkCreateComputePipelines|devStateCopy\.createComputePipelines|transport\.createComputePipelines')
    $hasPipelineDestruction = ($destroyFn -match 'vkDestroyPipeline|devStateCopy\.destroyPipeline|transportToDestroy\.destroyPipeline|transport\.destroyPipeline')
    $hasDispatch = ($presentFn -match 'vkCmdDispatch|transport\.cmdDispatch')
    $hasCopyGtoM = ($presentFn -match 'cmdCopyImage|vkCmdCopyImage') -and ($presentFn -match 'generatedImage')
    $hasFallback = ($presentFn -match 'b1ComputeFallback|b1Fallback') -or ($presentFn -match 'isB1Active')

    return ($hasPipelineCreation -and $hasPipelineDestruction -and $hasDispatch -and $hasCopyGtoM -and $hasFallback)
}

# --- Self Check ---
$fakeSourceGood = @'
static std::atomic<int> g_b1ComputeProof{0};
static std::atomic<int> g_b1ComputeProofMaxActive{0};
static std::atomic<uint64_t> g_b1ComputeEligible{0};
static std::atomic<uint64_t> g_b1ComputeDispatch{0};
static std::atomic<uint64_t> g_b1ComputeCopyToM{0};

struct TransportSlot {
    VkImage generatedImage = VK_NULL_HANDLE;
    VkDeviceMemory generatedImageMemory = VK_NULL_HANDLE;
    VkImageView generatedImageView = VK_NULL_HANDLE;
    VkDescriptorSet generatedDescriptorSet = VK_NULL_HANDLE;
    VkCommandBuffer acquireBridgeCommandBuffer = VK_NULL_HANDLE;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkFence copyFence = VK_NULL_HANDLE;
};

void init() {
    const char *e1 = getenv("AMETHYST_LSFG_B1_COMPUTE_PROOF");
    const char *e2 = getenv("AMETHYST_LSFG_B1_COMPUTE_PROOF_MAX_ACTIVE");
}

VkResult interposer_vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR* pCreateInfo, const VkAllocationCallbacks* pAllocator, VkSwapchainKHR* pSwapchain) {
    VkImageCreateInfo imgInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    imgInfo.usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    for (uint32_t s = 0; s < 2; ++s) {
        devStateCopy.createImage(device, &imgInfo, nullptr, &transport.slots[s].generatedImage);
    }
    devStateCopy.createComputePipelines(device, VK_NULL_HANDLE, 1, &pipeInfo, nullptr, &transport.computePipeline);
    return VK_SUCCESS;
}

void interposer_vkDestroySwapchainKHR(VkDevice device, VkSwapchainKHR swapchain, const VkAllocationCallbacks* pAllocator) {
    for (uint32_t s = 0; s < 2; ++s) {
        devStateCopy.destroyImage(device, transport.slots[s].generatedImage, nullptr);
    }
    devStateCopy.destroyPipeline(device, transport.computePipeline, nullptr);
}

VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* pPresentInfo) {
    if (isB1Active) {
        transport.cmdDispatch(cmdBuf, gx, gy, 1);
        transport.cmdCopyImage(cmdBuf, slot.generatedImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, images[M], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    } else {
        g_b1ComputeFallback.fetch_add(1, std::memory_order_relaxed);
    }
    return VK_SUCCESS;
}
'@

if (-not (Test-B1AGateDefinition $fakeSourceGood)) { throw "Self-check failed: Test-B1AGateDefinition" }
if (-not (Test-B1APerSlotGeneratedImageResource $fakeSourceGood)) { throw "Self-check failed: Test-B1APerSlotGeneratedImageResource" }
if (-not (Test-B1AComputePipelineAndTopology $fakeSourceGood)) { throw "Self-check failed: Test-B1AComputePipelineAndTopology" }
Write-Host "SELF-CHECK PASS B1A compute proof detector validated against synthetic models"

# --- Producer Test ---
$checks = 0
$failures = 0

if (-not (Test-Path $ProducerSource)) {
    Write-Error "Producer source not found: $ProducerSource"
    exit 1
}
$producerContent = [System.IO.File]::ReadAllText($ProducerSource)

$checks++
if (Test-B1AGateDefinition $producerContent) {
    Write-Host "PASS [producer] B1A feature gate and diagnostics counters defined"
} else {
    Write-Host "FAIL [producer] B1A feature gate and diagnostics counters defined"
    $failures++
}

$checks++
if (Test-B1APerSlotGeneratedImageResource $producerContent) {
    Write-Host "PASS [producer] Per-slot intermediate generated image G allocated with STORAGE and TRANSFER_SRC"
} else {
    Write-Host "FAIL [producer] Per-slot intermediate generated image G allocated with STORAGE and TRANSFER_SRC"
    $failures++
}

$checks++
if (Test-B1AComputePipelineAndTopology $producerContent) {
    Write-Host "PASS [producer] Compute pipeline, dispatch G, and Copy G -> M topology with fallback"
} else {
    Write-Host "FAIL [producer] Compute pipeline, dispatch G, and Copy G -> M topology with fallback"
    $failures++
}

Write-Host ""
Write-Host ("SUMMARY checks={0} failures={1}" -f $checks, $failures)
if ($failures -eq 0) {
    Write-Host "V2B.1B B1A COMPUTE PROOF CONTRACT: PASS"
    exit 0
} else {
    Write-Host "V2B.1B B1A COMPUTE PROOF CONTRACT: FAIL"
    exit 1
}
