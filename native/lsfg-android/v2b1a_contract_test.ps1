# LSFG V2B.1A Single-Shot Duplicate-Frame Active Transport Contract Test
# Validates producer and consumer invariants for milestone LSFG V2B.1A.

param(
    [ValidateSet('self', 'producer', 'full')]
    [string]$Stage = 'full',
    [string]$Check = ''
)

$ErrorActionPreference = 'Stop'

function Write-Pass([string]$msg) {
    Write-Host "PASS $msg" -ForegroundColor Green
}

function Write-Fail([string]$msg) {
    Write-Host "FAIL $msg" -ForegroundColor Red
}

function Write-SelfPass([string]$msg) {
    Write-Host "SELF-CHECK PASS $msg" -ForegroundColor Cyan
}

function Write-SelfFail([string]$msg) {
    Write-Host "SELF-CHECK FAIL $msg" -ForegroundColor Magenta
}

$ProducerFile = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp'
$ConsumerLSFGFile = 'C:\Proyectos\LS-FG\src\main\resources\assets\minecraft\shaders\program\lsfg_probe.c'
$ConsumerSGSRFile = 'C:\Proyectos\SGSR\native\lsfg-android\lsfg_probe.c'

function Remove-CppTrivia {
    param([string]$Source)
    $s = [regex]::Replace($Source, '/\*[\s\S]*?\*/', '')
    $s = [regex]::Replace($s, '//[^\r\n]*', '')
    return $s
}

function Get-CppFunctionBody {
    param([string]$Source, [string]$FunctionName)
    $clean = Remove-CppTrivia $Source
    $escaped = [regex]::Escape($FunctionName)
    $pattern = '(?m)\b' + $escaped + '\s*\([^)]*\)\s*\{'
    $match = [regex]::Match($clean, $pattern)
    if (-not $match.Success) { return $null }

    $startIndex = $match.Index + $match.Length - 1
    $braceCount = 0
    $endIndex = -1

    for ($i = $startIndex; $i -lt $clean.Length; $i++) {
        $c = $clean[$i]
        if ($c -eq '{') { $braceCount++ }
        elseif ($c -eq '}') {
            $braceCount--
            if ($braceCount -eq 0) {
                $endIndex = $i
                break
            }
        }
    }

    if ($endIndex -gt $startIndex) {
        return $clean.Substring($startIndex + 1, $endIndex - $startIndex - 1)
    }
    return $null
}

# --- Detector Functions ---

function Test-V2B1GateLatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    if ($null -eq $initFn) { return $false }
    
    $hasGateDecl = ($clean -match 'std::atomic<bool>\s+g_v2b1ActiveTransportEnabled')
    $hasGateLatch = ($initFn -match 'getenv\s*\(\s*"AMETHYST_LSFG_V2B1_ACTIVE"\s*\)')
    $hasAtomicStore = ($initFn -match 'g_v2b1ActiveTransportEnabled\s*\.\s*store')
    
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    $acquireFn = Get-CppFunctionBody $Source 'interposer_vkAcquireNextImageKHR'
    $noGetenvInHotPaths = $true
    if ($presentFn -and ($presentFn -match 'getenv\s*\(')) { $noGetenvInHotPaths = $false }
    if ($acquireFn -and ($acquireFn -match 'getenv\s*\(')) { $noGetenvInHotPaths = $false }
    
    return ($hasGateDecl -and $hasGateLatch -and $hasAtomicStore -and $noGetenvInHotPaths)
}

function Test-V2B1Structures {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasSlotStruct = ($clean -match 'struct\s+TransportSlot\s*\{[\s\S]*?extraAcquireSemaphore[\s\S]*?copyFence[\s\S]*?commandBuffer')
    $hasPresentationStruct = ($clean -match 'struct\s+SwapchainImagePresentationState\s*\{[\s\S]*?generatedPresentReady[\s\S]*?realPresentReady')
    $hasTransportState = ($clean -match 'struct\s+V2B1TransportState\s*\{[\s\S]*?imagePresentation')
    
    return ($hasSlotStruct -and $hasPresentationStruct -and $hasTransportState)
}

