[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('producer', 'consumer', 'full')]
    [string]$Stage = 'full'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProducerPath = 'C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp'
$LsfgConsumerPath = 'C:\Proyectos\LS-FG\minecraft-mod\src\main\cpp\mc_vk_passive_hook.cpp'
$SgsrConsumerPath = 'C:\Proyectos\SGSR\native\lsfg-android\mc_vk_passive_hook.cpp'

$script:Checks = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Add-Result {
    param(
        [Parameter(Mandatory)] [bool]$Passed,
        [Parameter(Mandatory)] [string]$Scope,
        [Parameter(Mandatory)] [string]$Requirement,
        [string]$Detail = ''
    )
    $script:Checks++
    if ($Passed) {
        Write-Output "PASS [$Scope] $Requirement"
        return
    }
    $message = "FAIL [$Scope] $Requirement"
    if ($Detail) { $message += ": $Detail" }
    $script:Failures.Add($message)
    Write-Output $message
}

function Assert-SelfCheck {
    param(
        [Parameter(Mandatory)] [bool]$Passed,
        [Parameter(Mandatory)] [string]$Name
    )
    if (-not $Passed) { throw "Self-check failed: $Name" }
    Write-Output "SELF-CHECK PASS $Name"
}

function Read-RequiredSource {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required source file does not exist: $Path"
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Remove-CppTrivia {
    param([Parameter(Mandatory)] [string]$Source)
    $chars = $Source.ToCharArray()
    $state = 'code'
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $ch = $chars[$i]
        $next = if ($i + 1 -lt $chars.Length) { $chars[$i + 1] } else { [char]0 }
        switch ($state) {
            'code' {
                if ($ch -eq '/' -and $next -eq '/') {
                    $chars[$i] = ' '; $chars[$i + 1] = ' '; $i++; $state = 'line-comment'
                } elseif ($ch -eq '/' -and $next -eq '*') {
                    $chars[$i] = ' '; $chars[$i + 1] = ' '; $i++; $state = 'block-comment'
                } elseif ($ch -eq '"') {
                    $chars[$i] = ' '; $state = 'string'
                } elseif ($ch -eq "'") {
                    $chars[$i] = ' '; $state = 'character'
                }
            }
            'line-comment' {
                if ($ch -eq "`n") { $state = 'code' }
                elseif ($ch -ne "`r") { $chars[$i] = ' ' }
            }
            'block-comment' {
                if ($ch -eq '*' -and $next -eq '/') {
                    $chars[$i] = ' '; $chars[$i + 1] = ' '; $i++; $state = 'code'
                } elseif ($ch -ne "`r" -and $ch -ne "`n") { $chars[$i] = ' ' }
            }
            'string' {
                if ($ch -eq '\' -and $i + 1 -lt $chars.Length) {
                    $chars[$i] = ' '; $chars[$i + 1] = ' '; $i++
                } elseif ($ch -eq '"') {
                    $chars[$i] = ' '; $state = 'code'
                } elseif ($ch -ne "`r" -and $ch -ne "`n") { $chars[$i] = ' ' }
            }
            'character' {
                if ($ch -eq '\' -and $i + 1 -lt $chars.Length) {
                    $chars[$i] = ' '; $chars[$i + 1] = ' '; $i++
                } elseif ($ch -eq "'") {
                    $chars[$i] = ' '; $state = 'code'
                } elseif ($ch -ne "`r" -and $ch -ne "`n") { $chars[$i] = ' ' }
            }
        }
    }
    return -join $chars
}

function Get-CppFunctionBody {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$FunctionName
    )
    $pattern = '(?s)\b' + [regex]::Escape($FunctionName) + '\s*\([^)]*?\)\s*(?:const\s*)?\{'
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) { return $null }

    $startIndex = $match.Index + $match.Length - 1
    $chars = $Source.ToCharArray()
    $depth = 0
    for ($i = $startIndex; $i -lt $chars.Length; $i++) {
        if ($chars[$i] -eq '{') { $depth++ }
        elseif ($chars[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Source.Substring($startIndex, $i - $startIndex + 1)
            }
        }
    }
    return $null
}

function Test-Pattern {
    param([string]$Text, [string]$Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, $Pattern)
}

function Assert-Pattern {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Scope,
        [string]$Requirement,
        [string]$Detail = ''
    )
    $passed = Test-Pattern $Text $Pattern
    Add-Result $passed $Scope $Requirement $Detail
}

