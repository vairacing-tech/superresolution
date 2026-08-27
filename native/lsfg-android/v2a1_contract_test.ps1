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

function Get-MatchingBraceIndex {
    param([string]$TriviaFreeSource, [int]$OpenIndex)
    $depth = 0
    for ($i = $OpenIndex; $i -lt $TriviaFreeSource.Length; $i++) {
        if ($TriviaFreeSource[$i] -eq '{') { $depth++ }
        elseif ($TriviaFreeSource[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function Get-EnclosingScopeClose {
    param([string]$TriviaFreeSource, [int]$Index)
    $stack = [System.Collections.Generic.Stack[int]]::new()
    for ($i = 0; $i -lt $Index; $i++) {
        if ($TriviaFreeSource[$i] -eq '{') { $stack.Push($i) }
        elseif ($TriviaFreeSource[$i] -eq '}' -and $stack.Count -gt 0) { [void]$stack.Pop() }
    }
    if ($stack.Count -eq 0) { return $TriviaFreeSource.Length }
    return Get-MatchingBraceIndex -TriviaFreeSource $TriviaFreeSource -OpenIndex $stack.Peek()
}

function Get-CppFunctionInfos {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    # Function-like compiler attributes can otherwise greedily consume the real
    # signature and make the attribute name look like the function name.
    $scanChars = $clean.ToCharArray()
    foreach ($attribute in [regex]::Matches($clean, '__attribute__\s*\(\([^;{}]*?\)\)')) {
        for ($i = $attribute.Index; $i -lt $attribute.Index + $attribute.Length; $i++) {
            if ($scanChars[$i] -ne "`r" -and $scanChars[$i] -ne "`n") { $scanChars[$i] = ' ' }
        }
    }
    $scanClean = -join $scanChars
    $controlWords = @('if', 'for', 'while', 'switch', 'catch')
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $functions = [System.Collections.Generic.List[object]]::new()
    $pattern = '\b(?<name>[A-Za-z_~][A-Za-z0-9_]*)\s*\([^;{}]*\)\s*(?:const\s*)?(?:noexcept(?:\s*\([^)]*\))?\s*)?(?:->\s*[^{}]+)?\{'
    foreach ($match in [regex]::Matches($scanClean, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $name = $match.Groups['name'].Value
        if ($name -in $controlWords) { continue }
        $openIndex = $scanClean.IndexOf('{', $match.Index)
        if ($openIndex -lt 0 -or -not $seen.Add($openIndex)) { continue }
        $closeIndex = Get-MatchingBraceIndex $clean $openIndex
        if ($closeIndex -lt 0) { continue }
        $functions.Add([pscustomobject]@{
            Name = $name; OpenIndex = $openIndex; CloseIndex = $closeIndex; BodyStart = $openIndex + 1
            Body = $Source.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
            CleanBody = $clean.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
        })
    }
    return @($functions)
}

function Get-CppNamedBody {
    param([string]$Source, [string]$Name)
    $info = @(Get-CppFunctionInfos $Source | Where-Object Name -eq $Name | Select-Object -First 1)
    if ($info.Count -eq 0) { return $null }
    return $info[0].Body
}

function Get-CppStructBody {
    param([string]$Source, [string]$Name)
    $clean = Remove-CppTrivia $Source
    $match = [regex]::Match($clean, "\bstruct\s+$([regex]::Escape($Name))\s*\{")
    if (-not $match.Success) { return $null }
    $openIndex = $clean.IndexOf('{', $match.Index)
    $closeIndex = Get-MatchingBraceIndex $clean $openIndex
    if ($closeIndex -lt 0) { return $null }
    return $Source.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
}

function Test-Pattern {
    param([string]$Text, [string]$Pattern)
    return [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

function Assert-Pattern {
    param([string]$Text, [string]$Pattern, [string]$Scope, [string]$Requirement, [string]$MissingDetail = 'required implementation marker is absent')
    Add-Result (Test-Pattern $Text $Pattern) $Scope $Requirement $MissingDetail
}

function Normalize-CppLayout {
    param([string]$Text)
    $normalized = [regex]::Replace((Remove-CppTrivia $Text), '\s+', ' ').Trim()
    return [regex]::Replace($normalized, '\s*([\[\];,])\s*', '$1')
}

function Test-V2AbiLayout {
    param([string]$Source)
    $body = Get-CppStructBody $Source 'LsfgBridgeSnapshotV2'
    if ($null -eq $body) { return [pscustomobject]@{ Prefix = $false; Append = $false } }
    $expectedPrefix = @(
        'uint32_t abiVersion;', 'uint32_t structSize;', 'uint64_t generation;',
        'VkInstance instance;', 'VkPhysicalDevice physicalDevice;', 'VkDevice device;',
        'VkQueue presentQueue;', 'uint32_t queueFamilyIndex;', 'uint32_t queueIndex;', 'VkDeviceQueueCreateFlags queueFlags;',
        'VkSurfaceKHR surface;', 'VkSwapchainKHR swapchain;', 'VkFormat imageFormat;', 'VkColorSpaceKHR imageColorSpace;',
        'VkExtent2D imageExtent;', 'uint32_t imageArrayLayers;', 'VkImageUsageFlags imageUsage;',
        'VkSharingMode imageSharingMode;', 'VkSurfaceTransformFlagBitsKHR preTransform;',
        'VkCompositeAlphaFlagBitsKHR compositeAlpha;', 'VkPresentModeKHR presentMode;', 'VkBool32 clipped;',
        'VkSwapchainKHR oldSwapchain;', 'uint32_t requestedMinImageCount;', 'uint32_t actualImageCount;',
        'uint32_t imageCapacity;', 'VkImage images[LSFG_BRIDGE_MAX_SWAPCHAIN_IMAGES];',
        'VkSurfaceCapabilitiesKHR surfaceCapabilities;', 'uint32_t supportedPresentModeCount;',
        'uint32_t presentModeCapacity;', 'VkPresentModeKHR supportedPresentModes[LSFG_BRIDGE_MAX_PRESENT_MODES];',
        'uint32_t validMask;'
    ) -join ''
    $expectedAppend = 'VkQueueFlags queueFamilyFlags;uint32_t queueFamilyQueueCount;'
    $normalizedBody = (Normalize-CppLayout $body) -replace '; ', ';'
    return [pscustomobject]@{
        Prefix = $normalizedBody.StartsWith($expectedPrefix, [System.StringComparison]::Ordinal)
        Append = $normalizedBody.StartsWith($expectedPrefix + $expectedAppend, [System.StringComparison]::Ordinal)
    }
}

function Assert-V2AbiLayout {
    param([string]$Source, [string]$Scope)
    $layout = Test-V2AbiLayout $Source
    Add-Result $layout.Prefix $Scope 'the complete pre-existing LsfgBridgeSnapshotV2 ABI prefix through validMask is byte-order unchanged' 'an old V2 field is missing, reordered, retyped, or has an inserted field before validMask'
    Add-Result $layout.Append $Scope 'VkQueueFlags queueFamilyFlags and uint32_t queueFamilyQueueCount append immediately after validMask' 'the exact V2A.1 append order is absent'
}

function Assert-ExactPresentModesSignature {
    param([string]$Source, [string]$Scope)
    $signature = 'lsfg_interposer_bridge_get_present_modes_v2\s*\(\s*uint64_t\s+expectedGeneration\s*,\s*VkSwapchainKHR\s+swapchain\s*,\s*uint32_t\s*\*\s*pCount\s*,\s*VkPresentModeKHR\s*\*\s*pModes\s*\)'
    Add-Result (Test-Pattern (Remove-CppTrivia $Source) $signature) $Scope 'exact present-mode copy-out signature uses expectedGeneration, swapchain, pCount, and pModes' 'the exact required signature is absent'
}

function Get-StateMutexLockIntervals {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $intervals = [System.Collections.Generic.List[object]]::new()
    $recognized = [System.Collections.Generic.List[object]]::new()
    $raiiPattern = '(?:std::)?(?<kind>lock_guard|unique_lock|scoped_lock)\s*(?:<[^;{}]+>)?\s+(?<var>[A-Za-z_]\w*)\s*(?:\(\s*g_stateMutex\s*\)|\{\s*g_stateMutex\s*\})\s*;'
    foreach ($match in [regex]::Matches($clean, $raiiPattern)) {
        $end = Get-EnclosingScopeClose $clean $match.Index
        $varName = $match.Groups['var'].Value
        $tailLength = [Math]::Max(0, $end - $match.Index - $match.Length)
        $unlock = [regex]::Match($clean.Substring($match.Index + $match.Length, $tailLength), "\b$([regex]::Escape($varName))\s*\.\s*unlock\s*\(\s*\)")
        if ($unlock.Success) { $end = $match.Index + $match.Length + $unlock.Index }
        $intervals.Add([pscustomobject]@{ Start = $match.Index; End = $end; Form = $match.Groups['kind'].Value })
        $recognized.Add([pscustomobject]@{ Start = $match.Index; End = $match.Index + $match.Length })
    }
    foreach ($match in [regex]::Matches($clean, '\bg_stateMutex\s*\.\s*lock\s*\(\s*\)\s*;')) {
        $scopeEnd = Get-EnclosingScopeClose $clean $match.Index
        $tailLength = [Math]::Max(0, $scopeEnd - $match.Index - $match.Length)
        $unlock = [regex]::Match($clean.Substring($match.Index + $match.Length, $tailLength), '\bg_stateMutex\s*\.\s*unlock\s*\(\s*\)\s*;')
        $end = if ($unlock.Success) { $match.Index + $match.Length + $unlock.Index } else { $scopeEnd }
        $intervals.Add([pscustomobject]@{ Start = $match.Index; End = $end; Form = 'manual' })
        $recognized.Add([pscustomobject]@{ Start = $match.Index; End = $match.Index + $match.Length })
        if ($unlock.Success) {
            $unlockStart = $match.Index + $match.Length + $unlock.Index
            $recognized.Add([pscustomobject]@{ Start = $unlockStart; End = $unlockStart + $unlock.Length })
        }
    }
    return [pscustomobject]@{ Clean = $clean; Intervals = @($intervals); Recognized = @($recognized) }
}

function Get-CachedRealVulkanPfnNames {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in @('g_realGipa', 'g_realGdpa', 'realGetCaps', 'realGetModes', 'realGetQueueFamilyProperties')) { [void]$names.Add($name) }
    foreach ($match in [regex]::Matches($clean, '\bPFN_vk[A-Za-z0-9_]*\s+(?<name>[A-Za-z_]\w*)\s*(?=[=;,)])')) { [void]$names.Add($match.Groups['name'].Value) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($assignment in [regex]::Matches($clean, '(?:\b(?:auto|PFN_vk[A-Za-z0-9_]*)\s+)?\b(?<lhs>[A-Za-z_]\w*)\s*=\s*(?<rhs>[^;]+);')) {
            foreach ($known in @($names)) {
                if (Test-Pattern $assignment.Groups['rhs'].Value "(?:\b|(?:->|\.))$([regex]::Escape($known))\b") {
                    if ($names.Add($assignment.Groups['lhs'].Value)) { $changed = $true }
                    break
                }
            }
        }
    }
    return $names
}

function Find-RealVulkanCallsUnderStateMutex {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $lockData = Get-StateMutexLockIntervals $Source
    $pfnNames = Get-CachedRealVulkanPfnNames $Source
    $violations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($function in Get-CppFunctionInfos $Source) {
        if (-not (Test-Pattern $function.CleanBody '\bg_stateMutex\b')) { continue }
        $functionIntervals = @($lockData.Intervals | Where-Object { $_.Start -gt $function.OpenIndex -and $_.Start -lt $function.CloseIndex })
        foreach ($mutexUse in [regex]::Matches($function.CleanBody, '\bg_stateMutex\b')) {
            $absoluteUse = $function.BodyStart + $mutexUse.Index
            $knownUse = @($lockData.Recognized | Where-Object { $absoluteUse -ge $_.Start -and $absoluteUse -lt $_.End }).Count -gt 0
            if (-not $knownUse) { [void]$violations.Add("$($function.Name): unrecognized g_stateMutex locking form") }
        }
        foreach ($pfnName in @($pfnNames)) {
            $callPatterns = @("\b$([regex]::Escape($pfnName))\s*\(", "(?:->|\.)\s*$([regex]::Escape($pfnName))\s*\(")
            foreach ($callPattern in $callPatterns) {
                foreach ($call in [regex]::Matches($function.CleanBody, $callPattern)) {
                    $absoluteCall = $function.BodyStart + $call.Index
                    $active = @($functionIntervals | Where-Object { $absoluteCall -ge $_.Start -and $absoluteCall -lt $_.End }).Count -gt 0
                    if ($active) {
                        $line = 1 + ([regex]::Matches($clean.Substring(0, $absoluteCall), "`n")).Count
                        [void]$violations.Add("$($function.Name): cached real Vulkan PFN $pfnName() at line $line")
                    }
                }
            }
        }
    }
    return @($violations | Sort-Object)
}

function Assert-NoRealVulkanCallsUnderStateMutex {
    param([string]$Source, [string]$Scope)
    $violations = @(Find-RealVulkanCallsUnderStateMutex $Source)
    Add-Result ($violations.Count -eq 0) $Scope 'every function containing g_stateMutex has recognized lock scopes and no real Vulkan PFN call while locked' ($violations -join ', ')
}

function Get-CallerOutputWrites {
    param([string]$Text, [string]$OutputPointer, [switch]$IncludeCount)
    $clean = Remove-CppTrivia $Text
    $pointer = [regex]::Escape($OutputPointer)
    $writes = [System.Collections.Generic.List[object]]::new()
    $patterns = @(
        @{ Kind = 'array write'; Regex = "\b$pointer\s*\[[^\]]*\]\s*(?:[+\-*/%]?=|\+\+|--)" },
        @{ Kind = 'pointer write'; Regex = "\*\s*\(?\s*$pointer(?:\s*\+\+|\s*--)?\s*\)?\s*(?:[+\-*/%]?=|\+\+|--)" },
        @{ Kind = 'memcpy/memmove'; Regex = "\b(?:std::)?mem(?:cpy|move)\s*\(\s*$pointer\b" },
        @{ Kind = 'std copy'; Regex = "\bstd::(?:(?:ranges)::)?copy(?:_n)?\s*\([^;]*,\s*$pointer(?:\s*[+\-][^)]*)?\s*\)" },
        @{ Kind = 'std transform/fill'; Regex = "\bstd::(?:transform|fill(?:_n)?)\s*\([^;]*,\s*$pointer(?:\s*[+\-][^)]*)?\s*\)" }
    )
    if ($IncludeCount) { $patterns += @{ Kind = 'count write'; Regex = '\*\s*pCount\s*(?:[+\-*/%]?=|\+\+|--)' } }
    foreach ($entry in $patterns) {
        foreach ($match in [regex]::Matches($clean, $entry.Regex)) {
            $writes.Add([pscustomobject]@{ Index = $match.Index; Kind = $entry.Kind; Text = $match.Value })
        }
    }
    return @($writes | Sort-Object Index, Kind -Unique)
}

function Get-CopyOutAnalysis {
    param([string]$Source, [string]$FunctionName, [string]$OutputPointer)
    $body = Get-CppNamedBody $Source $FunctionName
    if ($null -eq $body) { return [pscustomobject]@{ Exists = $false; StaleDominates = $false; Coherent = $false; CapacitySafe = $false; Detail = 'function body was not found' } }
    $clean = Remove-CppTrivia $body
    $allWrites = @(Get-CallerOutputWrites $body $OutputPointer -IncludeCount)
    $dataWrites = @(Get-CallerOutputWrites $body $OutputPointer)
    $staleMatch = [regex]::Match($clean, 'expectedGeneration[\s\S]{0,360}?return\s+-4\s*;')
    $staleDominates = $staleMatch.Success -and $allWrites.Count -gt 0
    if ($staleDominates) { $staleDominates = @($allWrites | Where-Object { $_.Index -le ($staleMatch.Index + $staleMatch.Length) }).Count -eq 0 }
    $lockData = Get-StateMutexLockIntervals $body
    $coherent = $false
    if ($staleMatch.Success -and $allWrites.Count -gt 0) {
        foreach ($interval in $lockData.Intervals) {
            $staleInside = $staleMatch.Index -ge $interval.Start -and ($staleMatch.Index + $staleMatch.Length) -lt $interval.End
            $allWritesInside = @($allWrites | Where-Object { $_.Index -lt $interval.Start -or $_.Index -ge $interval.End }).Count -eq 0
            if ($staleInside -and $allWritesInside) { $coherent = $true; break }
        }
    }
    $capacityMatch = [regex]::Match($clean, 'if\s*\([^{};]*(?:\*\s*pCount|capacity)[^{};]*<[^{};]*\)\s*\{?[\s\S]{0,300}?return\s+-(?!4\b)\d+\s*;')
    $firstDataWrite = if ($dataWrites.Count -gt 0) { $dataWrites[0].Index } else { -1 }
    $capacitySafe = $capacityMatch.Success -and $firstDataWrite -ge 0 -and $capacityMatch.Index -lt $firstDataWrite
    if (Test-Pattern $clean '(?:std::min\s*\(\s*\*\s*pCount|\btoCopy\b[\s\S]{0,160}?return\s+0)') { $capacitySafe = $false }
    $details = [System.Collections.Generic.List[string]]::new()
    if (-not $staleDominates) { $details.Add('stale -4 does not precede every pCount/buffer write') }
    if (-not $coherent) { $details.Add('stale check and all caller writes are not one coherent g_stateMutex-locked copy') }
    if (-not $capacitySafe) { $details.Add('insufficient capacity can reach a partial/unchecked data write') }
    return [pscustomobject]@{ Exists = $true; StaleDominates = $staleDominates; Coherent = $coherent; CapacitySafe = $capacitySafe; Detail = ($details -join '; ') }
}

function Assert-CopyOutContract {
    param([string]$Source, [string]$FunctionName, [string]$OutputPointer, [string]$Scope)
    $analysis = Get-CopyOutAnalysis $Source $FunctionName $OutputPointer
    Add-Result $analysis.Exists $Scope "$FunctionName exists" $analysis.Detail
    if (-not $analysis.Exists) { return }
    Add-Result $analysis.StaleDominates $Scope "$FunctionName returns stale -4 before every count, array, pointer, memcpy, or std::copy output write" $analysis.Detail
    Add-Result $analysis.Coherent $Scope "$FunctionName performs one coherent generation check and caller copy under g_stateMutex" $analysis.Detail
    Add-Result $analysis.CapacitySafe $Scope "$FunctionName rejects insufficient capacity before any caller-buffer data write and never reports partial success" $analysis.Detail
}

function Assert-ExistingValidityBits {
    param([string]$Source, [string]$Scope)
    foreach ($entry in @(
        @{ Bit = '0x01'; Word = 'Core'; Meaning = 'core handles' }, @{ Bit = '0x02'; Word = 'Queue'; Meaning = 'queue' },
        @{ Bit = '0x04'; Word = 'Swapchain'; Meaning = 'swapchain' }, @{ Bit = '0x08'; Word = 'Images'; Meaning = 'images' },
        @{ Bit = '0x10'; Word = 'Surface'; Meaning = 'surface capabilities' }, @{ Bit = '0x20'; Word = 'Present'; Meaning = 'present modes' }
    )) {
        $pattern = "validMask\s*\|=\s*$([regex]::Escape($entry.Bit))(?:u|U)?\s*;[^`r`n]*$($entry.Word)"
        Add-Result (Test-Pattern $Source $pattern) $Scope "existing validity bit $($entry.Bit) remains assigned to $($entry.Meaning)" 'the pre-existing V2 validity-bit mapping changed or disappeared'
    }
}

function Assert-StructSizeBoundedSnapshotCopy {
    param([string]$Source, [string]$Scope)
    $body = Get-CppNamedBody $Source 'lsfg_interposer_bridge_get_snapshot_v2'
    if ($null -eq $body) { Add-Result $false $Scope 'snapshot V2 uses structSize-gated bounded copying' 'snapshot function body was not found'; return }
    $clean = Remove-CppTrivia $body
    $gate = Test-Pattern $clean 'outSnapshot\s*->\s*structSize\s*<\s*LSFG_BRIDGE_SNAPSHOT_V2_MIN_SIZE[\s\S]{0,120}?return\s+-3'
    $bound = Test-Pattern $clean 'std::min\s*\([^;]*callerSize[^;]*sizeof\s*\(\s*LsfgBridgeSnapshotV2\s*\)'
    $copy = Test-Pattern $clean '(?:std::)?memcpy\s*\(\s*outSnapshot\s*,\s*&\s*hostSnapshot\s*,\s*copyBytes\s*\)'
    Add-Result ($gate -and $bound -and $copy) $Scope 'snapshot V2 retains the minimum structSize gate and copies only min(callerSize, producerSize)' 'minimum-size rejection, bounded size calculation, or bounded memcpy is absent'
}

function Get-V2A1PathFunctions {
    param([string]$Source)
    return @(Get-CppFunctionInfos $Source | Where-Object { $_.Name -match '(?i)(v2a1|v2a_snapshot|metadata.*(?:worker|probe)|snapshot.*(?:worker|probe))' })
}

function Find-PassivePathViolations {
    param([string]$Source)
    $violations = [System.Collections.Generic.List[string]]::new()
    $cachedVulkanPfns = Get-CachedRealVulkanPfnNames $Source
    $forbiddenCall = '\b(?:vk|lsfg_vk|g_real)(?:AcquireNextImage(?:2)?KHR|QueuePresentKHR|QueueSubmit(?:2)?|WaitForFences|ResetFences|CreateFence|CreateSemaphore|SignalSemaphore|WaitSemaphores|CmdPipelineBarrier(?:2)?|CmdCopyImage(?:2)?|CmdBlitImage(?:2)?|CmdResolveImage(?:2)?|CmdDispatch(?:Base)?)\s*\('
    $forbiddenMutation = '(?:(?:pCreateInfo|createInfo|swapchainInfo)\s*(?:->|\.)\s*(?:presentMode|minImageCount)|\b(?:oldLayout|newLayout)\b)\s*='
    $forbiddenCompute = '\b(?:lsfg|framegen|frame_generation)[A-Za-z0-9_]*(?:compute|dispatch)[A-Za-z0-9_]*\s*\('
    foreach ($function in Get-V2A1PathFunctions $Source) {
        $clean = Remove-CppTrivia $function.Body
        if (Test-Pattern $clean $forbiddenCall) { $violations.Add("$($function.Name): active Vulkan operation") }
        if (Test-Pattern $clean $forbiddenMutation) { $violations.Add("$($function.Name): layout/present-mode/image-count mutation") }
        if (Test-Pattern $clean $forbiddenCompute) { $violations.Add("$($function.Name): LSFG/frame-generation compute") }
        foreach ($pfnName in @($cachedVulkanPfns)) {
            if (Test-Pattern $clean "(?:\b|(?:->|\.))$([regex]::Escape($pfnName))\s*\(") {
                $violations.Add("$($function.Name): cached real Vulkan PFN $pfnName()")
            }
        }
    }
    return @($violations)
}

function Assert-ConsumerWorkerAndPassivePath {
    param([string]$Source, [string]$Scope)
    $functions = @(Get-CppFunctionInfos $Source)
    $worker = @($functions | Where-Object Name -match '(?i)(?:v2a1|metadata).*(?:worker)|(?:worker).*(?:v2a1|metadata)' | Select-Object -First 1)
    $workerExists = $worker.Count -eq 1
    Add-Result $workerExists $Scope 'consumer defines a dedicated short-lived V2A.1 initialization worker' 'no V2A.1/metadata worker function was found'
    if ($workerExists) {
        $launch = Test-Pattern $Source "std::thread[\s\S]{0,240}?\b$([regex]::Escape($worker[0].Name))\b"
        $oneShot = Test-Pattern (Remove-CppTrivia $Source) '(?:v2a1|metadata)[A-Za-z0-9_]*(?:worker|started)[A-Za-z0-9_]*\s*\.\s*exchange\s*\(\s*true\s*\)'
        Add-Result ($launch -and $oneShot) $Scope 'consumer starts the V2A.1 worker once behind an atomic one-shot gate' 'thread launch or atomic worker-start exchange is absent'
        Add-Result (Test-Pattern $worker[0].CleanBody 'for\s*\([^;]*;[^;]*<\s*3\s*;') $Scope 'worker bounds complete stale-retry sequences to at most three attempts' 'the worker lacks a literal three-attempt bound'
    } else {
        Add-Result $false $Scope 'consumer starts the V2A.1 worker once behind an atomic one-shot gate' 'worker is absent'
        Add-Result $false $Scope 'worker bounds complete stale-retry sequences to at most three attempts' 'worker is absent'
    }
    $callback = Get-CppNamedBody $Source 'lsfg_present_observer_callback_v1'
    if ($null -eq $callback) { Add-Result $false $Scope 'present callback is signal-only for V2A.1' 'callback body was not found' }
    else {
        $callbackClean = Remove-CppTrivia $callback
        $signal = Test-Pattern $callbackClean '(?:(?:v2a1|metadata|snapshot)[A-Za-z0-9_]*\s*\.\s*(?:store|exchange)\s*\(|notify_(?:one|all)\s*\()'
        $forbidden = Test-Pattern $callbackClean '(?:try_query_v2a_snapshot|getSnapshot|get_snapshot|getSwapchainImages|getPresentModes|std::vector|dlsym|new\s+|malloc\s*\(|for\s*\()'
        Add-Result ($signal -and -not $forbidden) $Scope 'present callback only signals V2A.1 readiness and performs no query, allocation, or retry' 'expected a V2A.1 readiness signal and no query/allocation/retry marker'
    }
    $passiveViolations = @(Find-PassivePathViolations $Source)
    Add-Result ($passiveViolations.Count -eq 0) $Scope 'V2A.1 paths contain no acquire, present, submit, synchronization, layout, image-content-copy, mode/count mutation, or LSFG compute operation' ($passiveViolations -join ', ')
}

function Invoke-DetectorSelfChecks {
    $triviaFixture = @'
const char *text = "escaped quote: \" // still in string";
realGetModes(); // this call must remain visible
'@
    Assert-SelfCheck (Test-Pattern (Remove-CppTrivia $triviaFixture) '\brealGetModes\s*\(') 'C++ escaped quote preserves following code'
    $lockTemplateBrace = @'
PFN_vkQueuePresentKHR cachedPresent;
void bad_template_brace() { std::lock_guard<std::mutex> lock{g_stateMutex}; cachedPresent(queue, info); }
'@
    $lockCtad = @'
PFN_vkQueuePresentKHR cachedPresent;
void bad_ctad() { std::lock_guard lock(g_stateMutex); cachedPresent(queue, info); }
'@
    $lockManualAlias = @'
struct DeviceState { PFN_vkQueuePresentKHR queuePresent; };
void bad_manual_alias() { auto cachedCall = state.queuePresent; g_stateMutex.lock(); cachedCall(queue, info); g_stateMutex.unlock(); }
'@
    $lockSafe = @'
PFN_vkQueuePresentKHR cachedPresent;
void safe_call() { { std::lock_guard<std::mutex> lock{g_stateMutex}; state = 1; } cachedPresent(queue, info); }
'@
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockTemplateBrace).Count -gt 0) 'lock audit rejects template brace-init lock_guard call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockCtad).Count -gt 0) 'lock audit rejects CTAD lock_guard call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockManualAlias).Count -gt 0) 'lock audit rejects manual lock cached-PFN alias call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockSafe).Count -eq 0) 'lock audit accepts real Vulkan call after lock closes'
    foreach ($fixture in @(
        @{ Text = 'memcpy(pModes, cached.data(), bytes);'; Kind = 'memcpy/memmove' },
        @{ Text = 'std::copy(cached.begin(), cached.end(), pModes);'; Kind = 'std copy' },
        @{ Text = '*pModes++ = mode;'; Kind = 'pointer write' }
    )) {
        $writes = @(Get-CallerOutputWrites $fixture.Text 'pModes')
        Assert-SelfCheck (@($writes | Where-Object Kind -eq $fixture.Kind).Count -gt 0) "output audit detects $($fixture.Kind)"
    }
    $goodCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != 0 && expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (pModes == nullptr) { *pCount = required; return 0; }
 if (*pCount < required) { return -5; } std::copy(cachedModes.begin(), cachedModes.end(), pModes); *pCount = required; return 0;
}
'@
    $badCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); *pModes++ = cachedModes[0];
 if (expectedGeneration != generation) { return -4; } return 0;
}
'@
    $goodAnalysis = Get-CopyOutAnalysis $goodCopy 'copy_modes' 'pModes'
    $badAnalysis = Get-CopyOutAnalysis $badCopy 'copy_modes' 'pModes'
    Assert-SelfCheck ($goodAnalysis.StaleDominates -and $goodAnalysis.Coherent -and $goodAnalysis.CapacitySafe) 'copy-out audit accepts coherent locked non-partial copy'
    Assert-SelfCheck (-not $badAnalysis.StaleDominates) 'copy-out audit rejects caller write before stale check'
    $abiGood = @'