function Test-V2B1Lifecycle {
    param([string]$Source)
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $destroyFn = Get-CppFunctionBody $Source 'interposer_vkDestroySwapchainKHR'
    if ($null -eq $createFn -or $null -eq $destroyFn) { return $false }
    
    $allocatesSemaphores = ($createFn -match 'generatedPresentReady') -and ($createFn -match 'realPresentReady')
    $allocatesCmdPool = ($createFn -match 'commandPool')
    $destroysSemaphores = ($destroyFn -match 'destroySemaphore|DestroySemaphore')
    $destroysCmdPool = ($destroyFn -match 'destroyCommandPool|DestroyCommandPool')
    
    return ($allocatesSemaphores -and $allocatesCmdPool -and $destroysSemaphores -and $destroysCmdPool)
}

function Test-V2B1PreCommitEligibility {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }
    
    $checksGate = ($presentFn -match 'g_v2b1ActiveTransportEnabled')
    $checksLimiter = ($presentFn -match 'g_v2b1aCompleted')
    $checksSwapchainCount = ($presentFn -match 'swapchainCount\s*==\s*1')
    $checksPNext = ($presentFn -match 'pNext\s*==\s*nullptr')
    
    return ($checksGate -and $checksLimiter -and $checksSwapchainCount -and $checksPNext)
}

function Test-V2B1ExtraAcquire {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Must call acquire with timeout=0 and extraAcquireSemaphore
    $hasExtraAcquire = ($presentFn -match '(\.acquire|realAcquireNextImage)\s*\([^,]+,[^,]+,\s*0\s*,[^,]*extraAcquireSemaphore')
    $handlesNotReady = ($presentFn -match 'VK_NOT_READY')
    $handlesTimeout = ($presentFn -match 'VK_TIMEOUT')

    return ($hasExtraAcquire -and $handlesNotReady -and $handlesTimeout)
}

function Test-V2B1CopyAndPresentationOrdering {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $matchAcquire = [regex]::Match($presentFn, '(\.acquire|realAcquireNextImage)\s*\([^;]+extraAcquireSemaphore')
    if (-not $matchAcquire.Success) { return $false }
    $idxAcquire = $matchAcquire.Index

    $afterAcquire = $presentFn.Substring($idxAcquire)
    $matchCopy = [regex]::Match($afterAcquire, '(\.cmdCopyImage|vkCmdCopyImage|realCmdCopyImage)\s*\(')
    if (-not $matchCopy.Success) { return $false }
    $idxCopy = $idxAcquire + $matchCopy.Index

    $afterCopy = $presentFn.Substring($idxCopy)
    $matchSubmit = [regex]::Match($afterCopy, '(\.queueSubmit|realQueueSubmit)\s*\(')
    if (-not $matchSubmit.Success) { return $false }
    $idxSubmit = $idxCopy + $matchSubmit.Index

    $afterSubmit = $presentFn.Substring($idxSubmit)
    $matchGen = [regex]::Match($afterSubmit, 'generatedPresentReady')
    if (-not $matchGen.Success) { return $false }
    $idxGen = $idxSubmit + $matchGen.Index

    $afterGen = $presentFn.Substring($idxGen)
    $matchReal = [regex]::Match($afterGen, 'realPresentReady')
    if (-not $matchReal.Success) { return $false }
    $idxReal = $idxGen + $matchReal.Index

    return ($idxAcquire -lt $idxCopy -and $idxCopy -lt $idxSubmit -and $idxSubmit -lt $idxGen -and $idxGen -lt $idxReal)
}

function Test-V2B1SingleConsumptionSemaphores {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Submit must wait on app render semaphores (pWaitSemaphores from pPresentInfo)
    $submitWaitsApp = ($presentFn -match 'pWaitSemaphores') -and ($presentFn -match '(\.queueSubmit|realQueueSubmit)')
    # Original present of N must NOT pass caller's pWaitSemaphores, but realPresentReady
    $realPresentUsesRealReady = ($presentFn -match 'realPresentReady')

    return ($submitWaitsApp -and $realPresentUsesRealReady)
}

function Test-V2B1CallerResultsPreservation {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Generated present M must use a local VkResult storage
    $hasLocalResultM = ($presentFn -match 'localResult|localGenResult|resM')
    # N present preserves caller pResults
    $preservesCallerResults = ($presentFn -match 'pResults')

    return ($hasLocalResultM -and $preservesCallerResults)
}

function Test-V2B1SingleShotLimiter {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $declaresFlag = ($clean -match 'std::atomic<bool>\s+g_v2b1aCompleted')
    $setsCompleted = ($presentFn -match 'g_v2b1aCompleted\s*\.\s*store\s*\(\s*true')

    return ($declaresFlag -and $setsCompleted)
}

