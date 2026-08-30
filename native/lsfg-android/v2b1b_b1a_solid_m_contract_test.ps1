# ==============================================================================
# LSFG V2B.1B Phase B1A Solid-M Present Visibility Diagnostic Contract Test
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

function Test-SolidMGateDefinition {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $hasGate = ($clean -match 'AMETHYST_LSFG_B1_DIAG_SOLID_M_PRESENT') -and ($clean -match 'g_b1DiagSolidMPresent')
    $hasMax = ($clean -match 'AMETHYST_LSFG_B1_DIAG_SOLID_M_PRESENT_MAX_ACTIVE') -and ($clean -match 'g_b1DiagSolidMPresentMaxActive')
    $hasCounters = ($clean -match 'g_b1DiagSolidMEligible') -and ($clean -match 'g_b1DiagSolidMClear')
    return ($hasGate -and $hasMax -and $hasCounters)
}

function Test-SolidMClearCommandAndColor {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasClearCmd = ($presentFn -match 'cmdClearColorImage|vkCmdClearColorImage')
    $hasTargetM = ($presentFn -match 'swapchainImages\[M\]')
    $hasMagenta = ($presentFn -match '(?s)1\.0f.*0\.0f.*1\.0f.*1\.0f|(?s)1\.0.*0\.0.*1\.0.*1\.0')
    $hasTransferDstLayout = ($presentFn -match 'VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL')
    $hasPresentSrcLayout = ($presentFn -match 'VK_IMAGE_LAYOUT_PRESENT_SRC_KHR')

    return ($hasClearCmd -and $hasTargetM -and $hasMagenta -and $hasTransferDstLayout -and $hasPresentSrcLayout)
}

function Test-PreserveDualPresentAndNUntouched {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasPresentM = ($presentFn -match 'presentM') -and ($presentFn -match 'generatedPresentReady')
    $hasPresentN = ($presentFn -match 'presentN') -and ($presentFn -match 'realPresentReady')
    $mIndex = $presentFn.IndexOf('presentM')
    $nIndex = $presentFn.IndexOf('presentN')
    $orderCorrect = ($mIndex -ge 0 -and $nIndex -gt $mIndex)

    # Check N is not passed to clear color image
    $nCleared = ($presentFn -match 'cmdClearColorImage\s*\([^)]*swapchainImages\[N\]')

    return ($hasPresentM -and $hasPresentN -and $orderCorrect -and (-not $nCleared))
}

function Test-NoHotPathWaitsOrAllocations {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $hasQueueWaitIdle = ($presentFn -match '\bvkQueueWaitIdle\b')
    $hasDeviceWaitIdle = ($presentFn -match '\bvkDeviceWaitIdle\b')
    $hasNew = ($presentFn -match '\bnew\s+')
    $hasMalloc = ($presentFn -match '\bmalloc\s*\(')

    return (-not ($hasQueueWaitIdle -or $hasDeviceWaitIdle -or $hasNew -or $hasMalloc))
}

# --- Self Check with synthetic test string ---
$fakeSource = @'
static std::atomic<int> g_b1DiagSolidMPresent{0};
static std::atomic<int> g_b1DiagSolidMPresentMaxActive{0};
static std::atomic<uint64_t> g_b1DiagSolidMEligible{0};
static std::atomic<uint64_t> g_b1DiagSolidMClear{0};

void init() {
    const char *e1 = getenv("AMETHYST_LSFG_B1_DIAG_SOLID_M_PRESENT");
    const char *e2 = getenv("AMETHYST_LSFG_B1_DIAG_SOLID_M_PRESENT_MAX_ACTIVE");
}

VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* pPresentInfo) {
    if (isSolidMDiagActive) {
        VkClearColorValue magentaColor{};
        magentaColor.float32[0] = 1.0f;
        magentaColor.float32[1] = 0.0f;
        magentaColor.float32[2] = 1.0f;
        magentaColor.float32[3] = 1.0f;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        transport.cmdClearColorImage(cmdBuf, transport.swapchainImages[M], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &magentaColor, 1, &colorRange);
        postBarrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    }
    VkPresentInfoKHR presentM{};
    presentM.pWaitSemaphores = &generatedPresentReady;
    realFunc(queue, &presentM);

    VkPresentInfoKHR presentN{};
    presentN.pWaitSemaphores = &realPresentReady;
    realFunc(queue, &presentN);
    return VK_SUCCESS;
}
'@

if (-not (Test-SolidMGateDefinition $fakeSource)) { throw "Self-check failed: Test-SolidMGateDefinition" }
if (-not (Test-SolidMClearCommandAndColor $fakeSource)) { throw "Self-check failed: Test-SolidMClearCommandAndColor" }
if (-not (Test-PreserveDualPresentAndNUntouched $fakeSource)) { throw "Self-check failed: Test-PreserveDualPresentAndNUntouched" }
if (-not (Test-NoHotPathWaitsOrAllocations $fakeSource)) { throw "Self-check failed: Test-NoHotPathWaitsOrAllocations" }
Write-Host "SELF-CHECK PASS: Solid-M diagnostic detector validated against synthetic models"

# --- Live Target Verification ---
if (-not (Test-Path -Path $ProducerSource)) {
    throw "Producer source file not found at: $ProducerSource"
}

$liveSource = Get-Content -Path $ProducerSource -Raw -Encoding UTF8

$passGates = Test-SolidMGateDefinition $liveSource
$passClear = Test-SolidMClearCommandAndColor $liveSource
$passPresent = Test-PreserveDualPresentAndNUntouched $liveSource
$passHotPath = Test-NoHotPathWaitsOrAllocations $liveSource

Write-Host "CONTRACT AUDIT RESULTS:"
Write-Host "  1. Solid M Diagnostic Gates Defined:     $passGates"
Write-Host "  2. Solid M Clear Command and Magenta:    $passClear"
Write-Host "  3. Dual Present and N Untouched:         $passPresent"
Write-Host "  4. No Hot-Path Blocking / Allocations:   $passHotPath"

if ($passGates -and $passClear -and $passPresent -and $passHotPath) {
    Write-Host "CONTRACT PASS: Phase B1A Solid-M Present Visibility Diagnostic is structurally verified"
    exit 0
} else {
    Write-Host "CONTRACT FAIL: Implementation does not yet satisfy all Solid-M contract requirements"
    exit 1
}
