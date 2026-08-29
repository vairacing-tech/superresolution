# LSFG V2B.1B Continuous 1:1 Duplicate-Frame Active Transport Contract Test
# Validates producer invariants for milestone LSFG V2B.1B.

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

# --- Detector Functions for V2B.1B ---

function Test-V2B1BModeLatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    if ($null -eq $initFn) { return $false }

    $hasEnumDecl = ($clean -match 'enum\s+class\s+V2B1Mode\s*:\s*uint32_t\s*\{[\s\S]*?Disabled\s*=\s*0[\s\S]*?SingleShot\s*=\s*1[\s\S]*?Continuous\s*=\s*2')
    $hasAtomicMode = ($clean -match 'std::atomic<V2B1Mode>\s+g_v2b1Mode')
    $hasGateLatch = ($initFn -match 'getenv\s*\(\s*"AMETHYST_LSFG_V2B1_ACTIVE"\s*\)')
    $hasModeStore = ($initFn -match 'g_v2b1Mode\s*\.\s*store')
    
    # Must NOT introduce secondary env variable AMETHYST_LSFG_V2B1B_CONTINUOUS
    $noExtraEnv = -not ($clean -match 'AMETHYST_LSFG_V2B1B_CONTINUOUS')

    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    $acquireFn = Get-CppFunctionBody $Source 'interposer_vkAcquireNextImageKHR'
    $noGetenvInHotPaths = $true
    if ($presentFn -and ($presentFn -match 'getenv\s*\(')) { $noGetenvInHotPaths = $false }
    if ($acquireFn -and ($acquireFn -match 'getenv\s*\(')) { $noGetenvInHotPaths = $false }

    return ($hasEnumDecl -and $hasAtomicMode -and $hasGateLatch -and $hasModeStore -and $noExtraEnv -and $noGetenvInHotPaths)
}

function Test-V2B1BStructures {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasSlotStruct = ($clean -match 'struct\s+TransportSlot\s*\{[\s\S]*?extraAcquireSemaphore[\s\S]*?copyFence[\s\S]*?commandBuffer')
    $hasPresentationStruct = ($clean -match 'struct\s+SwapchainImagePresentationState\s*\{[\s\S]*?generatedPresentReady[\s\S]*?realPresentReady')
    $hasTransportState = ($clean -match 'struct\s+V2B1TransportState\s*\{[\s\S]*?imagePresentation[\s\S]*?generationDisabled')

    return ($hasSlotStruct -and $hasPresentationStruct -and $hasTransportState)
}

function Test-V2B1BSlotPollingAndDeferredFenceReset {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Slot search must use getFenceStatus
    $usesGetFenceStatus = ($presentFn -match 'getFenceStatus\s*\(')
    # Must NOT reset fence inside slot search loop or before acquire
    # Check ordering: acquire must appear BEFORE resetFences
    $matchAcquire = [regex]::Match($presentFn, '(\.acquire|realAcquireNextImage)\s*\(')
    $matchResetFences = [regex]::Match($presentFn, '(\.resetFences|resetFences)\s*\(')
    $matchSubmit = [regex]::Match($presentFn, '(\.queueSubmit|realQueueSubmit)\s*\(')

    if (-not $matchAcquire.Success -or -not $matchResetFences.Success -or -not $matchSubmit.Success) {
        return $false
    }

    # Reset fences must be AFTER acquire and BEFORE submit
    $deferredFenceReset = ($matchAcquire.Index -lt $matchResetFences.Index) -and ($matchResetFences.Index -lt $matchSubmit.Index)

    return ($usesGetFenceStatus -and $deferredFenceReset)
}

function Test-V2B1BInvariantViolationHandling {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Invariant check: M == N
    $checksInvariant = ($presentFn -match 'M\s*==\s*N')
    # Must increment invariant violation counter and disable generation
    $tracksViolation = ($presentFn -match 'g_v2b1InvariantViolation|v2b1InvariantViolation')
    $disablesGeneration = ($presentFn -match 'generationDisabled\s*=\s*true')
    
    # Must NOT issue duplicate emergency presents for M==N; should pass-through N once
    # Check that in the M == N branch, we do NOT see two present calls
    $mEqualsNMatch = [regex]::Match($presentFn, 'if\s*\(\s*M\s*==\s*N[\s\S]*?\{([\s\S]*?)\}')
    $noDoublePresent = $true
    if ($mEqualsNMatch.Success) {
        $branchBody = $mEqualsNMatch.Groups[1].Value
        $presentCallsInBranch = ([regex]::Matches($branchBody, 'realFunc\s*\(')).Count
        if ($presentCallsInBranch -gt 1) { $noDoublePresent = $false }
    }

    return ($checksInvariant -and $tracksViolation -and $disablesGeneration -and $noDoublePresent)
}