struct LsfgBridgeSnapshotV2 {
uint32_t abiVersion; uint32_t structSize; uint64_t generation; VkInstance instance; VkPhysicalDevice physicalDevice; VkDevice device;
VkQueue presentQueue; uint32_t queueFamilyIndex; uint32_t queueIndex; VkDeviceQueueCreateFlags queueFlags; VkSurfaceKHR surface; VkSwapchainKHR swapchain;
VkFormat imageFormat; VkColorSpaceKHR imageColorSpace; VkExtent2D imageExtent; uint32_t imageArrayLayers; VkImageUsageFlags imageUsage; VkSharingMode imageSharingMode;
VkSurfaceTransformFlagBitsKHR preTransform; VkCompositeAlphaFlagBitsKHR compositeAlpha; VkPresentModeKHR presentMode; VkBool32 clipped; VkSwapchainKHR oldSwapchain;
uint32_t requestedMinImageCount; uint32_t actualImageCount; uint32_t imageCapacity; VkImage images[LSFG_BRIDGE_MAX_SWAPCHAIN_IMAGES];
VkSurfaceCapabilitiesKHR surfaceCapabilities; uint32_t supportedPresentModeCount; uint32_t presentModeCapacity;
VkPresentModeKHR supportedPresentModes[LSFG_BRIDGE_MAX_PRESENT_MODES]; uint32_t validMask; VkQueueFlags queueFamilyFlags; uint32_t queueFamilyQueueCount;
};
'@
    $abiBad = $abiGood.Replace('VkFormat imageFormat;', 'uint32_t insertedField; VkFormat imageFormat;')
    Assert-SelfCheck ((Test-V2AbiLayout $abiGood).Append) 'ABI audit accepts exact append-only layout'
    Assert-SelfCheck (-not (Test-V2AbiLayout $abiBad).Prefix) 'ABI audit rejects insertion into old V2 prefix'
    $passiveBad = 'void v2a1_metadata_worker() { vkQueueSubmit(queue, 1, submits, fence); }'
    $passiveCachedBad = 'PFN_vkQueuePresentKHR cachedPresent; void v2a1_metadata_worker() { cachedPresent(queue, info); }'
    $passiveOutside = 'void v2a1_metadata_worker() { query_metadata(); } void lsfg_vkQueuePresentKHR() { vkQueuePresentKHR(queue, info); }'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveBad).Count -gt 0) 'passive audit rejects active Vulkan operation in V2A.1 path'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveCachedBad).Count -gt 0) 'passive audit rejects cached Vulkan PFN in V2A.1 path'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveOutside).Count -eq 0) 'passive audit ignores existing wrapper outside V2A.1 path'
}