function Test-NoRealVulkanUnderMutex {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    # Locate all std::lock_guard<std::mutex> lock(g_stateMutex) blocks or unique_lock
    $lockPattern = 'std::(?:lock_guard|unique_lock)\s*<\s*std::mutex\s*>\s+\w+\s*\(\s*g_stateMutex\s*\)\s*;'
    $matches = [regex]::Matches($clean, $lockPattern)
    foreach ($m in $matches) {
        # Find enclosing or following scope of this lock
        $idx = $m.Index
        # Find scope start (either preceding { or following {)
        $scopeStart = $clean.LastIndexOf('{', $idx)
        if ($scopeStart -ge 0) {
            # Find matching }
            $depth = 0
            $scopeEnd = -1
            for ($i = $scopeStart; $i -lt $clean.Length; $i++) {
                if ($clean[$i] -eq '{') { $depth++ }
                elseif ($clean[$i] -eq '}') {
                    $depth--
                    if ($depth -eq 0) { $scopeEnd = $i; break }
                }
            }
            if ($scopeEnd -gt $idx) {
                $lockedRegion = $clean.Substring($idx, $scopeEnd - $idx)
                # Check for prohibited Vulkan calls
                if ($lockedRegion -match '\b(?:realGetCaps|realGetModes|realGetQueueFamilyProperties|realCreateSwapchain|realFunc)\s*\(') {
                    return $false
                }
                if ($lockedRegion -match '\b(?:vkGetPhysicalDeviceSurfacePresentModesKHR|vkGetPhysicalDeviceSurfaceCapabilitiesKHR|vkCreateSwapchainKHR)\s*\(') {
                    return $false
                }
            }
        }
    }
    return $true
}

function Test-V2B0DiagnosticBlock {
    param([string]$Source)
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    if ($null -eq $createFn) { return $false }
    
    $requiredLabels = @(
        'LSFG-V2B0',
        'gateEnabled',
        'swapchain',
        'surface',
        'appRequestedMode',
        'effectiveMode',
        'fifoSupported',
        'queryResult',
        'overrideApplied',
        'fallbackReason',
        'requestedMinImageCount',
        'actualImageCount',
        'imageUsage',
        'extent',
        'format',
        'colorSpace'
    )
    foreach ($label in $requiredLabels) {
        if (-not $createFn.Contains($label)) {
            return $false
        }
    }
    return $true
}

function Test-V2B0GateLatch {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $initFn = Get-CppFunctionBody $Source 'lsfg_interposer_init'
    if ($null -eq $initFn) { return $false }
    if (-not ($initFn -match 'getenv\s*\(\s*"AMETHYST_LSFG_V2B0_FIFO"\s*\)')) { return $false }
    if (-not ($clean -match 'std::atomic\s*<\s*bool\s*>\s+g_v2b0FifoEnabled')) { return $false }
    return $true
}

function Test-V2B0NoHotPathGetenv {
    param([string]$Source)
    $presentFn = Get-CppFunctionBody $Source 'interposer_vkQueuePresentKHR'
    $acquireFn = Get-CppFunctionBody $Source 'interposer_vkAcquireNextImageKHR'
    $acquire2Fn = Get-CppFunctionBody $Source 'interposer_vkAcquireNextImage2KHR'
    
    if ($null -ne $presentFn -and $presentFn -match '\bgetenv\b') { return $false }
    if ($null -ne $acquireFn -and $acquireFn -match '\bgetenv\b') { return $false }
    if ($null -ne $acquire2Fn -and $acquire2Fn -match '\bgetenv\b') { return $false }
    return $true
}

function Test-V2B0SafeCreateInfoOverride {
    param([string]$Source)
    $createFn = Get-CppFunctionBody $Source 'interposer_vkCreateSwapchainKHR'
    if ($null -eq $createFn) { return $false }
    
    # Must declare shallow copy: VkSwapchainCreateInfoKHR ... = ...*pCreateInfo...;
    $hasShallowCopy = ($createFn -match 'VkSwapchainCreateInfoKHR\s+\w+\s*=[^;]*\*\s*pCreateInfo')
    # Must override presentMode = VK_PRESENT_MODE_FIFO_KHR
    $hasFifoOverride = ($createFn -match '\.\s*presentMode\s*=\s*VK_PRESENT_MODE_FIFO_KHR\s*;')
    # Must call real function with pointer to local copy or pCreateInfo
    $hasRealCall = ($createFn -match 'realFunc\s*\(\s*device\s*,')
    # Must NOT cast away const on pCreateInfo
    $noConstCast = -not ($createFn -match 'const_cast\s*<\s*VkSwapchainCreateInfoKHR')
    
    return ($hasShallowCopy -and $hasFifoOverride -and $hasRealCall -and $noConstCast)
}