function Test-V2B1BContinuousMultiEvent {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Active transport condition must check mode and generationDisabled
    $checksMode = ($presentFn -match 'V2B1Mode::Continuous|mode\s*==\s*V2B1Mode::Continuous')
    $checksGenerationDisabled = ($presentFn -match 'generationDisabled')
    # Single-shot limiter must only apply when mode is SingleShot
    $singleShotGuarded = ($presentFn -match 'V2B1Mode::SingleShot') -or ($presentFn -match '!isContinuous')

    return ($checksMode -and $checksGenerationDisabled -and $singleShotGuarded)
}

function Test-V2B1BCopyAndPresentationOrdering {
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

function Test-V2B1BSingleConsumptionSemaphores {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $submitWaitsApp = ($presentFn -match 'pWaitSemaphores') -and ($presentFn -match '(\.queueSubmit|realQueueSubmit)')
    $realPresentUsesRealReady = ($presentFn -match 'realPresentReady')

    return ($submitWaitsApp -and $realPresentUsesRealReady)
}

function Test-V2B1BPerImagePresentationSemaphores {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $indexesM = ($presentFn -match 'imagePresentation\s*\[\s*M\s*\]\s*\.\s*generatedPresentReady')
    $indexesN = ($presentFn -match 'imagePresentation\s*\[\s*N\s*\]\s*\.\s*realPresentReady')
    $dynamicSizing = ($clean -match 'imagePresentation\s*\.\s*resize\s*\(\s*(imageCount|actualImageCount)') -or ($clean -match 'imagePresentation\s*\[\s*(imageCount|actualImageCount)')

    return ($indexesM -and $indexesN -and $dynamicSizing)
}

function Test-V2B1BSummaryCounters {
    param([string]$Source)
    $summaryFn = Get-CppFunctionBody $Source 'lsfg_interposer_log_summary'
    if ($null -eq $summaryFn) { return $false }

    $requiredLabels = @(
        'v2b1Mode', 'v2b1Eligible', 'v2b1ExtraAcquireAttempt', 'v2b1ExtraAcquireSuccess',
        'v2b1ExtraAcquireNotReady', 'v2b1SlotUnavailable', 'v2b1CopySubmit',
        'v2b1GeneratedPresent', 'v2b1OriginalPresent', 'v2b1PostCommitFailure',
        'v2b1InvariantViolation', 'v2b1GenerationDisabled', 'v2b1Fallback'
    )
    foreach ($label in $requiredLabels) {
        if (-not ($summaryFn -match [regex]::Escape($label))) {
            return $false
        }
    }
    return $true
}

function Test-V2B1BZeroRealVulkanUnderMutex {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source

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

$mockValidContinuousSource = @"
enum class V2B1Mode : uint32_t {
    Disabled = 0,
    SingleShot = 1,
    Continuous = 2
};
std::atomic<V2B1Mode> g_v2b1Mode{V2B1Mode::Disabled};
std::atomic<bool> g_v2b1ActiveTransportEnabled{false};
std::atomic<bool> g_v2b1aCompleted{false};
std::atomic<uint32_t> g_v2b1SlotUnavailable{0};
std::atomic<uint32_t> g_v2b1ExtraAcquireNotReady{0};
std::atomic<uint32_t> g_v2b1InvariantViolation{0};
std::atomic<uint32_t> g_v2b1GenerationDisabled{0};

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
    bool generationDisabled{false};
    std::vector<SwapchainImagePresentationState> imagePresentation;
};

void lsfg_interposer_init(void *h) {
    const char *v = getenv("AMETHYST_LSFG_V2B1_ACTIVE");
    if (v && strcmp(v, "2") == 0) {
        g_v2b1Mode.store(V2B1Mode::Continuous);
        g_v2b1ActiveTransportEnabled.store(true);
    } else if (v && strcmp(v, "1") == 0) {
        g_v2b1Mode.store(V2B1Mode::SingleShot);
        g_v2b1ActiveTransportEnabled.store(true);
    }
}
VkResult interposer_vkCreateSwapchainKHR() {
    imagePresentation.resize(actualImageCount);
    return VK_SUCCESS;
}
VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    V2B1Mode mode = g_v2b1Mode.load(std::memory_order_relaxed);
    bool isContinuous = (mode == V2B1Mode::Continuous);
    if (mode == V2B1Mode::Disabled || (!isContinuous && g_v2b1aCompleted.load()) || transport.generationDisabled) return realFunc(queue, pPresentInfo);
    if (pPresentInfo->swapchainCount == 1 && pPresentInfo->pNext == nullptr) {
        VkResult fRes = transport.getFenceStatus(transport.device, slot.copyFence);
        if (fRes != VK_SUCCESS) return realFunc(queue, pPresentInfo);
        VkResult resAcq = transport.acquire(device, swapchain, 0, slot.extraAcquireSemaphore, 0, &M);
        if (resAcq == VK_NOT_READY || resAcq == VK_TIMEOUT) return realFunc(queue, pPresentInfo);
        if (M == N || M >= transport.imageCount) {
            g_v2b1InvariantViolation.fetch_add(1);
            transport.generationDisabled = true;
            return realFunc(queue, pPresentInfo);
        }
        realCmdCopyImage();
        transport.resetFences(transport.device, 1, &slot.copyFence);
        VkSubmitInfo submitInfo{};
        submitInfo.pWaitSemaphores = pPresentInfo->pWaitSemaphores;
        realQueueSubmit(queue, 1, &submitInfo, slot.copyFence);
        if (mode == V2B1Mode::SingleShot) g_v2b1aCompleted.store(true);
        VkPresentInfoKHR piM{};
        piM.pWaitSemaphores = &imagePresentation[M].generatedPresentReady;
        realQueuePresent(queue, &piM);
        VkPresentInfoKHR piN{};
        piN.pResults = pPresentInfo->pResults;
        piN.pWaitSemaphores = &imagePresentation[N].realPresentReady;
        VkResult resN = realQueuePresent(queue, &piN);
        return resN;
    }
    return realFunc(queue, pPresentInfo);
}
void lsfg_interposer_log_summary() {
    printf("v2b1Mode=0 v2b1Eligible=0 v2b1ExtraAcquireAttempt=0 v2b1ExtraAcquireSuccess=0 v2b1ExtraAcquireNotReady=0 v2b1SlotUnavailable=0 v2b1CopySubmit=0 v2b1GeneratedPresent=0 v2b1OriginalPresent=0 v2b1PostCommitFailure=0 v2b1InvariantViolation=0 v2b1GenerationDisabled=0 v2b1Fallback=0");
}
"@