function Invoke-ProducerChecks {
    $scope = 'producer'; $source = Read-RequiredSource $ProducerPath
    Assert-V2AbiLayout $source $scope
    Assert-ExistingValidityBits $source $scope
    Assert-Pattern $source 'validMask\s*\|=\s*0x40(?:u|U)?\s*;[^\r\n]*(?:queue|Queue)' $scope 'new queue-family capability validity bit is append-only value 0x40'
    Assert-StructSizeBoundedSnapshotCopy $source $scope
    Assert-ExactPresentModesSignature $source $scope
    $metadataBody = Get-CppStructBody $source 'SwapchainMetadata'
    Add-Result ($null -ne $metadataBody -and (Test-Pattern $metadataBody 'std::vector\s*<\s*VkPresentModeKHR\s*>\s+supportedPresentModes\b')) $scope 'producer owns the complete present-mode list in std::vector<VkPresentModeKHR>' 'SwapchainMetadata lacks value-owned unbounded present-mode storage'
    Assert-Pattern $source '\bPFN_vkGetPhysicalDeviceQueueFamilyProperties\b' $scope 'producer resolves queue-family properties from the real Vulkan driver'
    Assert-Pattern $source '\brealGetQueueFamilyProperties\s*\(' $scope 'producer calls realGetQueueFamilyProperties for the active queue family'
    Assert-CopyOutContract $source 'lsfg_interposer_bridge_get_present_modes_v2' 'pModes' $scope
    Assert-CopyOutContract $source 'lsfg_interposer_bridge_get_swapchain_images_v2' 'pImages' $scope
    Assert-NoRealVulkanCallsUnderStateMutex $source $scope
}

