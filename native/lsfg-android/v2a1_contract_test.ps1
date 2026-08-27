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
    if ($Detail) {
        $message += ": $Detail"
    }
    $script:Failures.Add($message)
    Write-Output $message
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
                    $chars[$i] = ' '
                    $chars[$i + 1] = ' '
                    $i++
                    $state = 'line-comment'
                } elseif ($ch -eq '/' -and $next -eq '*') {
                    $chars[$i] = ' '
                    $chars[$i + 1] = ' '
                    $i++
                    $state = 'block-comment'
                } elseif ($ch -eq '"') {
                    $chars[$i] = ' '
                    $state = 'string'
                } elseif ($ch -eq "'") {
                    $chars[$i] = ' '
                    $state = 'character'
                }
            }
            'line-comment' {
                if ($ch -eq "`n") {
                    $state = 'code'
                } elseif ($ch -ne "`r") {
                    $chars[$i] = ' '
                }
            }
            'block-comment' {
                if ($ch -eq '*' -and $next -eq '/') {
                    $chars[$i] = ' '
                    $chars[$i + 1] = ' '
                    $i++
                    $state = 'code'
                } elseif ($ch -ne "`r" -and $ch -ne "`n") {
                    $chars[$i] = ' '
                }
            }
            'string' {
                if ($ch -eq '\\' -and $i + 1 -lt $chars.Length) {
                    $chars[$i] = ' '
                    $chars[$i + 1] = ' '
                    $i++
                } elseif ($ch -eq '"') {
                    $chars[$i] = ' '
                    $state = 'code'
                } elseif ($ch -ne "`r" -and $ch -ne "`n") {
                    $chars[$i] = ' '
                }
            }
            'character' {
                if ($ch -eq '\\' -and $i + 1 -lt $chars.Length) {
                    $chars[$i] = ' '
                    $chars[$i + 1] = ' '
                    $i++
                } elseif ($ch -eq "'") {
                    $chars[$i] = ' '
                    $state = 'code'
                } elseif ($ch -ne "`r" -and $ch -ne "`n") {
                    $chars[$i] = ' '
                }
            }
        }
    }

    return -join $chars
}

function Get-MatchingBraceIndex {
    param(
        [Parameter(Mandatory)] [string]$TriviaFreeSource,
        [Parameter(Mandatory)] [int]$OpenIndex
    )

    $depth = 0
    for ($i = $OpenIndex; $i -lt $TriviaFreeSource.Length; $i++) {
        if ($TriviaFreeSource[$i] -eq '{') {
            $depth++
        } elseif ($TriviaFreeSource[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }
    return -1
}

function Get-CppNamedBody {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Name
    )

    $clean = Remove-CppTrivia $Source
    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match(
        $clean,
        "\b$escapedName\s*\([^;{}]*\)\s*(?:noexcept\s*)?\{",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) {
        return $null
    }

    $openIndex = $clean.IndexOf('{', $match.Index)
    $closeIndex = Get-MatchingBraceIndex -TriviaFreeSource $clean -OpenIndex $openIndex
    if ($closeIndex -lt 0) {
        return $null
    }

    return $Source.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
}

function Get-CppStructBody {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Name
    )

    $clean = Remove-CppTrivia $Source
    $match = [regex]::Match($clean, "\bstruct\s+$([regex]::Escape($Name))\s*\{")
    if (-not $match.Success) {
        return $null
    }
    $openIndex = $clean.IndexOf('{', $match.Index)
    $closeIndex = Get-MatchingBraceIndex -TriviaFreeSource $clean -OpenIndex $openIndex
    if ($closeIndex -lt 0) {
        return $null
    }
    return $Source.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
}

function Test-Pattern {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [string]$Pattern
    )

    return [regex]::IsMatch(
        $Text,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
}

function Assert-Pattern {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [string]$Pattern,
        [Parameter(Mandatory)] [string]$Scope,
        [Parameter(Mandatory)] [string]$Requirement,
        [string]$MissingDetail = 'required implementation marker is absent'
    )

    Add-Result -Passed (Test-Pattern $Text $Pattern) -Scope $Scope -Requirement $Requirement -Detail $MissingDetail
}

