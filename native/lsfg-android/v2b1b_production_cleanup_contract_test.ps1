# LSFG V2B.1B Production Transport Cleanup Contract Test
# Validates that the production bridge command buffer resource is normalized to acquireBridgeCommandBuffer,
# that diagAcquireReadyCommandBuffer is removed from TransportSlot, and that the production Mode-2
# duplicate transport topology remains identical.

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

function Test-V2B1BProductionCleanupMemberNames {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source

    # Locate TransportSlot struct
    $matchSlot = [regex]::Match($clean, 'struct\s+TransportSlot\s*\{([\s\S]*?)\};')
    if (-not $matchSlot.Success) { return $false }
    $slotBody = $matchSlot.Groups[1].Value

    # Must contain acquireBridgeCommandBuffer
    $hasNewName = ($slotBody -match 'VkCommandBuffer\s+acquireBridgeCommandBuffer')
    # Must NOT contain old diagnostic name in struct definition
    $noOldNameInStruct = -not ($slotBody -match 'diagAcquireReadyCommandBuffer')

    return ($hasNewName -and $noOldNameInStruct)
}

function Test-V2B1BProductionCleanupTopology {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Bridge uses acquireBridgeCommandBuffer
    $bridgeUsesNewCmd = ($presentFn -match 'acquireBridgeCommandBuffer')

    # Bridge submission: wait extraAcquire, signal acquireReady
    $bridgeWait = ($presentFn -match 'pWaitSemaphores\s*=\s*&slot\.extraAcquireSemaphore')
    $bridgeSignal = ($presentFn -match 'pSignalSemaphores\s*=\s*&slot\.acquireReadySemaphore')

    # Copy submission: waits app waits + acquireReady, signals gen/real, fence copyFence
    $copyAppWaits = ($presentFn -match 'pPresentInfo->pWaitSemaphores')
    $copyAcquireReady = ($presentFn -match 'acquireReadySemaphore')
    $copySignalsGen = ($presentFn -match 'generatedPresentReady')
    $copySignalsReal = ($presentFn -match 'realPresentReady')
    $copyFence = ($presentFn -match 'copyFence')

    return ($bridgeUsesNewCmd -and $bridgeWait -and $bridgeSignal -and $copyAppWaits -and $copyAcquireReady -and $copySignalsGen -and $copySignalsReal -and $copyFence)
}

function Test-V2B1BProductionCleanupInvariants {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $usesFenceStatus = ($presentFn -match 'getFenceStatus\s*\(')
    $noBlockingWait = -not ($presentFn -match 'waitForFences|vkWaitForFences')
    $preservesFailOpen = ($presentFn -match 'g_v2b1SlotUnavailable') -and ($presentFn -match 'VK_NOT_READY|VK_TIMEOUT')

    return ($usesFenceStatus -and $noBlockingWait -and $preservesFailOpen)
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

$mockValidCleanupSource = @"
struct TransportSlot {
    VkSemaphore extraAcquireSemaphore = VK_NULL_HANDLE;
    VkSemaphore acquireReadySemaphore = VK_NULL_HANDLE;
    VkFence copyFence = VK_NULL_HANDLE;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkCommandBuffer acquireBridgeCommandBuffer = VK_NULL_HANDLE;
};

VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    transport.getFenceStatus(transport.device, slot.copyFence);
    if (!slotAvailable) {
        g_v2b1SlotUnavailable.fetch_add(1);
        return realFunc(queue, pPresentInfo);
    }
    VkResult acqRes = transport.acquire(device, swapchain, 0, slot.extraAcquireSemaphore, VK_NULL_HANDLE, &M);
    if (acqRes == VK_NOT_READY || acqRes == VK_TIMEOUT) {
        return realFunc(queue, pPresentInfo);
    }
    bool isBridgeMode = isContinuous && !isDiagnosticOverride;
    if (isBridgeMode) {
        VkCommandBuffer cmdBufBridge = slot.acquireBridgeCommandBuffer;
        submitInfoBridge.waitSemaphoreCount = 1;
        submitInfoBridge.pWaitSemaphores = &slot.extraAcquireSemaphore;
        submitInfoBridge.signalSemaphoreCount = 1;
        submitInfoBridge.pSignalSemaphores = &slot.acquireReadySemaphore;
        transport.queueSubmit(queue, 1, &submitInfoBridge, VK_NULL_HANDLE);

        waitSems[0] = pPresentInfo->pWaitSemaphores[0];
        waitSems[1] = slot.acquireReadySemaphore;
        submitInfoCopy.pWaitSemaphores = waitSems;
        VkSemaphore pSems[2] = { transport.imagePresentation[M].generatedPresentReady, transport.imagePresentation[N].realPresentReady };
        submitInfoCopy.pSignalSemaphores = pSems;
        transport.queueSubmit(queue, 1, &submitInfoCopy, slot.copyFence);
    }
    return VK_SUCCESS;
}
"@

Run-SelfCheck "cleanup detector accepts normalized member names in TransportSlot" (Test-V2B1BProductionCleanupMemberNames $mockValidCleanupSource)
Run-SelfCheck "cleanup detector accepts normalized bridge and copy topology" (Test-V2B1BProductionCleanupTopology $mockValidCleanupSource)
Run-SelfCheck "cleanup detector accepts invariants and fail-open preservation" (Test-V2B1BProductionCleanupInvariants $mockValidCleanupSource)

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

Run-Check "TransportSlot defines acquireBridgeCommandBuffer and retires old diagnostic name" (Test-V2B1BProductionCleanupMemberNames $producerSrc)
Run-Check "Production bridge and copy topology uses acquireBridgeCommandBuffer" (Test-V2B1BProductionCleanupTopology $producerSrc)
Run-Check "Non-blocking vkGetFenceStatus slot reuse and fail-open preservation" (Test-V2B1BProductionCleanupInvariants $producerSrc)

Write-Output "`nSUMMARY checks=$($checksPassed + $checksFailed) failures=$checksFailed"
if ($checksFailed -gt 0) {
    Write-Output "V2B.1B PRODUCTION CLEANUP CONTRACT: FAIL"
    exit 1
} else {
    Write-Output "V2B.1B PRODUCTION CLEANUP CONTRACT: PASS"
    exit 0
}