function Test-V2B0SummaryCounters {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $summaryFn = Get-CppFunctionBody $Source 'lsfg_interposer_log_summary'
    if ($null -eq $summaryFn) { return $false }
    
    $requiredSummaryLabels = @('v2b0Gate', 'v2b0Eligible', 'v2b0Override', 'v2b0Fallback', 'v2b0ActiveTransport')
    foreach ($label in $requiredSummaryLabels) {
        if (-not ($summaryFn -match [regex]::Escape($label))) {
            return $false
        }
    }
    return $true
}

function Test-V2B0PassivityInvariants {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    # Prohibit new active Vulkan operations in interposer
    if ($clean -match '\bvkQueueSubmit\s*\(') { return $false }
    if ($clean -match '\bvkQueueSubmit2\s*\(') { return $false }
    if ($clean -match '\bvkCreateFence\s*\(') { return $false }
    if ($clean -match '\bvkCreateSemaphore\s*\(') { return $false }
    if ($clean -match '\bvkAllocateCommandBuffers\s*\(') { return $false }
    if ($clean -match '\bvkCmdBlitImage\s*\(') { return $false }
    if ($clean -match '\bvkCmdCopyImage\s*\(') { return $false }
    if ($clean -match '\bvkCmdDispatch\s*\(') { return $false }
    return $true
}

function Invoke-DetectorSelfChecks {
    $goodCode = @'
std::atomic<bool> g_v2b0FifoEnabled{false};
std::atomic<uint32_t> g_v2b0SwapchainCreateEligible{0};
std::atomic<uint32_t> g_v2b0FifoOverrideApplied{0};
std::atomic<uint32_t> g_v2b0FifoFallback{0};
std::atomic<uint32_t> g_v2b0UnexpectedActiveTransport{0};

bool lsfg_interposer_init(void *realVulkanHandle) {
    const char *env = getenv("AMETHYST_LSFG_V2B0_FIFO");
    if (env != nullptr && (std::strcmp(env, "1") == 0 || strcasecmp(env, "true") == 0)) {
        g_v2b0FifoEnabled.store(true, std::memory_order_relaxed);
    }
    return true;
}

VkResult interposer_vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkSwapchainKHR *pSwapchain) {
    VkSwapchainCreateInfoKHR effectiveCreateInfo = *pCreateInfo;
    effectiveCreateInfo.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    VkResult res = realFunc(device, &effectiveCreateInfo, pAllocator, pSwapchain);
    LOGI("[LSFG-V2B0] gateEnabled=true swapchain=%p surface=%p appRequestedMode=1 effectiveMode=2 fifoSupported=true queryResult=OK overrideApplied=true fallbackReason=NONE requestedMinImageCount=3 actualImageCount=4 imageUsage=0x97 extent=1920x1080 format=37 colorSpace=0", *pSwapchain, pCreateInfo->surface);
    return res;
}

void lsfg_interposer_log_summary() {
    LOGI("[LSFG-VK-SUMMARY] v2b0Gate=%u v2b0Eligible=%u v2b0Override=%u v2b0Fallback=%u v2b0ActiveTransport=%u", 1, 1, 1, 0, 0);
}
'@

    $badMutexCode = @'
VkResult interposer_vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkSwapchainKHR *pSwapchain) {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    realGetModes(physDev, surface, &count, modes);
    return realCreateSwapchain(device, pCreateInfo, pAllocator, pSwapchain);
}
'@

    Assert-SelfCheck (Test-V2B0GateLatch $goodCode) 'gate latch detector accepts valid latch in init'
    Assert-SelfCheck (Test-V2B0SafeCreateInfoOverride $goodCode) 'safe createInfo override detector accepts local stack copy override'
    Assert-SelfCheck (Test-V2B0DiagnosticBlock $goodCode) 'diagnostic block detector accepts complete LSFG-V2B0 log line'
    Assert-SelfCheck (Test-V2B0SummaryCounters $goodCode) 'summary counters detector accepts V2B.0 telemetry fields'
    Assert-SelfCheck (Test-V2B0PassivityInvariants $goodCode) 'passivity detector accepts passive implementation'
    Assert-SelfCheck (-not (Test-NoRealVulkanUnderMutex $badMutexCode)) 'locking detector rejects real Vulkan calls under g_stateMutex'
}