function Assert-AppendOnlyV2Fields {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Scope
    )

    $body = Get-CppStructBody -Source $Source -Name 'LsfgBridgeSnapshotV2'
    if ($null -eq $body) {
        Add-Result -Passed $false -Scope $Scope -Requirement 'LsfgBridgeSnapshotV2 exists' -Detail 'struct body was not found'
        return
    }

    $cleanBody = Remove-CppTrivia $body
    $exactOrder = 'uint32_t\s+validMask\s*;\s*VkQueueFlags\s+queueFamilyFlags\s*;\s*uint32_t\s+queueFamilyQueueCount\s*;'
    Add-Result -Passed (Test-Pattern $cleanBody $exactOrder) -Scope $Scope `
        -Requirement 'append-only ABI fields immediately follow validMask as VkQueueFlags queueFamilyFlags, then uint32_t queueFamilyQueueCount' `
        -Detail 'the exact V2A.1 append order is absent'
}

function Assert-ExactPresentModesSignature {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Scope
    )

    $clean = Remove-CppTrivia $Source
    $signature = 'lsfg_interposer_bridge_get_present_modes_v2\s*\(\s*uint64_t\s+expectedGeneration\s*,\s*VkSwapchainKHR\s+swapchain\s*,\s*uint32_t\s*\*\s*pCount\s*,\s*VkPresentModeKHR\s*\*\s*pModes\s*\)'
    Add-Result -Passed (Test-Pattern $clean $signature) -Scope $Scope `
        -Requirement 'exact present-mode copy-out signature uses expectedGeneration, swapchain, pCount, and pModes' `
        -Detail 'lsfg_interposer_bridge_get_present_modes_v2(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes) is absent'
}

function Assert-StaleBeforeCopy {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [string]$OutputPointer,
        [Parameter(Mandatory)] [string]$Scope
    )

    $body = Get-CppNamedBody -Source $Source -Name $FunctionName
    if ($null -eq $body) {
        Add-Result -Passed $false -Scope $Scope -Requirement "$FunctionName exists" -Detail 'function body was not found'
        return
    }

    $clean = Remove-CppTrivia $body
    $stale = [regex]::Match($clean, 'expectedGeneration[\s\S]{0,300}?return\s+-4\s*;')
    $firstArrayWrite = [regex]::Match($clean, "$([regex]::Escape($OutputPointer))\s*\[")
    $firstCountWrite = [regex]::Match($clean, '\*\s*pCount\s*=')
    $firstWriteIndex = $clean.Length
    if ($firstArrayWrite.Success) { $firstWriteIndex = [Math]::Min($firstWriteIndex, $firstArrayWrite.Index) }
    if ($firstCountWrite.Success) { $firstWriteIndex = [Math]::Min($firstWriteIndex, $firstCountWrite.Index) }
    $staleBeforeWrite = $stale.Success -and $stale.Index -lt $firstWriteIndex

    Add-Result -Passed $staleBeforeWrite -Scope $Scope `
        -Requirement "$FunctionName returns stale result -4 before any caller output write" `
        -Detail 'expectedGeneration must be checked before pCount or caller-buffer output'
}

function Assert-NoPartialCopyOnCapacityFailure {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [string]$OutputPointer,
        [Parameter(Mandatory)] [string]$Scope
    )

    $body = Get-CppNamedBody -Source $Source -Name $FunctionName
    if ($null -eq $body) {
        Add-Result -Passed $false -Scope $Scope -Requirement "$FunctionName rejects insufficient capacity without partial output" -Detail 'function body was not found'
        return
    }

    $clean = Remove-CppTrivia $body
    $capacityFailure = [regex]::Match(
        $clean,
        'if\s*\([^)]*(?:\*\s*pCount|capacity)[^)]*<[^)]*\)\s*\{?[\s\S]{0,240}?return\s+-(?!4\b)\d+\s*;'
    )
    $firstArrayWrite = [regex]::Match($clean, "$([regex]::Escape($OutputPointer))\s*\[")
    $noPartial = $capacityFailure.Success -and ((-not $firstArrayWrite.Success) -or $capacityFailure.Index -lt $firstArrayWrite.Index)

    Add-Result -Passed $noPartial -Scope $Scope `
        -Requirement "$FunctionName rejects insufficient caller capacity before copying" `
        -Detail 'a distinct negative capacity result must precede every caller-buffer element write'
}