Run-SelfCheck "mode latch detector accepts V2B1Mode enum and AMETHYST_LSFG_V2B1_ACTIVE" (Test-V2B1BModeLatch $mockValidContinuousSource)
Run-SelfCheck "structures detector accepts generationDisabled field" (Test-V2B1BStructures $mockValidContinuousSource)
Run-SelfCheck "slot polling detector accepts getFenceStatus and deferred fence reset" (Test-V2B1BSlotPollingAndDeferredFenceReset $mockValidContinuousSource)
Run-SelfCheck "invariant detector accepts M==N check and single present pass-through" (Test-V2B1BInvariantViolationHandling $mockValidContinuousSource)
Run-SelfCheck "continuous multi-event detector accepts mode branching and generationDisabled check" (Test-V2B1BContinuousMultiEvent $mockValidContinuousSource)
Run-SelfCheck "ordering detector verifies Acquire -> CopySubmit -> Present M -> Present N" (Test-V2B1BCopyAndPresentationOrdering $mockValidContinuousSource)
Run-SelfCheck "summary detector accepts all required V2B.1B continuous telemetry counters" (Test-V2B1BSummaryCounters $mockValidContinuousSource)

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

Run-Check "AMETHYST_LSFG_V2B1_ACTIVE single gate latch (0/1/2) with V2B1Mode enum" (Test-V2B1BModeLatch $producerSrc)
Run-Check "separated TransportSlot and SwapchainImagePresentationState with generationDisabled" (Test-V2B1BStructures $producerSrc)
Run-Check "non-blocking slot polling with vkGetFenceStatus and deferred fence reset" (Test-V2B1BSlotPollingAndDeferredFenceReset $producerSrc)
Run-Check "M==N invariant violation handling (zero double presents, generation disabled)" (Test-V2B1BInvariantViolationHandling $producerSrc)
Run-Check "continuous active multi-event execution guarded by mode and generationDisabled" (Test-V2B1BContinuousMultiEvent $producerSrc)
Run-Check "presentation ordering: Copy N->M -> RealPresent M -> RealPresent N" (Test-V2B1BCopyAndPresentationOrdering $producerSrc)
Run-Check "single-consumption of application wait semaphores by copy submit" (Test-V2B1BSingleConsumptionSemaphores $producerSrc)
Run-Check "per-image indexed presentation semaphores with dynamic actualImageCount sizing" (Test-V2B1BPerImagePresentationSemaphores $producerSrc)
Run-Check "all required V2B.1B continuous telemetry counters present in lsfg_interposer_log_summary" (Test-V2B1BSummaryCounters $producerSrc)
Run-Check "zero real Vulkan driver calls under g_stateMutex" (Test-V2B1BZeroRealVulkanUnderMutex $producerSrc)

Write-Output "`nSUMMARY checks=$($checksPassed + $checksFailed) failures=$checksFailed"
if ($checksFailed -gt 0) {
    Write-Output "V2B.1B CONTRACT: FAIL"
    exit 1
} else {
    Write-Output "V2B.1B CONTRACT: PASS"
    exit 0
}