function Invoke-ProducerChecks {
    $scope = 'producer'
    $source = Read-RequiredSource $ProducerPath
    $clean = Remove-CppTrivia $source

    Add-Result (Test-V2B0GateLatch $source) $scope 'AMETHYST_LSFG_V2B0_FIFO gate is latched at native init and stored in std::atomic<bool>' 'gate latch is missing or not in lsfg_interposer_init'
    Add-Result (Test-V2B0NoHotPathGetenv $source) $scope 'no getenv calls in acquire or present hot paths' 'getenv found in hot path function'
    Add-Result (Test-V2B0SafeCreateInfoOverride $source) $scope 'safe local stack copy of VkSwapchainCreateInfoKHR used for presentMode override' 'missing local createInfo copy or invalid presentMode assignment'
    Add-Result (Test-NoRealVulkanUnderMutex $source) $scope 'zero real Vulkan driver calls under g_stateMutex' 'driver call executed while holding state lock'
    Add-Result (Test-V2B0DiagnosticBlock $source) $scope 'one-shot [LSFG-V2B0] diagnostic block with all required fields in vkCreateSwapchainKHR' 'missing required diagnostic labels in createSwapchain'
    Add-Result (Test-V2B0SummaryCounters $source) $scope 'lsfg_interposer_log_summary includes all required V2B.0 telemetry counters' 'summary telemetry missing v2b0 counters'
    Add-Result (Test-V2B0PassivityInvariants $source) $scope 'zero active Vulkan operations (no submit, fences, semaphores, command buffers, copies, blits, compute)' 'active Vulkan transport call found in producer'
    
    # Metadata & Generation check
    $metadataBody = Get-CppFunctionBody $source 'interposer_vkCreateSwapchainKHR'
    $hasEffectiveCommit = ($null -ne $metadataBody -and $metadataBody -match 'meta\.presentMode\s*=')
    Add-Result $hasEffectiveCommit $scope 'SwapchainMetadata records effective present mode on successful creation' 'meta.presentMode not committed from effective createInfo'
}

function Invoke-ConsumerChecks {
    $scope = 'consumer'
    $lsfgSource = Read-RequiredSource $LsfgConsumerPath
    $sgsrSource = Read-RequiredSource $SgsrConsumerPath
    
    # Verify consumers remain passive and decode FIFO
    Assert-Pattern $lsfgSource 'VK_PRESENT_MODE_FIFO_KHR' 'consumer:LS-FG' 'consumer decodes VK_PRESENT_MODE_FIFO_KHR'
    Assert-Pattern $sgsrSource 'VK_PRESENT_MODE_FIFO_KHR' 'consumer:SGSR' 'consumer decodes VK_PRESENT_MODE_FIFO_KHR'
    
    $lsfgHash = (Get-FileHash $LsfgConsumerPath -Algorithm SHA256).Hash
    $sgsrHash = (Get-FileHash $SgsrConsumerPath -Algorithm SHA256).Hash
    Add-Result ($lsfgHash -eq $sgsrHash) 'consumer:mirror' 'LS-FG and SGSR consumer files match exactly'
}

Write-Output "LSFG Bridge V2B.0 contract test (stage=$Stage)"
try {
    Invoke-DetectorSelfChecks
    if ($Stage -in @('producer', 'full')) { Invoke-ProducerChecks }
    if ($Stage -in @('consumer', 'full')) { Invoke-ConsumerChecks }
} catch {
    [Console]::Error.WriteLine("Contract test infrastructure error: $($_.Exception.Message)")
    exit 2
}

Write-Output "SUMMARY checks=$script:Checks failures=$($script:Failures.Count)"
if ($script:Failures.Count -gt 0) {
    Write-Output 'V2B.0 CONTRACT: FAIL'
    exit 1
}
Write-Output 'V2B.0 CONTRACT: PASS'
exit 0