function Assert-NoRealVulkanCallsUnderStateMutex {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Scope
    )

    $clean = Remove-CppTrivia $Source
    $cachedPfnNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($clean, '\bPFN_vk[A-Za-z0-9_]*\s+(?<name>[A-Za-z_]\w*)\s*(?=[=;,)])')) {
        [void]$cachedPfnNames.Add($match.Groups['name'].Value)
    }
    foreach ($name in @('g_realGipa', 'g_realGdpa', 'realGetCaps', 'realGetModes', 'realGetQueueFamilyProperties')) {
        [void]$cachedPfnNames.Add($name)
    }

    $violations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $lockPattern = '(?:std::)?(?:lock_guard|unique_lock|scoped_lock)\s*<[^;{}]+>\s+[A-Za-z_]\w*\s*\(\s*g_stateMutex\s*\)'
    foreach ($lockMatch in [regex]::Matches($clean, $lockPattern)) {
        $mutexMatch = [regex]::Match($lockMatch.Value, '\bg_stateMutex\b')
        $mutexIndex = $lockMatch.Index + $mutexMatch.Index
        $stack = [System.Collections.Generic.Stack[int]]::new()
        for ($i = 0; $i -lt $mutexIndex; $i++) {
            if ($clean[$i] -eq '{') {
                $stack.Push($i)
            } elseif ($clean[$i] -eq '}' -and $stack.Count -gt 0) {
                [void]$stack.Pop()
            }
        }
        if ($stack.Count -eq 0) {
            continue
        }

        $scopeOpen = $stack.Peek()
        $scopeClose = Get-MatchingBraceIndex -TriviaFreeSource $clean -OpenIndex $scopeOpen
        if ($scopeClose -lt 0) {
            continue
        }
        $lockedRegion = $clean.Substring($mutexIndex, $scopeClose - $mutexIndex)

        foreach ($pfnName in $cachedPfnNames) {
            $call = [regex]::Match($lockedRegion, "\b$([regex]::Escape($pfnName))\s*\(")
            if ($call.Success) {
                $absoluteIndex = $mutexIndex + $call.Index
                $line = 1 + ([regex]::Matches($clean.Substring(0, $absoluteIndex), "`n")).Count
                [void]$violations.Add("$pfnName() at line $line")
            }
        }

        foreach ($memberCall in [regex]::Matches($lockedRegion, '(?:->|\.)\s*(?<name>(?:real|get|create|destroy|acquire|queue)[A-Za-z0-9_]*)\s*\(')) {
            $absoluteIndex = $mutexIndex + $memberCall.Index
            $line = 1 + ([regex]::Matches($clean.Substring(0, $absoluteIndex), "`n")).Count
            [void]$violations.Add("cached PFN $($memberCall.Groups['name'].Value)() at line $line")
        }
    }

    $detail = if ($violations.Count -eq 0) { '' } else { ($violations | Sort-Object) -join ', ' }
    Add-Result -Passed ($violations.Count -eq 0) -Scope $Scope `
        -Requirement 'no real Vulkan call executes before any g_stateMutex lock scope closes' `
        -Detail $detail
}

function Invoke-ProducerChecks {
    $scope = 'producer'
    $source = Read-RequiredSource $ProducerPath

    Assert-AppendOnlyV2Fields -Source $source -Scope $scope
    Assert-ExactPresentModesSignature -Source $source -Scope $scope

    $metadataBody = Get-CppStructBody -Source $source -Name 'SwapchainMetadata'
    Add-Result -Passed ($null -ne $metadataBody -and (Test-Pattern $metadataBody 'std::vector\s*<\s*VkPresentModeKHR\s*>\s+supportedPresentModes\b')) `
        -Scope $scope -Requirement 'producer owns the complete present-mode list in std::vector<VkPresentModeKHR>' `
        -Detail 'SwapchainMetadata still lacks value-owned unbounded present-mode storage'

    Assert-Pattern -Text $source -Pattern '\bPFN_vkGetPhysicalDeviceQueueFamilyProperties\b' -Scope $scope `
        -Requirement 'producer resolves queue-family properties from the real Vulkan driver'
    Assert-Pattern -Text $source -Pattern '\brealGetQueueFamilyProperties\s*\(' -Scope $scope `
        -Requirement 'producer calls realGetQueueFamilyProperties for the active queue family'

    Assert-StaleBeforeCopy -Source $source -FunctionName 'lsfg_interposer_bridge_get_present_modes_v2' -OutputPointer 'pModes' -Scope $scope
    Assert-NoPartialCopyOnCapacityFailure -Source $source -FunctionName 'lsfg_interposer_bridge_get_present_modes_v2' -OutputPointer 'pModes' -Scope $scope
    Assert-StaleBeforeCopy -Source $source -FunctionName 'lsfg_interposer_bridge_get_swapchain_images_v2' -OutputPointer 'pImages' -Scope $scope
    Assert-NoPartialCopyOnCapacityFailure -Source $source -FunctionName 'lsfg_interposer_bridge_get_swapchain_images_v2' -OutputPointer 'pImages' -Scope $scope
    Assert-NoRealVulkanCallsUnderStateMutex -Source $source -Scope $scope
}

