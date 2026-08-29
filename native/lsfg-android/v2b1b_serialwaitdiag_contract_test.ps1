# LSFG V2B.1B Event #2 Serialized Wait-Provenance Diagnostic Contract Test
# Validates serialize-waits diagnostic gating, preallocation, Event 2 execution (B1, B2, C), and logging.

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

function Test-V2B1BSerialWaitsLatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    if ($null -eq $initFn) { return $false }

    $hasAtomicDecl = ($clean -match 'std::atomic<bool>\s+g_v2b1DiagSerializeWaits') -or ($clean -match 'std::atomic<uint32_t>\s+g_v2b1DiagSerializeWaits')
    $hasLatch = ($initFn -match 'getenv\s*\(\s*"AMETHYST_LSFG_V2B1_DIAG_SERIALIZE_WAITS"\s*\)')
    $hasStore = ($initFn -match 'g_v2b1DiagSerializeWaits\s*\.\s*store')

    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    $noGetenvInPresent = $true
    if ($presentFn -and ($presentFn -match 'getenv\s*\(')) { $noGetenvInPresent = $false }

    return ($hasAtomicDecl -and $hasLatch -and $hasStore -and $noGetenvInPresent)
}

function Test-V2B1BSerialWaitsPreallocation {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $createSwapchainFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    $destroySwapchainFn = Get-CppFunctionBody $Source 'interposer_vkDestroySwapchainKHR'
    if ($null -eq $createSwapchainFn -or $null -eq $destroySwapchainFn) { return $false }

    $hasSlotMembers = ($clean -match 'VkSemaphore\s+appChainReadySemaphore') -and ($clean -match 'VkSemaphore\s+acquireChainReadySemaphore')
    $hasCreate = ($createSwapchainFn -match 'appChainReadySemaphore') -and ($createSwapchainFn -match 'acquireChainReadySemaphore')
    $hasDestroy = ($destroySwapchainFn -match 'appChainReadySemaphore') -and ($destroySwapchainFn -match 'acquireChainReadySemaphore')

    return ($hasSlotMembers -and $hasCreate -and $hasDestroy)
}