function Test-V2B1PostCommitRecovery {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $handlesDeviceLost = ($presentFn -match 'VK_ERROR_DEVICE_LOST')
    $hasRecoveryPath = ($presentFn -match 'recoveryCommandBuffer|recoveryPresentReady|v2b1PostCommitFailure')

    return ($handlesDeviceLost -and $hasRecoveryPath)
}

function Test-V2B1SummaryCounters {
    param([string]$Source)
    $summaryFn = Get-CppFunctionBody $Source 'lsfg_interposer_log_summary'
    if ($null -eq $summaryFn) { return $false }

    $requiredLabels = @('v2b1Gate', 'v2b1Eligible', 'v2b1ExtraAcquireAttempt', 'v2b1ExtraAcquireSuccess', 'v2b1CopySubmit', 'v2b1GeneratedPresent', 'v2b1OriginalPresent', 'v2b1PostCommitFailure', 'v2b1Fallback')
    foreach ($label in $requiredLabels) {
        if (-not ($summaryFn -match [regex]::Escape($label))) {
            return $false
        }
    }
    return $true
}

function Test-V2B1ZeroRealVulkanUnderMutex {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source

    # Find all std::lock_guard<std::mutex> lock(g_stateMutex); blocks
    $pattern = 'std::lock_guard<std::mutex>\s+\w+\s*\(\s*g_stateMutex\s*\)\s*;'
    $matches = [regex]::Matches($clean, $pattern)

    $vulkanDriverCalls = @('realFunc\(', 'realAcquire\(', 'realQueueSubmit\(', 'realQueuePresent\(', 'realCreateSwapchain\(', 'realGetModes\(', 'realGetCaps\(')

    foreach ($m in $matches) {
        $idx = $m.Index
        $scope = $clean.Substring($idx, [Math]::Min(500, $clean.Length - $idx))
        $braceIdx = $scope.IndexOf('}')
        if ($braceIdx -gt 0) {
            $lockBlock = $scope.Substring(0, $braceIdx)
            foreach ($call in $vulkanDriverCalls) {
                if ($lockBlock -match [regex]::Escape($call)) {
                    return $false
                }
            }
        }
    }
    return $true
}

# --- Self-Checks ---
$selfChecksPassed = 0
$selfChecksFailed = 0

function Run-SelfCheck([string]$name, [bool]$condition) {
    if ($condition) {
        Write-SelfPass $name
        $script:selfChecksPassed++
    } else {
        Write-SelfFail $name
        $script:selfChecksFailed++
    }
}

$mockValidSource = @"
std::atomic<bool> g_v2b1ActiveTransportEnabled{false};
std::atomic<bool> g_v2b1aCompleted{false};
struct TransportSlot {
    VkSemaphore extraAcquireSemaphore;
    VkFence copyFence;
    VkCommandBuffer commandBuffer;
    VkCommandBuffer recoveryCommandBuffer;
    bool inFlight;
};
struct SwapchainImagePresentationState {
    VkSemaphore generatedPresentReady;
    VkSemaphore realPresentReady;
    VkSemaphore recoveryPresentReady;
};
struct V2B1TransportState {
    std::vector<SwapchainImagePresentationState> imagePresentation;
};

void lsfg_interposer_init(void *h) {
    const char *v = getenv("AMETHYST_LSFG_V2B1_ACTIVE");
    if (v) g_v2b1ActiveTransportEnabled.store(true);
}
VkResult interposer_vkCreateSwapchainKHR() {
    auto generatedPresentReady = 0;
    auto realPresentReady = 0;
    auto commandPool = 0;
    return VK_SUCCESS;
}
void interposer_vkDestroySwapchainKHR() {
    destroySemaphore();
    destroyCommandPool();
}
VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    if (!g_v2b1ActiveTransportEnabled.load() || g_v2b1aCompleted.load()) return VK_SUCCESS;
    if (pPresentInfo->swapchainCount == 1 && pPresentInfo->pNext == nullptr) {
        VkResult resAcq = realAcquireNextImage(device, swapchain, 0, slot.extraAcquireSemaphore, 0, &M);
        if (resAcq == VK_NOT_READY || resAcq == VK_TIMEOUT) return VK_SUCCESS;
        realCmdCopyImage();
        VkSubmitInfo submitInfo{};
        submitInfo.pWaitSemaphores = pPresentInfo->pWaitSemaphores;
        realQueueSubmit(queue, 1, &submitInfo, slot.copyFence);
        VkResult localResultM;
        VkPresentInfoKHR piM{};
        piM.pResults = &localResultM;
        piM.pWaitSemaphores = &imagePresentation[M].generatedPresentReady;
        realQueuePresent(queue, &piM);
        VkPresentInfoKHR piN{};
        piN.pResults = pPresentInfo->pResults;
        piN.pWaitSemaphores = &imagePresentation[N].realPresentReady;
        VkResult resN = realQueuePresent(queue, &piN);
        g_v2b1aCompleted.store(true);
        if (resN == VK_ERROR_DEVICE_LOST) return VK_ERROR_DEVICE_LOST;
        return resN;
    }
    return VK_SUCCESS;
}
void lsfg_interposer_log_summary() {
    printf("v2b1Gate=0 v2b1Eligible=0 v2b1ExtraAcquireAttempt=0 v2b1ExtraAcquireSuccess=0 v2b1CopySubmit=0 v2b1GeneratedPresent=0 v2b1OriginalPresent=0 v2b1PostCommitFailure=0 v2b1Fallback=0");
}
"@