function Assert-ConsumerContract {
    param([string]$Path, [string]$Scope)
    $source = Read-RequiredSource $Path; $clean = Remove-CppTrivia $source
    Assert-V2AbiLayout $source $Scope
    Assert-ExactPresentModesSignature $source $Scope
    Assert-Pattern $clean 'PFN_lsfg_interposer_bridge_get_swapchain_images_v2[\s\S]{0,300}?uint64_t\s+expectedGeneration[\s\S]{0,300}?VkImage\s*\*\s*pImages' $Scope 'consumer declares the generation-safe swapchain-image copy-out ABI'
    Assert-Pattern $clean 'PFN_lsfg_interposer_bridge_get_present_modes_v2[\s\S]{0,300}?uint64_t\s+expectedGeneration[\s\S]{0,300}?VkPresentModeKHR\s*\*\s*pModes' $Scope 'consumer declares the exact generation-safe present-mode copy-out ABI'
    Assert-Pattern $source '(?:validMask\s*&\s*0x40|LSFG_BRIDGE_VALID_[A-Za-z0-9_]*QUEUE[A-Za-z0-9_]*\s*=\s*0x40)' $Scope 'consumer mirrors the new queue-family validity bit at append-only value 0x40'
    Assert-ConsumerWorkerAndPassivePath $source $Scope
    Assert-Pattern $source '\[LSFG-V2A1\]' $Scope 'consumer emits the required one-shot [LSFG-V2A1] diagnostic label'
    Assert-Pattern $clean '(?:v2a1|metadata|snapshot)[A-Za-z0-9_]*\s*\.\s*exchange\s*\(\s*true\s*\)' $Scope 'consumer guards the V2A.1 diagnostic with one-shot atomic exchange'
    Assert-Pattern $clean 'std::vector\s*<\s*VkImage\s*>' $Scope 'consumer allocates caller-owned swapchain-image storage outside the present callback'
    Assert-Pattern $clean 'actualImageCount[\s\S]{0,500}?(?:!=|==)[\s\S]{0,120}?(?:imageCount|copyOutImageCount)|(?:imageCount|copyOutImageCount)[\s\S]{0,120}?(?:!=|==)[\s\S]{0,500}?actualImageCount' $Scope 'consumer validates copied image count against snapshot.actualImageCount'
    Assert-Pattern $clean 'VkImage[\s\S]{0,700}?(?:==|!=)\s*VK_NULL_HANDLE' $Scope 'consumer validates every copied swapchain image handle is non-null'
    Assert-Pattern $clean 'std::vector\s*<\s*VkPresentModeKHR\s*>' $Scope 'consumer allocates caller-owned present-mode storage'
    foreach ($mode in @('VK_PRESENT_MODE_IMMEDIATE_KHR', 'VK_PRESENT_MODE_MAILBOX_KHR', 'VK_PRESENT_MODE_FIFO_KHR', 'VK_PRESENT_MODE_FIFO_RELAXED_KHR')) { Assert-Pattern $source ([regex]::Escape($mode)) $Scope "consumer decodes $mode symbolically" }
    Assert-Pattern $source '(?:UNKNOWN|unknown|numeric)[^\r\n]*%[diu]' $Scope 'consumer retains a numeric label for unknown/vendor present modes'
    foreach ($label in @('generation=', 'currentExtent=', 'minImageExtent=', 'maxImageExtent=', 'maxImageArrayLayers=', 'supportedTransforms=', 'currentTransform=', 'supportedCompositeAlpha=', 'supportedUsageFlags=', 'queueFamilyFlags=', 'queueFamilyQueueCount=', 'supportedPresentModeCount=', 'supportedPresentModes=', 'swapchainImageCount=', 'swapchainImageCopyOutStatus=')) { Assert-Pattern $source ([regex]::Escape($label)) $Scope "required V2A.1 log label $label is present" }
    Assert-Pattern $clean '(?:==|!=)\s*-4\b|\b-4\s*(?:==|!=)' $Scope 'consumer recognizes the exact stale result -4'
    Assert-Pattern $clean '(?:stale|STALE)[\s\S]{0,500}?(?:continue|retry)' $Scope 'consumer discards stale local results and retries from a fresh snapshot'
}