function Assert-ConsumerContract {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Scope
    )

    $source = Read-RequiredSource $Path
    $clean = Remove-CppTrivia $source

    Assert-AppendOnlyV2Fields -Source $source -Scope $Scope
    Assert-ExactPresentModesSignature -Source $source -Scope $Scope
    Assert-Pattern -Text $clean -Pattern 'PFN_lsfg_interposer_bridge_get_swapchain_images_v2[\s\S]{0,260}?uint64_t\s+expectedGeneration[\s\S]{0,260}?VkImage\s*\*\s*pImages' `
        -Scope $Scope -Requirement 'consumer declares the generation-safe swapchain-image copy-out ABI'
    Assert-Pattern -Text $clean -Pattern 'PFN_lsfg_interposer_bridge_get_present_modes_v2[\s\S]{0,260}?uint64_t\s+expectedGeneration[\s\S]{0,260}?VkPresentModeKHR\s*\*\s*pModes' `
        -Scope $Scope -Requirement 'consumer declares the exact generation-safe present-mode copy-out ABI'

    Assert-Pattern -Text $source -Pattern 'std::thread' -Scope $Scope `
        -Requirement 'consumer starts a short-lived initialization worker for the V2A.1 query'
    Assert-Pattern -Text $clean -Pattern 'for\s*\([^;]*;[^;]*<\s*3\s*;' -Scope $Scope `
        -Requirement 'consumer bounds complete stale-retry sequences to at most three attempts'
    Assert-Pattern -Text $source -Pattern '\[LSFG-V2A1\]' -Scope $Scope `
        -Requirement 'consumer emits the required one-shot [LSFG-V2A1] diagnostic label'
    Assert-Pattern -Text $clean -Pattern '(?:v2a1|metadata|snapshot)[A-Za-z0-9_]*\s*\.\s*exchange\s*\(\s*true\s*\)' -Scope $Scope `
        -Requirement 'consumer guards the V2A.1 diagnostic with one-shot atomic exchange'

    $callbackBody = Get-CppNamedBody -Source $source -Name 'lsfg_present_observer_callback_v1'
    if ($null -eq $callbackBody) {
        Add-Result -Passed $false -Scope $Scope -Requirement 'present callback is signal-only for V2A.1' -Detail 'callback body was not found'
    } else {
        $callbackClean = Remove-CppTrivia $callbackBody
        $hasSignal = Test-Pattern $callbackClean '(?:(?:v2a1|metadata|snapshot)[A-Za-z0-9_]*\s*\.\s*store\s*\(|notify_(?:one|all)\s*\()'
        $forbidden = Test-Pattern $callbackClean '(?:try_query_v2a_snapshot|getSnapshot|get_snapshot|getSwapchainImages|getPresentModes|std::vector|dlsym|new\s+|malloc\s*\()'
        Add-Result -Passed ($hasSignal -and -not $forbidden) -Scope $Scope `
            -Requirement 'present callback only signals V2A.1 readiness and performs no metadata query, allocation, or retry' `
            -Detail 'expected a V2A.1 readiness signal and no query/allocation marker in the callback body'
    }

    Assert-Pattern -Text $clean -Pattern 'std::vector\s*<\s*VkImage\s*>' -Scope $Scope `
        -Requirement 'consumer allocates caller-owned swapchain-image storage outside the present callback'
    Assert-Pattern -Text $clean -Pattern 'actualImageCount[\s\S]{0,500}?(?:!=|==)[\s\S]{0,120}?(?:imageCount|copyOutImageCount)|(?:imageCount|copyOutImageCount)[\s\S]{0,120}?(?:!=|==)[\s\S]{0,500}?actualImageCount' `
        -Scope $Scope -Requirement 'consumer validates copied image count against snapshot.actualImageCount'
    Assert-Pattern -Text $clean -Pattern 'VkImage[\s\S]{0,700}?(?:==|!=)\s*VK_NULL_HANDLE' -Scope $Scope `
        -Requirement 'consumer validates every copied swapchain image handle is non-null'

    Assert-Pattern -Text $clean -Pattern 'std::vector\s*<\s*VkPresentModeKHR\s*>' -Scope $Scope `
        -Requirement 'consumer allocates caller-owned present-mode storage'
    foreach ($mode in @('VK_PRESENT_MODE_IMMEDIATE_KHR', 'VK_PRESENT_MODE_MAILBOX_KHR', 'VK_PRESENT_MODE_FIFO_KHR', 'VK_PRESENT_MODE_FIFO_RELAXED_KHR')) {
        Assert-Pattern -Text $source -Pattern ([regex]::Escape($mode)) -Scope $Scope `
            -Requirement "consumer decodes $mode symbolically"
    }
    Assert-Pattern -Text $source -Pattern '(?:UNKNOWN|unknown|numeric)[^\r\n]*%[diu]' -Scope $Scope `
        -Requirement 'consumer retains a numeric label for unknown/vendor present modes'

    foreach ($label in @(
        'generation=',
        'currentExtent=',
        'minImageExtent=',
        'maxImageExtent=',
        'maxImageArrayLayers=',
        'supportedTransforms=',
        'currentTransform=',
        'supportedCompositeAlpha=',
        'supportedUsageFlags=',
        'queueFamilyFlags=',
        'queueFamilyQueueCount=',
        'supportedPresentModeCount=',
        'supportedPresentModes=',
        'swapchainImageCount=',
        'swapchainImageCopyOutStatus='
    )) {
        Assert-Pattern -Text $source -Pattern ([regex]::Escape($label)) -Scope $Scope `
            -Requirement "required V2A.1 log label $label is present"
    }

    Assert-Pattern -Text $clean -Pattern 'return\s+-4\s*;' -Scope $Scope `
        -Requirement 'consumer recognizes the exact stale result -4'
    Assert-Pattern -Text $clean -Pattern '(?:stale|STALE)[\s\S]{0,500}?(?:continue|retry)' -Scope $Scope `
        -Requirement 'consumer discards stale local results and retries from a fresh snapshot'
}

function Invoke-ConsumerChecks {
    Assert-ConsumerContract -Path $LsfgConsumerPath -Scope 'consumer:LS-FG'
    Assert-ConsumerContract -Path $SgsrConsumerPath -Scope 'consumer:SGSR'

    $lsfgHash = (Get-FileHash -LiteralPath $LsfgConsumerPath -Algorithm SHA256).Hash
    $sgsrHash = (Get-FileHash -LiteralPath $SgsrConsumerPath -Algorithm SHA256).Hash
    Add-Result -Passed ($lsfgHash -eq $sgsrHash) -Scope 'consumer:mirror' `
        -Requirement 'LS-FG and SGSR mirrored consumer sources have identical SHA-256 hashes' `
        -Detail "LS-FG=$lsfgHash SGSR=$sgsrHash"
}

Write-Output "LSFG Bridge V2A.1 contract test (stage=$Stage)"

try {
    if ($Stage -in @('producer', 'full')) {
        Invoke-ProducerChecks
    }
    if ($Stage -in @('consumer', 'full')) {
        Invoke-ConsumerChecks
    }
} catch {
    Write-Error "Contract test infrastructure error: $($_.Exception.Message)"
    exit 2
}

Write-Output "SUMMARY checks=$script:Checks failures=$($script:Failures.Count)"
if ($script:Failures.Count -gt 0) {
    Write-Output 'V2A.1 CONTRACT: FAIL'
    exit 1
}

Write-Output 'V2A.1 CONTRACT: PASS'
exit 0