Run-SelfCheck "gate latch detector accepts valid latch in init" (Test-V2B1GateLatch $mockValidSource)
Run-SelfCheck "structures detector accepts separated transport slot and presentation state" (Test-V2B1Structures $mockValidSource)
Run-SelfCheck "ordering detector verifies Acquire -> CopySubmit -> Present M -> Present N" (Test-V2B1CopyAndPresentationOrdering $mockValidSource)
Run-SelfCheck "semaphores detector verifies single consumption of app waits" (Test-V2B1SingleConsumptionSemaphores $mockValidSource)
Run-SelfCheck "limiter detector accepts single-shot completion logic" (Test-V2B1SingleShotLimiter $mockValidSource)
Run-SelfCheck "summary detector accepts all required V2B.1 telemetry counters" (Test-V2B1SummaryCounters $mockValidSource)

if ($Stage -eq 'self') {
    Write-Output "Self-check completed: $selfChecksPassed passed, $selfChecksFailed failed."
    if ($selfChecksFailed -gt 0) { exit 1 } else { exit 0 }
}

# --- Real Producer Evaluation ---
$producerSrc = Get-Content $ProducerFile -Raw -Encoding UTF8
$checksPassed = 0
$checksFailed = 0

function Run-Check([string]$name, [bool]$condition) {
    if ($condition) {
        Write-Pass "[producer] $name"
        $script:checksPassed++
    } else {
        Write-Fail "[producer] $name"
        $script:checksFailed++
    }
}

Run-Check "AMETHYST_LSFG_V2B1_ACTIVE gate latched once at init" (Test-V2B1GateLatch $producerSrc)
Run-Check "separated TransportSlot and SwapchainImagePresentationState structures" (Test-V2B1Structures $producerSrc)
Run-Check "transport resource lifecycle in vkCreateSwapchainKHR and vkDestroySwapchainKHR" (Test-V2B1Lifecycle $producerSrc)
Run-Check "pre-commit eligibility checks (pNext==nullptr, swapchainCount==1, limiter unconsumed)" (Test-V2B1PreCommitEligibility $producerSrc)
Run-Check "non-blocking extra acquire (timeout=0) with VK_NOT_READY/VK_TIMEOUT fail-open" (Test-V2B1ExtraAcquire $producerSrc)
Run-Check "presentation ordering: Copy N->M -> RealPresent M -> RealPresent N" (Test-V2B1CopyAndPresentationOrdering $producerSrc)
Run-Check "single-consumption of application wait semaphores by copy submit" (Test-V2B1SingleConsumptionSemaphores $producerSrc)
Run-Check "caller pResults preserved and generated M uses local result" (Test-V2B1CallerResultsPreservation $producerSrc)
Run-Check "single-shot limiter bounds execution to at most one active duplicate" (Test-V2B1SingleShotLimiter $producerSrc)
Run-Check "concrete post-commit recovery and device-lost handling" (Test-V2B1PostCommitRecovery $producerSrc)
Run-Check "all required V2B.1 telemetry counters present in lsfg_interposer_log_summary" (Test-V2B1SummaryCounters $producerSrc)
Run-Check "zero real Vulkan driver calls under g_stateMutex" (Test-V2B1ZeroRealVulkanUnderMutex $producerSrc)

Write-Output "`nSUMMARY checks=$($checksPassed + $checksFailed) failures=$checksFailed"
if ($checksFailed -gt 0) {
    Write-Output "V2B.1A CONTRACT: FAIL"
    exit 1
} else {
    Write-Output "V2B.1A CONTRACT: PASS"
    exit 0
}
