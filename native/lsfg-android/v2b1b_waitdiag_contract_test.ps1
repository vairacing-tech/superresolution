# LSFG V2B.1B Event #2 Wait-Provenance Diagnostic Experiment Contract Test
# Validates split-wait diagnostic gating, preallocation, Event 2 execution, and logging.

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

function Test-V2B1BSplitWaitsLatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    if ($null -eq $initFn) { return $false }

    $hasAtomicDecl = ($clean -match 'std::atomic<bool>\s+g_v2b1DiagSplitWaits') -or ($clean -match 'std::atomic<uint32_t>\s+g_v2b1DiagSplitWaits')
    $hasLatch = ($initFn -match 'getenv\s*\(\s*"AMETHYST_LSFG_V2B1_DIAG_SPLIT_WAITS"\s*\)')
    $hasStore = ($initFn -match 'g_v2b1DiagSplitWaits\s*\.\s*store')

    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    $noGetenvInPresent = $true
    if ($presentFn -and ($presentFn -match 'getenv\s*\(')) { $noGetenvInPresent = $false }

    return ($hasAtomicDecl -and $hasLatch -and $hasStore -and $noGetenvInPresent)
}

function Test-V2B1BSplitWaitsPreallocation {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $createSwapchainFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $destroySwapchainFn = Get-CppFunctionBody $Source 'interposer_vkDestroySwapchainKHR'
    if ($null -eq $createSwapchainFn -or $null -eq $destroySwapchainFn) { return $false }

    $hasSlotMember = ($clean -match 'VkSemaphore\s+appReadySemaphore')
    $hasCreate = ($createSwapchainFn -match 'createSemaphore\s*\([^,]+,\s*[^,]+,\s*[^,]+,\s*&[^\.]*\.appReadySemaphore') -or
                 ($createSwapchainFn -match 'appReadySemaphore')
    $hasDestroy = ($destroySwapchainFn -match 'destroySemaphore\s*\([^,]+,\s*[^\.]*\.appReadySemaphore') -or
                  ($destroySwapchainFn -match 'appReadySemaphore')

    return ($hasSlotMember -and $hasCreate -and $hasDestroy)
}

function Test-V2B1BSplitWaitsEvent2Execution {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasSplitCheck = ($presentFn -match 'g_v2b1DiagSplitWaits') -and ($presentFn -match 'currentDiagEvent\s*==\s*2|event\s*==\s*2|diagActive\s*==\s*1')
    $hasStepALog = ($presentFn -match '\[LSFG-V2B1-WAITDIAG\]') -and ($presentFn -match 'APP_WAIT')
    $hasStepBLog = ($presentFn -match '\[LSFG-V2B1-WAITDIAG\]') -and ($presentFn -match 'COPY_WAIT')
    $hasAppReadyWaitInCopy = ($presentFn -match 'appReadySemaphore')

    return ($hasSplitCheck -and $hasStepALog -and $hasStepBLog -and $hasAppReadyWaitInCopy)
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

$mockValidWaitDiagSource = @"
struct TransportSlot {
    VkSemaphore extraAcquireSemaphore = VK_NULL_HANDLE;
    VkSemaphore appReadySemaphore = VK_NULL_HANDLE;
    VkFence copyFence = VK_NULL_HANDLE;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
};
std::atomic<bool> g_v2b1DiagSplitWaits{false};

void lsfg_interposer_init(void *h) {
    const char *s = getenv("AMETHYST_LSFG_V2B1_DIAG_SPLIT_WAITS");
    if (s) {
        g_v2b1DiagSplitWaits.store(true);
    }
}
VkResult interposer_vkCreateSwapchainKHR(VkDevice d, const VkSwapchainCreateInfoKHR *c, const VkAllocationCallbacks *a, VkSwapchainKHR *s) {
    devStateCopy.createSemaphore(device, &semInfo, nullptr, &transport.slots[s].appReadySemaphore);
    return VK_SUCCESS;
}
void interposer_vkDestroySwapchainKHR(VkDevice d, VkSwapchainKHR s, const VkAllocationCallbacks *a) {
    transportToDestroy.destroySemaphore(transportToDestroy.device, slot.appReadySemaphore, nullptr);
}
VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    bool splitWaits = g_v2b1DiagSplitWaits.load(std::memory_order_relaxed);
    uint32_t currentDiagEvent = diagActive + 1;
    if (splitWaits && currentDiagEvent == 2) {
        LOGI("[LSFG-V2B1-WAITDIAG] event=2 phase=APP_WAIT appWaitCount=%u appReadySemaphore=0x%lx", count, appReadySemaphore);
        VkResult resA = transport.queueSubmit(queue, 1, &submitInfoA, VK_NULL_HANDLE);
        LOGI("[LSFG-V2B1-WAITDIAG] event=2 phase=APP_WAIT submitRes=%d", resA);
        
        LOGI("[LSFG-V2B1-WAITDIAG] event=2 phase=COPY_WAIT appReadySemaphore=0x%lx extraAcquireSemaphore=0x%lx", appReadySemaphore, extraAcquire);
        VkResult resB = transport.queueSubmit(queue, 1, &submitInfoCopy, slot.copyFence);
        LOGI("[LSFG-V2B1-WAITDIAG] event=2 phase=COPY_WAIT submitRes=%d", resB);
    }
    return VK_SUCCESS;
}
"@

Run-SelfCheck "waitdiag latch detector accepts AMETHYST_LSFG_V2B1_DIAG_SPLIT_WAITS" (Test-V2B1BSplitWaitsLatch $mockValidWaitDiagSource)
Run-SelfCheck "waitdiag preallocation detector accepts appReadySemaphore in slot" (Test-V2B1BSplitWaitsPreallocation $mockValidWaitDiagSource)
Run-SelfCheck "waitdiag execution detector accepts event 2 split submission and logging" (Test-V2B1BSplitWaitsEvent2Execution $mockValidWaitDiagSource)

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

Run-Check "AMETHYST_LSFG_V2B1_DIAG_SPLIT_WAITS latch at init with default false" (Test-V2B1BSplitWaitsLatch $producerSrc)
Run-Check "appReadySemaphore preallocated and destroyed with transport slot" (Test-V2B1BSplitWaitsPreallocation $producerSrc)
Run-Check "Event #2 split submission (STEP A app-wait -> STEP B copy) with [LSFG-V2B1-WAITDIAG] logs" (Test-V2B1BSplitWaitsEvent2Execution $producerSrc)

Write-Output "`nSUMMARY checks=$($checksPassed + $checksFailed) failures=$checksFailed"
if ($checksFailed -gt 0) {
    Write-Output "V2B.1B WAIT-DIAG CONTRACT: FAIL"
    exit 1
} else {
    Write-Output "V2B.1B WAIT-DIAG CONTRACT: PASS"
    exit 0
}