function Invoke-ConsumerChecks {
    Assert-ConsumerContract $LsfgConsumerPath 'consumer:LS-FG'
    Assert-ConsumerContract $SgsrConsumerPath 'consumer:SGSR'
    $lsfgHash = (Get-FileHash $LsfgConsumerPath -Algorithm SHA256).Hash
    $sgsrHash = (Get-FileHash $SgsrConsumerPath -Algorithm SHA256).Hash
    Add-Result ($lsfgHash -eq $sgsrHash) 'consumer:mirror' 'LS-FG and SGSR mirrored consumer sources have identical SHA-256 hashes' "LS-FG=$lsfgHash SGSR=$sgsrHash"
}

Write-Output "LSFG Bridge V2A.1 contract test (stage=$Stage)"
try {
    Invoke-DetectorSelfChecks
    if ($Stage -in @('producer', 'full')) { Invoke-ProducerChecks }
    if ($Stage -in @('consumer', 'full')) { Invoke-ConsumerChecks }
} catch {
    Write-Error "Contract test infrastructure error: $($_.Exception.Message)"
    exit 2
}
Write-Output "SUMMARY checks=$script:Checks failures=$($script:Failures.Count)"
if ($script:Failures.Count -gt 0) { Write-Output 'V2A.1 CONTRACT: FAIL'; exit 1 }
Write-Output 'V2A.1 CONTRACT: PASS'
exit 0