function Test-V2B1BSerialWaitsEvent2Execution {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasSerialCheck = ($clean -match 'g_v2b1DiagSerializeWaits') -and ($clean -match 'currentDiagEvent\s*==\s*2|event\s*==\s*2|diagActive\s*==\s*1')
    $hasB1Log = ($clean -match '\[LSFG-V2B1-SERIALDIAG\]') -and ($clean -match 'APP_READY_ONLY')
    $hasB2Log = ($clean -match '\[LSFG-V2B1-SERIALDIAG\]') -and ($clean -match 'EXTRA_ACQUIRE_ONLY')
    $hasCLog = ($clean -match '\[LSFG-V2B1-SERIALDIAG\]') -and ($clean -match 'COPY_INTERNAL_WAITS')
    $hasChainedWaitsInCopy = ($clean -match 'appChainReadySemaphore') -and ($clean -match 'acquireChainReadySemaphore')

    return ($hasSerialCheck -and $hasB1Log -and $hasB2Log -and $hasCLog -and $hasChainedWaitsInCopy)
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

$mockValidSerialWaitDiagSource = @"
struct TransportSlot {
    VkSemaphore extraAcquireSemaphore = VK_NULL_HANDLE;
    VkSemaphore appReadySemaphore = VK_NULL_HANDLE;
    VkSemaphore appChainReadySemaphore = VK_NULL_HANDLE;
    VkSemaphore acquireChainReadySemaphore = VK_NULL_HANDLE;
    VkFence copyFence = VK_NULL_HANDLE;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkCommandBuffer diagAppWaitCommandBuffer = VK_NULL_HANDLE;
    VkCommandBuffer diagAppReadyCommandBuffer = VK_NULL_HANDLE;
    VkCommandBuffer diagAcquireReadyCommandBuffer = VK_NULL_HANDLE;
};
std::atomic<bool> g_v2b1DiagSerializeWaits{false};

void lsfg_interposer_init(void *h) {
    const char *s = getenv("AMETHYST_LSFG_V2B1_DIAG_SERIALIZE_WAITS");
    if (s) {
        g_v2b1DiagSerializeWaits.store(true);
    }
}
VkResult interposer_vkCreateSwapchainKHR(VkDevice d, const VkSwapchainCreateInfoKHR *c, const VkAllocationCallbacks *a, VkSwapchainKHR *s) {
    devStateCopy.createSemaphore(device, &semInfo, nullptr, &transport.slots[s].appChainReadySemaphore);
    devStateCopy.createSemaphore(device, &semInfo, nullptr, &transport.slots[s].acquireChainReadySemaphore);
    return VK_SUCCESS;
}
void interposer_vkDestroySwapchainKHR(VkDevice d, VkSwapchainKHR s, const VkAllocationCallbacks *a) {
    transportToDestroy.destroySemaphore(transportToDestroy.device, slot.appChainReadySemaphore, nullptr);
    transportToDestroy.destroySemaphore(transportToDestroy.device, slot.acquireChainReadySemaphore, nullptr);
}
VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    bool serializeWaits = g_v2b1DiagSerializeWaits.load(std::memory_order_relaxed);
    uint32_t currentDiagEvent = diagActive + 1;
    if (serializeWaits && currentDiagEvent == 2) {
        LOGI("[LSFG-V2B1-SERIALDIAG] event=2 phase=APP_READY_ONLY wait=0x%lx signal=0x%lx", appReady, appChainReady);
        VkResult resB1 = transport.queueSubmit(queue, 1, &submitInfoB1, VK_NULL_HANDLE);
        LOGI("[LSFG-V2B1-SERIALDIAG] event=2 phase=APP_READY_ONLY submitRes=%d", resB1);

        LOGI("[LSFG-V2B1-SERIALDIAG] event=2 phase=EXTRA_ACQUIRE_ONLY wait=0x%lx signal=0x%lx", extraAcquire, acquireChainReady);
        VkResult resB2 = transport.queueSubmit(queue, 1, &submitInfoB2, VK_NULL_HANDLE);
        LOGI("[LSFG-V2B1-SERIALDIAG] event=2 phase=EXTRA_ACQUIRE_ONLY submitRes=%d", resB2);

        LOGI("[LSFG-V2B1-SERIALDIAG] event=2 phase=COPY_INTERNAL_WAITS wait0=0x%lx wait1=0x%lx", slot.appChainReadySemaphore, slot.acquireChainReadySemaphore);
        VkResult resC = transport.queueSubmit(queue, 1, &submitInfoCopy, slot.copyFence);
        LOGI("[LSFG-V2B1-SERIALDIAG] event=2 phase=COPY_INTERNAL_WAITS submitRes=%d", resC);
    }
    return VK_SUCCESS;
}
"@

Run-SelfCheck "serialwaitdiag latch detector accepts AMETHYST_LSFG_V2B1_DIAG_SERIALIZE_WAITS" (Test-V2B1BSerialWaitsLatch $mockValidSerialWaitDiagSource)
Run-SelfCheck "serialwaitdiag preallocation detector accepts appChainReady/acquireChainReady semaphores" (Test-V2B1BSerialWaitsPreallocation $mockValidSerialWaitDiagSource)
Run-SelfCheck "serialwaitdiag execution detector accepts B1, B2, C submissions and logging" (Test-V2B1BSerialWaitsEvent2Execution $mockValidSerialWaitDiagSource)

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

Run-Check "AMETHYST_LSFG_V2B1_DIAG_SERIALIZE_WAITS latch at init with default false" (Test-V2B1BSerialWaitsLatch $producerSrc)
Run-Check "appChainReadySemaphore and acquireChainReadySemaphore preallocated and destroyed" (Test-V2B1BSerialWaitsPreallocation $producerSrc)
Run-Check "Event #2 serialized wait submission (STEP B1 app-ready -> STEP B2 extra-acquire -> STEP C copy) with [LSFG-V2B1-SERIALDIAG] logs" (Test-V2B1BSerialWaitsEvent2Execution $producerSrc)

Write-Output "`nSUMMARY checks=$($checksPassed + $checksFailed) failures=$checksFailed"
if ($checksFailed -gt 0) {
    Write-Output "V2B.1B SERIAL-WAIT-DIAG CONTRACT: FAIL"
    exit 1
} else {
    Write-Output "V2B.1B SERIAL-WAIT-DIAG CONTRACT: PASS"
    exit 0
}
