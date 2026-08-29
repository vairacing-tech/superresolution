# LSFG V2B.1B Two-Event Diagnostic Experiment Contract Test
# Validates diagnostic max-active gating and pre/post submit logging.

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

function Test-V2B1BDiagLatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    if ($null -eq $initFn) { return $false }

    $hasAtomicDecl = ($clean -match 'std::atomic<uint32_t>\s+g_v2b1DiagMaxActive')
    $hasLatch = ($initFn -match 'getenv\s*\(\s*"AMETHYST_LSFG_V2B1_DIAG_MAX_ACTIVE"\s*\)')
    $hasStore = ($initFn -match 'g_v2b1DiagMaxActive\s*\.\s*store')

    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    $noGetenvInPresent = $true
    if ($presentFn -and ($presentFn -match 'getenv\s*\(')) { $noGetenvInPresent = $false }

    return ($hasAtomicDecl -and $hasLatch -and $hasStore -and $noGetenvInPresent)
}

function Test-V2B1BDiagLimitSemantics {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    $loadsMaxActive = ($presentFn -match 'g_v2b1DiagMaxActive') -or ($presentFn -match 'maxActive')
    $checksLimit = ($presentFn -match 'maxActive\s*>\s*0') -and ($presentFn -match '(committed|diagActive|activeCount|diagEvents|diagEventNumber)\s*>=?\s*maxActive')
    
    # Check that fallback returns (slot unavailable, NOT_READY, TIMEOUT) occur BEFORE the active count advances
    $matchNotReady = [regex]::Match($presentFn, 'resAcquire\s*==\s*VK_NOT_READY')
    $matchSubmit = [regex]::Match($presentFn, '(\.queueSubmit|realQueueSubmit)\s*\(')

    $orderedCorrectly = ($matchNotReady.Success -and $matchSubmit.Success -and $matchNotReady.Index -lt $matchSubmit.Index)

    return ($loadsMaxActive -and $checksLimit -and $orderedCorrectly)
}

function Test-V2B1BDiagPrePostSubmitLogs {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    if ($null -eq $presentFn) { return $false }

    # Must contain [LSFG-V2B1-DIAG] tag
    $hasDiagTag = ($presentFn -match '\[LSFG-V2B1-DIAG\]')
    
    # Must log before submit: selectedSlot, N, M, resAcquire, wait info, signal info
    $matchSubmit = [regex]::Match($presentFn, '(\.queueSubmit|realQueueSubmit)\s*\(')
    if (-not $matchSubmit.Success) { return $false }

    $beforeSubmit = $presentFn.Substring(0, $matchSubmit.Index)
    $afterSubmit = $presentFn.Substring($matchSubmit.Index)

    $logsBefore = ($beforeSubmit -match '\[LSFG-V2B1-DIAG\]') -and
                  ($beforeSubmit -match 'selectedSlot') -and
                  ($beforeSubmit -match 'extraAcquireSemaphore') -and
                  ($beforeSubmit -match 'generatedPresentReady') -and
                  ($beforeSubmit -match 'realPresentReady')

    # Must log after submit: queueSubmitResult
    $logsAfter = ($afterSubmit -match '\[LSFG-V2B1-DIAG\]') -and ($afterSubmit -match 'submitRes')

    return ($hasDiagTag -and $logsBefore -and $logsAfter)
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

$mockValidDiagSource = @"
std::atomic<uint32_t> g_v2b1DiagMaxActive{0};
std::atomic<uint32_t> g_v2b1DiagCommittedActive{0};

void lsfg_interposer_init(void *h) {
    const char *d = getenv("AMETHYST_LSFG_V2B1_DIAG_MAX_ACTIVE");
    if (d) {
        g_v2b1DiagMaxActive.store(static_cast<uint32_t>(atoi(d)));
    }
}
VkResult interposer_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    V2B1Mode mode = g_v2b1Mode.load(std::memory_order_relaxed);
    bool isContinuous = (mode == V2B1Mode::Continuous);
    uint32_t maxActive = g_v2b1DiagMaxActive.load(std::memory_order_relaxed);
    uint32_t diagActive = g_v2b1DiagCommittedActive.load(std::memory_order_relaxed);
    if (isContinuous && maxActive > 0 && diagActive >= maxActive) {
        return realFunc(queue, pPresentInfo);
    }
    if (resAcquire == VK_NOT_READY || resAcquire == VK_TIMEOUT) return realFunc(queue, pPresentInfo);
    
    if (diagActive < 2 || maxActive > 0) {
        LOGI("[LSFG-V2B1-DIAG] event=%u selectedSlot=%u N=%u M=%u resAcquire=%d extraAcquireSemaphore=0x%lx generatedPresentReady=0x%lx realPresentReady=0x%lx copyFence=0x%lx",
             diagActive + 1, selectedSlot, N, M, resAcquire, extraAcquireSemaphore, generatedPresentReady, realPresentReady, copyFence);
    }
    VkResult submitRes = transport.queueSubmit(queue, 1, &submitInfo, slot.copyFence);
    if (diagActive < 2 || maxActive > 0) {
        LOGI("[LSFG-V2B1-DIAG] event=%u submitRes=%d", diagActive + 1, submitRes);
    }
    g_v2b1DiagCommittedActive.fetch_add(1, std::memory_order_relaxed);
    return realFunc(queue, pPresentInfo);
}
"@

Run-SelfCheck "diag latch detector accepts AMETHYST_LSFG_V2B1_DIAG_MAX_ACTIVE" (Test-V2B1BDiagLatch $mockValidDiagSource)
Run-SelfCheck "diag limit semantics detector accepts maxActive guard and fallback ordering" (Test-V2B1BDiagLimitSemantics $mockValidDiagSource)
Run-SelfCheck "diag logging detector accepts pre/post submit diagnostic logs" (Test-V2B1BDiagPrePostSubmitLogs $mockValidDiagSource)

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

Run-Check "AMETHYST_LSFG_V2B1_DIAG_MAX_ACTIVE latch at init with default 0" (Test-V2B1BDiagLatch $producerSrc)
Run-Check "diag maxActive limit blocks event 3+ while preserving fallback semantics" (Test-V2B1BDiagLimitSemantics $producerSrc)
Run-Check "bounded pre/post submit [LSFG-V2B1-DIAG] logging for active events" (Test-V2B1BDiagPrePostSubmitLogs $producerSrc)

Write-Output "`nSUMMARY checks=$($checksPassed + $checksFailed) failures=$checksFailed"
if ($checksFailed -gt 0) {
    Write-Output "V2B.1B DIAG CONTRACT: FAIL"
    exit 1
} else {
    Write-Output "V2B.1B DIAG CONTRACT: PASS"
    exit 0
}
