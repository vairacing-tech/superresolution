# LSFG V2B.1B Event #2 Extra-Acquire Bridge Diagnostic Contract Test
# Validates extra-acquire bridge diagnostic gating, preallocation, Event 2 execution (Bridge + Copy with app waits), and logging.

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

function Test-V2B1BAcquireBridgeLatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    if ($null -eq $initFn) { return $false }

    $hasAtomicDecl = ($clean -match 'std::atomic<bool>\s+g_v2b1DiagExtraAcquireBridge') -or ($clean -match 'std::atomic<uint32_t>\s+g_v2b1DiagExtraAcquireBridge')
    $hasLatch = ($initFn -match 'getenv\s*\(\s*"AMETHYST_LSFG_V2B1_DIAG_EXTRA_ACQUIRE_BRIDGE"\s*\)')
    $hasStore = ($initFn -match 'g_v2b1DiagExtraAcquireBridge\s*\.\s*store')

    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    $noGetenvInPresent = $true
    if ($presentFn -and ($presentFn -match 'getenv\s*\(')) { $noGetenvInPresent = $false }

    return ($hasAtomicDecl -and $hasLatch -and $hasStore -and $noGetenvInPresent)
}

function Test-V2B1BAcquireBridgePreallocation {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $createSwapchainFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $destroySwapchainFn = Get-CppFunctionBody $Source 'interposer_vkDestroySwapchainKHR'
    if ($null -eq $createSwapchainFn -or $null -eq $destroySwapchainFn) { return $false }

    $hasSlotMembers = ($clean -match 'VkSemaphore\s+acquireReadySemaphore') -or ($clean -match 'VkSemaphore\s+acquireChainReadySemaphore')
    $hasCmdMember = ($clean -match 'VkCommandBuffer\s+diagAcquireReadyCommandBuffer')
    $hasCreate = ($createSwapchainFn -match 'acquireReadySemaphore|acquireChainReadySemaphore')
    $hasDestroy = ($destroySwapchainFn -match 'acquireReadySemaphore|acquireChainReadySemaphore')

    return ($hasSlotMembers -and $hasCmdMember -and $hasCreate -and $hasDestroy)
}

function Test-V2B1BAcquireBridgeExecution {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasBridgeCheck = ($clean -match 'g_v2b1DiagExtraAcquireBridge') -and ($clean -match 'currentDiagEvent\s*==\s*2|event\s*==\s*2|diagActive\s*==\s*1')
    $hasBridgeLog = ($clean -match '\[LSFG-V2B1-ACQBRIDGE\]') -and ($clean -match 'ACQUIRE_BRIDGE')
    $hasCopyLog = ($clean -match '\[LSFG-V2B1-ACQBRIDGE\]') -and ($clean -match 'COPY')
    $hasAppWaitsInCopy = ($clean -match 'pPresentInfo->pWaitSemaphores')
    $hasAcquireReadyInCopy = ($clean -match 'acquireReadySemaphore|acquireChainReadySemaphore')

    return ($hasBridgeCheck -and $hasBridgeLog -and $hasCopyLog -and $hasAppWaitsInCopy -and $hasAcquireReadyInCopy)
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

$mockValidAcquireBridgeSource = @"
struct TransportSlot {
    VkSemaphore extraAcquireSemaphore = VK_NULL_HANDLE;
    VkSemaphore acquireReadySemaphore = VK_NULL_HANDLE;
    VkFence copyFence = VK_NULL_HANDLE;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkCommandBuffer diagAcquireReadyCommandBuffer = VK_NULL_HANDLE;
};
std::atomic<bool> g_v2b1DiagExtraAcquireBridge{false};

void lsfg_interposer_init(void *h) {
    const char *s = getenv("AMETHYST_LSFG_V2B1_DIAG_EXTRA_ACQUIRE_BRIDGE");
    if (s) {
        g_v2b1DiagExtraAcquireBridge.store(true);
    }
}
VkResult interposer_vkCreateSwapchainKHR(VkDevice d, const VkSwapchainCreateInfoKHR *c, const VkAllocationCallbacks *a, VkSwapchainKHR *s) {
    devStateCopy.createSemaphore(device, &semInfo, nullptr, &transport.slots[s].acquireReadySemaphore);
    return VK_SUCCESS;
}
void interposer_vkDestroySwapchainKHR(VkDevice d, VkSwapchainKHR s, const VkAllocationCallbacks *a) {
    transportToDestroy.destroySemaphore(transportToDestroy.device, slot.acquireReadySemaphore, nullptr);
}
VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    bool bridgeDiag = g_v2b1DiagExtraAcquireBridge.load(std::memory_order_relaxed);
    uint32_t currentDiagEvent = diagActive + 1;
    if (bridgeDiag && currentDiagEvent == 2) {
        LOGI("[LSFG-V2B1-ACQBRIDGE] event=2 phase=ACQUIRE_BRIDGE wait=0x%lx signal=0x%lx", extraAcquire, acquireReady);
        VkResult resBridge = transport.queueSubmit(queue, 1, &submitInfoBridge, VK_NULL_HANDLE);
        LOGI("[LSFG-V2B1-ACQBRIDGE] event=2 phase=ACQUIRE_BRIDGE submitRes=%d", resBridge);

        submitInfoCopy.pWaitSemaphores = pPresentInfo->pWaitSemaphores;
        LOGI("[LSFG-V2B1-ACQBRIDGE] event=2 phase=COPY appWaitCount=%u acquireReadySemaphore=0x%lx", pPresentInfo->waitSemaphoreCount, slot.acquireReadySemaphore);
        VkResult resCopy = transport.queueSubmit(queue, 1, &submitInfoCopy, slot.copyFence);
        LOGI("[LSFG-V2B1-ACQBRIDGE] event=2 phase=COPY submitRes=%d", resCopy);
    }
    return VK_SUCCESS;
}
"@

Run-SelfCheck "acquirebridge latch detector accepts AMETHYST_LSFG_V2B1_DIAG_EXTRA_ACQUIRE_BRIDGE" (Test-V2B1BAcquireBridgeLatch $mockValidAcquireBridgeSource)
Run-SelfCheck "acquirebridge preallocation detector accepts acquireReadySemaphore" (Test-V2B1BAcquireBridgePreallocation $mockValidAcquireBridgeSource)
Run-SelfCheck "acquirebridge execution detector accepts Bridge and Copy submissions with logging" (Test-V2B1BAcquireBridgeExecution $mockValidAcquireBridgeSource)

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

Run-Check "AMETHYST_LSFG_V2B1_DIAG_EXTRA_ACQUIRE_BRIDGE latch at init with default false" (Test-V2B1BAcquireBridgeLatch $producerSrc)
Run-Check "acquireReadySemaphore preallocated and destroyed" (Test-V2B1BAcquireBridgePreallocation $producerSrc)
Run-Check "Event #2 extra-acquire bridge submission (Bridge extraAcquire -> Copy with appWaits + acquireReady) with [LSFG-V2B1-ACQBRIDGE] logs" (Test-V2B1BAcquireBridgeExecution $producerSrc)

Write-Output "`nSUMMARY checks=$($checksPassed + $checksFailed) failures=$checksFailed"
if ($checksFailed -gt 0) {
    Write-Output "V2B.1B ACQUIRE-BRIDGE DIAG CONTRACT: FAIL"
    exit 1
} else {
    Write-Output "V2B.1B ACQUIRE-BRIDGE DIAG CONTRACT: PASS"
    exit 0
}
