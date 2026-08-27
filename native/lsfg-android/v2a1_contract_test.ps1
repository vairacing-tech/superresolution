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

function Mask-CppFunctionAttributes {
    param([string]$TriviaFreeSource)
    $chars = $TriviaFreeSource.ToCharArray()
    foreach ($pattern in @('__attribute__\s*\(\([^;{}]*?\)\)', '\[\[[\s\S]*?\]\]')) {
        foreach ($attribute in [regex]::Matches($TriviaFreeSource, $pattern)) {
            for ($i = $attribute.Index; $i -lt $attribute.Index + $attribute.Length; $i++) {
                if ($chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
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

function Get-MatchingParenIndex {
    param([string]$TriviaFreeSource, [int]$OpenIndex)
    $depth = 0
    for ($i = $OpenIndex; $i -lt $TriviaFreeSource.Length; $i++) {
        if ($TriviaFreeSource[$i] -eq '(') { $depth++ }
        elseif ($TriviaFreeSource[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function Get-CppControlScopeIntervals {
    param([string]$TriviaFreeSource)
    $intervals = [System.Collections.Generic.List[object]]::new()
    foreach ($control in [regex]::Matches($TriviaFreeSource, '\b(?<kind>if|for|while|switch|catch)\s*\(')) {
        $openParen = $TriviaFreeSource.IndexOf('(', $control.Index)
        $closeParen = Get-MatchingParenIndex $TriviaFreeSource $openParen
        if ($closeParen -lt 0) { continue }
        $cursor = $closeParen + 1
        while ($cursor -lt $TriviaFreeSource.Length -and [char]::IsWhiteSpace($TriviaFreeSource[$cursor])) { $cursor++ }
        if ($cursor -ge $TriviaFreeSource.Length -or $TriviaFreeSource[$cursor] -ne '{') { continue }
        $closeBrace = Get-MatchingBraceIndex $TriviaFreeSource $cursor
        if ($closeBrace -ge 0) {
            $intervals.Add([pscustomobject]@{ Start = $control.Index; OpenBrace = $cursor; End = $closeBrace; Kind = $control.Groups['kind'].Value })
        }
    }
    return @($intervals)
}

function Test-CppGuardDominatesWrites {
    param([string]$TriviaFreeSource, [System.Text.RegularExpressions.Match]$Guard, [object[]]$Writes)
    if (-not $Guard.Success -or $Writes.Count -eq 0) { return $false }
    if (@($Writes | Where-Object { $_.Index -le ($Guard.Index + $Guard.Length) }).Count -gt 0) { return $false }
    foreach ($scope in Get-CppControlScopeIntervals $TriviaFreeSource) {
        if ($scope.Start -lt $Guard.Index -and $scope.End -gt ($Guard.Index + $Guard.Length)) { return $false }
    }
    $prefixStart = [Math]::Max(0, $Guard.Index - 500)
    $prefix = $TriviaFreeSource.Substring($prefixStart, $Guard.Index - $prefixStart)
    if (Test-Pattern $prefix '\b(?:if|for|while|switch)\s*\([^;{}]*\)\s*$') { return $false }
    return $true
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
    # Function-like GNU and standard attributes can otherwise consume the real
    # signature and make the attribute name look like the function name.
    $scanClean = Mask-CppFunctionAttributes $clean
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
    $callableType = '(?:(?:const|volatile)\s+)*(?:auto|PFN_vk[A-Za-z0-9_]*)(?:\s+(?:const|volatile))*'
    foreach ($match in [regex]::Matches($clean, '(?:(?:const|volatile)\s+)*PFN_vk[A-Za-z0-9_]*(?:\s+(?:const|volatile))*\s+(?<name>[A-Za-z_]\w*)\s*(?=[=;,)\{])')) { [void]$names.Add($match.Groups['name'].Value) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($assignment in [regex]::Matches($clean, "(?:\b$callableType\s+)?\b(?<lhs>[A-Za-z_]\w*)\s*=\s*(?<rhs>[^;]+);")) {
            foreach ($known in @($names)) {
                if (Test-Pattern $assignment.Groups['rhs'].Value "(?:\b|(?:->|\.))$([regex]::Escape($known))\b") {
                    if ($names.Add($assignment.Groups['lhs'].Value)) { $changed = $true }
                    break
                }
            }
        }
        foreach ($assignment in [regex]::Matches($clean, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*(?:\{\s*(?<rhsBrace>[^;{}]+)\s*\}|\(\s*(?<rhsParen>[^;()]+)\s*\))\s*;")) {
            $rhs = if ($assignment.Groups['rhsBrace'].Success) { $assignment.Groups['rhsBrace'].Value } else { $assignment.Groups['rhsParen'].Value }
            foreach ($known in @($names)) {
                if (Test-Pattern $rhs "(?:\b|(?:->|\.))$([regex]::Escape($known))\b") {
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
    $functions = @(Get-CppFunctionInfos $Source)
    foreach ($function in $functions) {
        if (-not (Test-Pattern $function.CleanBody '\bg_stateMutex\b')) { continue }
        $functionIntervals = @($lockData.Intervals | Where-Object { $_.Start -gt $function.OpenIndex -and $_.Start -lt $function.CloseIndex })
        foreach ($mutexUse in [regex]::Matches($function.CleanBody, '\bg_stateMutex\b')) {
            $absoluteUse = $function.BodyStart + $mutexUse.Index
            $knownUse = @($lockData.Recognized | Where-Object { $absoluteUse -ge $_.Start -and $absoluteUse -lt $_.End }).Count -gt 0
            if (-not $knownUse) { [void]$violations.Add("$($function.Name): unrecognized g_stateMutex locking form") }
        }
        foreach ($pfnName in @($pfnNames)) {
            $escapedPfn = [regex]::Escape($pfnName)
            $callPatterns = @("\b$escapedPfn\s*\(", "(?:->|\.)\s*$escapedPfn\s*\(", "\(\s*\*\s*$escapedPfn\s*\)\s*\(")
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
    $globalDeclarations = @([regex]::Matches($clean, '(?:\bextern\s+)?\bstd::mutex\s+g_stateMutex\s*;'))
    foreach ($mutexUse in [regex]::Matches($clean, '\bg_stateMutex\b')) {
        $insideFunction = @($functions | Where-Object { $mutexUse.Index -gt $_.OpenIndex -and $mutexUse.Index -lt $_.CloseIndex }).Count -gt 0
        $isDeclaration = @($globalDeclarations | Where-Object { $mutexUse.Index -ge $_.Index -and $mutexUse.Index -lt ($_.Index + $_.Length) }).Count -gt 0
        if (-not $insideFunction -and -not $isDeclaration) {
            $line = 1 + ([regex]::Matches($clean.Substring(0, $mutexUse.Index), "`n")).Count
            [void]$violations.Add("unparsed function or scope containing g_stateMutex at line $line")
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
    $pointerAliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    [void]$pointerAliases.Add($OutputPointer)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($assignment in [regex]::Matches($clean, '(?:\b(?:auto|[A-Za-z_]\w*(?:::\w+)*(?:\s*\*)?)\s+)?\b(?<lhs>[A-Za-z_]\w*)\s*(?:=|\{|\()\s*(?<rhs>[^;{}()]+)(?:\}|\))?\s*;')) {
            foreach ($known in @($pointerAliases)) {
                if (Test-Pattern $assignment.Groups['rhs'].Value "(?:&\s*)?\b$([regex]::Escape($known))\b(?:\s*\[[^\]]*\]|\s*[+\-].*)?") {
                    if ($pointerAliases.Add($assignment.Groups['lhs'].Value)) { $changed = $true }
                    break
                }
            }
        }
        foreach ($assignment in [regex]::Matches($clean, '\b(?:(?:const|volatile)\s+)*(?:auto|[A-Za-z_]\w*(?:::\w+)*(?:\s*\*)?)(?:\s+(?:const|volatile))*\s+(?<lhs>[A-Za-z_]\w*)\s*=\s*std::(?:(?:ranges)::)?(?:next|prev)\s*\(\s*(?<rhs>[A-Za-z_]\w*)\b[^;]*;')) {
            if ($pointerAliases.Contains($assignment.Groups['rhs'].Value) -and $pointerAliases.Add($assignment.Groups['lhs'].Value)) { $changed = $true }
        }
    }
    $writes = [System.Collections.Generic.List[object]]::new()
    $patterns = [System.Collections.Generic.List[object]]::new()
    foreach ($alias in @($pointerAliases)) {
        $pointer = [regex]::Escape($alias)
        $patterns.Add(@{ Kind = 'array write'; Regex = "\b$pointer\s*\[[^\]]*\]\s*(?:[+\-*/%]?=|\+\+|--)" })
        $patterns.Add(@{ Kind = 'pointer write'; Regex = "(?:\*\s*$pointer\s*(?:\+\+|--)?|\*\s*\(\s*$pointer\s*(?:\+\+|--|[+\-][^)]*)?\s*\))\s*(?:[+\-*/%]?=|\+\+|--)" })
        $patterns.Add(@{ Kind = 'iterator write'; Regex = "\*\s*std::(?:(?:ranges)::)?(?:next|prev)\s*\(\s*$pointer\b[^;)]*\)\s*(?:[+\-*/%]?=|\+\+|--)" })
        $patterns.Add(@{ Kind = 'memcpy/memmove'; Regex = "\b(?:std::)?mem(?:cpy|move|set)\s*\(\s*(?:&\s*)?$pointer\b(?:\s*\[[^\]]*\]|\s*[+\-][^,]*)?" })
        $patterns.Add(@{ Kind = 'std copy'; Regex = "\bstd::(?:(?:ranges)::)?copy(?:_n)?\s*\([^;]*\b$pointer\b[^;]*\)" })
        $patterns.Add(@{ Kind = 'std transform/fill'; Regex = "\bstd::(?:(?:ranges)::)?(?:transform|fill(?:_n)?|generate(?:_n)?|replace(?:_copy)?(?:_if)?|iota)\s*\([^;]*\b$pointer\b[^;]*\)" })
        $patterns.Add(@{ Kind = 'derived output pointer escape'; Regex = "\b[A-Za-z_]\w*\s*\([^;)]*(?:&\s*$pointer\s*\[[^\]]*\]|\b$pointer\s*[+\-][^,)]*)" })
    }
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
    $staleMatch = [regex]::Match($clean, 'if\s*\([^;{}]*expectedGeneration[^;{}]*\)\s*\{?\s*return\s+-4\s*;')
    $staleDominates = Test-CppGuardDominatesWrites $clean $staleMatch $allWrites
    $lockData = Get-StateMutexLockIntervals $body
    $coherent = $false
    if ($staleMatch.Success -and $allWrites.Count -gt 0) {
        foreach ($interval in $lockData.Intervals) {
            $staleInside = $staleMatch.Index -ge $interval.Start -and ($staleMatch.Index + $staleMatch.Length) -lt $interval.End
            $allWritesInside = @($allWrites | Where-Object { $_.Index -lt $interval.Start -or $_.Index -ge $interval.End }).Count -eq 0
            if ($staleInside -and $allWritesInside) { $coherent = $true; break }
        }
    }
    $capacityMatch = [regex]::Match($clean, 'if\s*\([^{};]*(?:\*\s*pCount|capacity)[^{};]*<[^{};]*\)\s*\{?\s*return\s+-(?!4\b)\d+\s*;')
    $firstDataWrite = if ($dataWrites.Count -gt 0) { $dataWrites[0].Index } else { -1 }
    $capacitySafe = $firstDataWrite -ge 0 -and (Test-CppGuardDominatesWrites $clean $capacityMatch $dataWrites)
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

function Get-ExistingValidityBitAnalysis {
    param([string]$Source)
    $body = Get-CppNamedBody $Source 'lsfg_interposer_bridge_get_snapshot_v2'
    if ($null -eq $body) {
        return [pscustomobject]@{ Core = $false; Queue = $false; Swapchain = $false; Images = $false; Surface = $false; Present = $false; All = $false }
    }
    $clean = Remove-CppTrivia $body
    $checks = [ordered]@{
        Core = Test-Pattern $clean 'hostSnapshot\s*\.\s*device\s*=[\s\S]{0,500}?hostSnapshot\s*\.\s*validMask\s*\|=\s*0x01(?:u|U)?\s*;'
        Queue = Test-Pattern $clean 'hostSnapshot\s*\.\s*presentQueue\s*=[\s\S]{0,700}?hostSnapshot\s*\.\s*validMask\s*\|=\s*0x02(?:u|U)?\s*;'
        Swapchain = Test-Pattern $clean 'hostSnapshot\s*\.\s*swapchain\s*=[\s\S]{0,2200}?hostSnapshot\s*\.\s*validMask\s*\|=\s*0x04(?:u|U)?\s*;'
        Images = Test-Pattern $clean 'hasImages[\s\S]{0,700}?hostSnapshot\s*\.\s*validMask\s*\|=\s*0x08(?:u|U)?\s*;'
        Surface = Test-Pattern $clean 'hasSurfaceCapabilities[\s\S]{0,500}?hostSnapshot\s*\.\s*validMask\s*\|=\s*0x10(?:u|U)?\s*;'
        Present = Test-Pattern $clean 'hasPresentModes[\s\S]{0,800}?hostSnapshot\s*\.\s*validMask\s*\|=\s*0x20(?:u|U)?\s*;'
    }
    return [pscustomobject]@{
        Core = $checks.Core; Queue = $checks.Queue; Swapchain = $checks.Swapchain
        Images = $checks.Images; Surface = $checks.Surface; Present = $checks.Present
        All = -not ($checks.Values -contains $false)
    }
}

function Assert-ExistingValidityBits {
    param([string]$Source, [string]$Scope)
    $analysis = Get-ExistingValidityBitAnalysis $Source
    foreach ($entry in @(
        @{ Property = 'Core'; Bit = '0x01'; Meaning = 'core handles' }, @{ Property = 'Queue'; Bit = '0x02'; Meaning = 'queue' },
        @{ Property = 'Swapchain'; Bit = '0x04'; Meaning = 'swapchain' }, @{ Property = 'Images'; Bit = '0x08'; Meaning = 'images' },
        @{ Property = 'Surface'; Bit = '0x10'; Meaning = 'surface capabilities' }, @{ Property = 'Present'; Bit = '0x20'; Meaning = 'present modes' }
    )) {
        Add-Result ([bool]$analysis.($entry.Property)) $Scope "existing validity bit $($entry.Bit) remains assigned in code to $($entry.Meaning)" 'the uncommented pre-existing V2 validity-bit mapping changed or disappeared'
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

function Test-CppCallableInvocation {
    param([string]$Text, [string]$Name)
    $escaped = [regex]::Escape($Name)
    return Test-Pattern $Text "(?:\b$escaped\s*\(|\(\s*\*\s*$escaped\s*\)\s*\()"
}

function Get-CppLocalFunctionAliases {
    param([string]$CleanBody, [object[]]$Functions)
    $functionNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($function in $Functions) { [void]$functionNames.Add($function.Name) }
    $aliases = @{}
    $callableType = '(?:(?:const|volatile)\s+)*(?:auto|PFN_[A-Za-z0-9_]+)(?:\s+(?:const|volatile))*'
    $declarations = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*=\s*&?\s*(?<rhs>[A-Za-z_]\w*)\s*;")) { $declarations.Add($match) }
    foreach ($match in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*(?:\{\s*&?\s*(?<rhsBrace>[A-Za-z_]\w*)\s*\}|\(\s*&?\s*(?<rhsParen>[A-Za-z_]\w*)\s*\))\s*;")) { $declarations.Add($match) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($declaration in $declarations) {
            $lhs = $declaration.Groups['lhs'].Value
            $rhs = if ($declaration.Groups['rhs'].Success) { $declaration.Groups['rhs'].Value } elseif ($declaration.Groups['rhsBrace'].Success) { $declaration.Groups['rhsBrace'].Value } else { $declaration.Groups['rhsParen'].Value }
            $target = if ($functionNames.Contains($rhs)) { $rhs } elseif ($aliases.ContainsKey($rhs)) { $aliases[$rhs] } else { $null }
            if ($null -ne $target -and (-not $aliases.ContainsKey($lhs) -or $aliases[$lhs] -ne $target)) {
                $aliases[$lhs] = $target
                $changed = $true
            }
        }
    }
    return $aliases
}

function Get-CppDirectLocalCallees {
    param([object]$Function, [object[]]$Functions)
    $callees = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($candidate in $Functions) {
        if (Test-CppCallableInvocation $Function.CleanBody $candidate.Name) { [void]$callees.Add($candidate.Name) }
    }
    $aliases = Get-CppLocalFunctionAliases $Function.CleanBody $Functions
    foreach ($alias in $aliases.Keys) {
        if (Test-CppCallableInvocation $Function.CleanBody $alias) { [void]$callees.Add([string]$aliases[$alias]) }
    }
    return @($callees)
}

function Get-CppReachableFunctions {
    param([object[]]$Functions, [string[]]$RootNames)
    $byName = @{}
    foreach ($function in $Functions) { $byName[$function.Name] = $function }
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($rootName in $RootNames) { $pending.Enqueue($rootName) }
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $closure = [System.Collections.Generic.List[object]]::new()
    while ($pending.Count -gt 0) {
        $name = $pending.Dequeue()
        if (-not $visited.Add($name) -or -not $byName.ContainsKey($name)) { continue }
        $function = $byName[$name]
        $closure.Add($function)
        foreach ($callee in Get-CppDirectLocalCallees $function $Functions) {
            if (-not $visited.Contains($callee)) { $pending.Enqueue($callee) }
        }
    }
    return @($closure)
}

function Get-V2A1PathFunctions {
    param([string]$Source)
    $functions = @(Get-CppFunctionInfos $Source)
    $roots = @($functions | Where-Object { $_.Name -match '(?i)(v2a1|v2a_snapshot|metadata.*(?:worker|probe)|snapshot.*(?:worker|probe))' } | ForEach-Object Name)
    return @(Get-CppReachableFunctions $functions $roots)
}

function Get-ConsumerWorkerArrangement {
    param([string]$Source)
    $functions = @(Get-CppFunctionInfos $Source)
    $workers = @($functions | Where-Object Name -match '(?i)(?:v2a1|metadata).*(?:worker)|(?:worker).*(?:v2a1|metadata)')
    $launchSites = [System.Collections.Generic.List[object]]::new()
    foreach ($worker in $workers) {
        foreach ($function in $functions) {
            if (Test-Pattern $function.CleanBody "std::thread[\s\S]{0,240}?\b$([regex]::Escape($worker.Name))\b") {
                $launchSites.Add([pscustomobject]@{ Worker = $worker; Function = $function })
            }
        }
    }
    $launchAndOneShot = $false
    $initTied = $false
    $initRoots = @($functions | Where-Object {
        $_.Name -match '(?i)(init|initializ|discover|export|resolve.*bridge|load.*bridge)' -or
        (Test-Pattern $_.CleanBody '(?i)(dlsym|VULKAN_PTR|interposer_handle|bridge_get_snapshot|export discovered)')
    })
    $initReachable = @(Get-CppReachableFunctions $functions @($initRoots | ForEach-Object Name))
    $everyFrameRoots = @($functions | Where-Object {
        $_.Name -match '(?i)(update|step|loop|render|frame|tick|callback|present|^on_)' -or
        (Test-Pattern $_.CleanBody '\b(?:vkQueuePresentKHR|pPresentInfo|frameSerial|renderFrame)\b')
    })
    $everyFrameReachable = @(Get-CppReachableFunctions $functions @($everyFrameRoots | ForEach-Object Name))
    foreach ($site in $launchSites) {
        $body = $site.Function.CleanBody
        $oneShot = Test-Pattern $body '(?i)(?:v2a1|metadata)[A-Za-z0-9_]*(?:worker|started)[A-Za-z0-9_]*\s*\.\s*exchange\s*\(\s*true\s*\)'
        if ($oneShot) { $launchAndOneShot = $true }
        $initEvidence = @($initReachable | Where-Object Name -eq $site.Function.Name).Count -gt 0
        $everyFrameEvidence = @($everyFrameReachable | Where-Object Name -eq $site.Function.Name).Count -gt 0
        if ($oneShot -and $initEvidence -and -not $everyFrameEvidence) { $initTied = $true }
    }
    return [pscustomobject]@{
        Workers = $workers
        LaunchSites = @($launchSites)
        LaunchAndOneShot = $launchAndOneShot
        InitializationTied = $initTied
    }
}

function Test-NewQueueValidityBit {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    return (Test-Pattern $clean '(?:queueFamilyFlags|queueFamilyQueueCount)[\s\S]{0,1200}?validMask\s*\|=\s*0x40(?:u|U)?\s*;') -or
        (Test-Pattern $clean 'validMask\s*&\s*0x40(?:u|U)?[\s\S]{0,1200}?(?:queueFamilyFlags|queueFamilyQueueCount)') -or
        (Test-Pattern $clean 'LSFG_BRIDGE_VALID_[A-Za-z0-9_]*QUEUE[A-Za-z0-9_]*\s*=\s*0x40(?:u|U)?')
}

function Get-UnresolvedIndirectCallNames {
    param([string]$CleanBody, [object[]]$Functions, [System.Collections.Generic.HashSet[string]]$KnownVulkanPfns)
    $resolved = Get-CppLocalFunctionAliases $CleanBody $Functions
    $unresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($call in [regex]::Matches($CleanBody, '\(\s*\*\s*(?<name>[A-Za-z_]\w*)\s*\)\s*\(')) {
        $name = $call.Groups['name'].Value
        if (-not $resolved.ContainsKey($name) -and -not $KnownVulkanPfns.Contains($name)) { [void]$unresolved.Add($name) }
    }
    $callableType = '(?:(?:const|volatile)\s+)*(?:auto|PFN_[A-Za-z0-9_]+)(?:\s+(?:const|volatile))*'
    foreach ($declaration in [regex]::Matches($CleanBody, "\b$callableType\s+(?<name>[A-Za-z_]\w*)\s*(?:=|\{|\()")) {
        $name = $declaration.Groups['name'].Value
        if ((Test-CppCallableInvocation $CleanBody $name) -and -not $resolved.ContainsKey($name) -and -not $KnownVulkanPfns.Contains($name)) {
            [void]$unresolved.Add($name)
        }
    }
    return @($unresolved)
}

function Find-PassivePathViolations {
    param([string]$Source)
    $violations = [System.Collections.Generic.List[string]]::new()
    $cachedVulkanPfns = Get-CachedRealVulkanPfnNames $Source
    $functions = @(Get-CppFunctionInfos $Source)
    $forbiddenCall = '\b(?:vk|lsfg_vk|g_real)(?:AcquireNextImage(?:2)?KHR|QueuePresentKHR|QueueSubmit(?:2)?|WaitForFences|ResetFences|CreateFence|CreateSemaphore|SignalSemaphore|WaitSemaphores|CmdPipelineBarrier(?:2)?|CmdCopyImage(?:2)?|CmdBlitImage(?:2)?|CmdResolveImage(?:2)?|CmdDispatch(?:Base)?)\s*\('
    $forbiddenMutation = '(?:(?:pCreateInfo|createInfo|swapchainInfo)\s*(?:->|\.)\s*(?:presentMode|minImageCount)|\b(?:oldLayout|newLayout)\b)\s*='
    $forbiddenCompute = '\b(?:lsfg|framegen|frame_generation)[A-Za-z0-9_]*(?:compute|dispatch)[A-Za-z0-9_]*\s*\('
    foreach ($function in Get-V2A1PathFunctions $Source) {
        $clean = Remove-CppTrivia $function.Body
        if (Test-Pattern $clean $forbiddenCall) { $violations.Add("$($function.Name): active Vulkan operation") }
        if (Test-Pattern $clean $forbiddenMutation) { $violations.Add("$($function.Name): layout/present-mode/image-count mutation") }
        if (Test-Pattern $clean $forbiddenCompute) { $violations.Add("$($function.Name): LSFG/frame-generation compute") }
        foreach ($pfnName in @($cachedVulkanPfns)) {
            $escapedPfn = [regex]::Escape($pfnName)
            if (Test-Pattern $clean "(?:\b$escapedPfn\s*\(|(?:->|\.)\s*$escapedPfn\s*\(|\(\s*\*\s*$escapedPfn\s*\)\s*\()") {
                $violations.Add("$($function.Name): cached real Vulkan PFN $pfnName()")
            }
        }
        foreach ($name in Get-UnresolvedIndirectCallNames $clean $functions $cachedVulkanPfns) {
            $violations.Add("$($function.Name): unresolved indirect call $name()")
        }
    }
    return @($violations)
}

function Assert-ConsumerWorkerAndPassivePath {
    param([string]$Source, [string]$Scope)
    $arrangement = Get-ConsumerWorkerArrangement $Source
    $worker = @($arrangement.Workers | Select-Object -First 1)
    $workerExists = $worker.Count -eq 1
    Add-Result $workerExists $Scope 'consumer defines a dedicated short-lived V2A.1 initialization worker' 'no V2A.1/metadata worker function was found'
    if ($workerExists) {
        Add-Result $arrangement.LaunchAndOneShot $Scope 'consumer starts the V2A.1 worker once behind an atomic one-shot gate in the same launch path' 'thread launch and atomic worker-start exchange are not tied together'
        Add-Result $arrangement.InitializationTied $Scope 'V2A.1 worker launch is tied to initialization/export discovery and excluded from every-frame paths' 'worker launch is absent from initialization/export discovery or appears in frame/present/render code'
        Add-Result (Test-Pattern $worker[0].CleanBody 'for\s*\([^;]*;[^;]*<\s*3\s*;') $Scope 'worker bounds complete stale-retry sequences to at most three attempts' 'the worker lacks a literal three-attempt bound'
    } else {
        Add-Result $false $Scope 'consumer starts the V2A.1 worker once behind an atomic one-shot gate in the same launch path' 'worker is absent'
        Add-Result $false $Scope 'V2A.1 worker launch is tied to initialization/export discovery and excluded from every-frame paths' 'worker is absent'
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
    $lockDirectInitAlias = @'
struct DeviceState { PFN_vkQueuePresentKHR queuePresent; };
void bad_direct_init_alias() { auto cachedCall{state.queuePresent}; std::lock_guard lock(g_stateMutex); cachedCall(queue, info); }
'@
    $lockCvDirectInitIndirect = @'
struct DeviceState { PFN_vkQueuePresentKHR queuePresent; };
void bad_cv_direct_init_indirect() { auto const cachedCall{state.queuePresent}; std::lock_guard lock(g_stateMutex); (*cachedCall)(queue, info); }
'@
    $lockVolatileParenIndirect = @'
PFN_vkQueuePresentKHR cachedPresent;
void bad_volatile_paren_indirect() { const volatile auto cachedCall(cachedPresent); std::lock_guard lock(g_stateMutex); (*cachedCall)(queue, info); }
'@
    $lockStandardAttribute = @'
PFN_vkQueuePresentKHR cachedPresent;
[[gnu::visibility("default")]] void bad_standard_attribute() { std::lock_guard lock(g_stateMutex); cachedPresent(queue, info); }
'@
    $lockUnparsedScope = @'
PFN_vkQueuePresentKHR cachedPresent;
auto unparsedLambda = [] { std::lock_guard lock(g_stateMutex); cachedPresent(queue, info); };
'@
    $lockSafe = @'
PFN_vkQueuePresentKHR cachedPresent;
void safe_call() { { std::lock_guard<std::mutex> lock{g_stateMutex}; state = 1; } cachedPresent(queue, info); }
'@
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockTemplateBrace).Count -gt 0) 'lock audit rejects template brace-init lock_guard call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockCtad).Count -gt 0) 'lock audit rejects CTAD lock_guard call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockManualAlias).Count -gt 0) 'lock audit rejects manual lock cached-PFN alias call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockDirectInitAlias).Count -gt 0) 'lock audit rejects direct-init cached-PFN alias call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockCvDirectInitIndirect).Count -gt 0) 'lock audit rejects cv-qualified brace-init alias indirect PFN call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockVolatileParenIndirect).Count -gt 0) 'lock audit rejects cv-qualified parenthesized cached PFN indirect call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockStandardAttribute).Count -gt 0) 'lock audit parses standard-attributed function and rejects locked PFN call'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockUnparsedScope).Count -gt 0) 'lock audit conservatively rejects unparsed scope containing g_stateMutex'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockSafe).Count -eq 0) 'lock audit accepts real Vulkan call after lock closes'
    foreach ($fixture in @(
        @{ Text = 'memcpy(pModes, cached.data(), bytes);'; Kind = 'memcpy/memmove' },
        @{ Text = 'std::copy(cached.begin(), cached.end(), pModes);'; Kind = 'std copy' },
        @{ Text = '*pModes++ = mode;'; Kind = 'pointer write' },
        @{ Text = 'memcpy(&pModes[0], cached.data(), bytes);'; Kind = 'memcpy/memmove' },
        @{ Text = '*std::next(pModes) = mode;'; Kind = 'iterator write' },
        @{ Text = 'auto const out = std::next(pModes, 1); *out = mode;'; Kind = 'pointer write' }
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
    $badAddressCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); memcpy(&pModes[0], cachedModes.data(), bytes);
 if (expectedGeneration != generation) { return -4; } if (*pCount < required) { return -5; } return 0;
}
'@
    $conditionalStaleCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); if (validationEnabled) { if (expectedGeneration != generation) { return -4; } }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; } *std::next(pModes) = cachedModes[0]; return 0;
}
'@
    $conditionalCapacityCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (validateCapacity) { if (*pCount < required) { return -5; } }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); return 0;
}
'@
    $goodAnalysis = Get-CopyOutAnalysis $goodCopy 'copy_modes' 'pModes'
    $badAnalysis = Get-CopyOutAnalysis $badCopy 'copy_modes' 'pModes'
    $badAddressAnalysis = Get-CopyOutAnalysis $badAddressCopy 'copy_modes' 'pModes'
    $conditionalStaleAnalysis = Get-CopyOutAnalysis $conditionalStaleCopy 'copy_modes' 'pModes'
    $conditionalCapacityAnalysis = Get-CopyOutAnalysis $conditionalCapacityCopy 'copy_modes' 'pModes'
    Assert-SelfCheck ($goodAnalysis.StaleDominates -and $goodAnalysis.Coherent -and $goodAnalysis.CapacitySafe) 'copy-out audit accepts coherent locked non-partial copy'
    Assert-SelfCheck (-not $badAnalysis.StaleDominates) 'copy-out audit rejects caller write before stale check'
    Assert-SelfCheck (-not $badAddressAnalysis.StaleDominates) 'copy-out audit rejects &pModes[0] destination before stale check'
    Assert-SelfCheck (-not $conditionalStaleAnalysis.StaleDominates) 'copy-out audit rejects stale guard nested in an optional branch'
    Assert-SelfCheck (-not $conditionalCapacityAnalysis.CapacitySafe) 'copy-out audit rejects capacity guard nested in an optional branch'
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
    $validityGood = @'
int32_t lsfg_interposer_bridge_get_snapshot_v2(LsfgBridgeSnapshotV2 *outSnapshot) {
 hostSnapshot.device = dev; hostSnapshot.validMask |= 0x01;
 hostSnapshot.presentQueue = queue; hostSnapshot.validMask |= 0x02;
 hostSnapshot.swapchain = swapchain; hostSnapshot.validMask |= 0x04;
 if (pMeta->hasImages) { hostSnapshot.validMask |= 0x08; }
 if (pMeta->hasSurfaceCapabilities) { hostSnapshot.validMask |= 0x10; }
 if (pMeta->hasPresentModes) { hostSnapshot.validMask |= 0x20; }
 return 0;
}
'@
    $validityCommentsOnly = @'
int32_t lsfg_interposer_bridge_get_snapshot_v2(LsfgBridgeSnapshotV2 *outSnapshot) {
 // hostSnapshot.device = dev; hostSnapshot.validMask |= 0x01;
 // hostSnapshot.presentQueue = queue; hostSnapshot.validMask |= 0x02;
 // hostSnapshot.swapchain = swapchain; hostSnapshot.validMask |= 0x04;
 // hasImages hostSnapshot.validMask |= 0x08; hasSurfaceCapabilities hostSnapshot.validMask |= 0x10;
 // hasPresentModes hostSnapshot.validMask |= 0x20;
 return 0;
}
'@
    $validityChanged = $validityGood.Replace('hostSnapshot.validMask |= 0x02;', 'hostSnapshot.validMask |= 0x04;')
    Assert-SelfCheck (Get-ExistingValidityBitAnalysis $validityGood).All 'validity audit accepts exact uncommented old-bit mappings'
    Assert-SelfCheck (-not (Get-ExistingValidityBitAnalysis $validityCommentsOnly).All) 'validity audit rejects comment-only mappings'
    Assert-SelfCheck (-not (Get-ExistingValidityBitAnalysis $validityChanged).Queue) 'validity audit rejects changed actual old queue bit'
    $passiveBad = 'void v2a1_metadata_worker() { vkQueueSubmit(queue, 1, submits, fence); }'
    $passiveCachedBad = 'PFN_vkQueuePresentKHR cachedPresent; void v2a1_metadata_worker() { cachedPresent(queue, info); }'
    $passiveHelperBad = 'void active_helper() { vkQueueSubmit(queue, 1, submits, fence); } void v2a1_metadata_worker() { active_helper(); }'
    $passiveIndirectHelperBad = 'void active_helper() { vkQueueSubmit(queue, 1, submits, fence); } void v2a1_metadata_worker() { auto invoke = active_helper; invoke(); }'
    $passiveConstIndirectHelperBad = 'void active_helper() { vkQueueSubmit(queue, 1, submits, fence); } void v2a1_metadata_worker() { auto const invoke(active_helper); invoke(); }'
    $passiveUnresolvedIndirectBad = 'void v2a1_metadata_worker() { auto invoke = external_callable; invoke(); }'
    $passiveOutside = 'void v2a1_metadata_worker() { query_metadata(); } void lsfg_vkQueuePresentKHR() { vkQueuePresentKHR(queue, info); }'
    $initWorkerGood = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void discover_bridge_exports() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }'
    $transitiveInitWorkerGood = 'std::atomic<bool> g_metadataWorkerStarted; void v2a1_metadata_worker() {} void start_probe() { if (!g_metadataWorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void discover_bridge_exports() { start_probe(); }'
    $everyFrameWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void render_frame() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }'
    $indirectEveryFrameWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void initialize_metadata() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void render_frame() { initialize_metadata(); }'
    $updateWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void initialize_metadata() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void update() { initialize_metadata(); }'
    $splitGateWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void discover_bridge_exports() { std::thread worker(v2a1_metadata_worker); } void unrelated_once() { g_v2a1WorkerStarted.exchange(true); }'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveBad).Count -gt 0) 'passive audit rejects active Vulkan operation in V2A.1 path'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveCachedBad).Count -gt 0) 'passive audit rejects cached Vulkan PFN in V2A.1 path'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveHelperBad).Count -gt 0) 'passive audit transitively rejects active helper called by worker'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveIndirectHelperBad).Count -gt 0) 'passive audit rejects active helper reached through function-pointer alias'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveConstIndirectHelperBad).Count -gt 0) 'passive audit rejects active helper reached through const function-pointer alias'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveUnresolvedIndirectBad).Count -gt 0) 'passive audit conservatively rejects unresolved indirect worker call'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveOutside).Count -eq 0) 'passive audit ignores existing wrapper outside V2A.1 path'
    Assert-SelfCheck (Get-ConsumerWorkerArrangement $initWorkerGood).InitializationTied 'worker audit accepts one-shot launch in export-discovery path'
    Assert-SelfCheck (Get-ConsumerWorkerArrangement $transitiveInitWorkerGood).InitializationTied 'worker audit ties delegated launch to parsed export-discovery root'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $everyFrameWorkerBad).InitializationTied) 'worker audit rejects one-shot launch from every-frame path'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $indirectEveryFrameWorkerBad).InitializationTied) 'worker audit rejects indirect every-frame reachability into init-named launcher'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $updateWorkerBad).InitializationTied) 'worker audit rejects update reachability into init-named launcher'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $splitGateWorkerBad).LaunchAndOneShot) 'worker audit rejects file-wide one-shot gate detached from launch root'
}

function Invoke-ProducerChecks {
    $scope = 'producer'; $source = Read-RequiredSource $ProducerPath
    Assert-V2AbiLayout $source $scope
    Assert-ExistingValidityBits $source $scope
    Add-Result (Test-NewQueueValidityBit $source) $scope 'new queue-family capability validity bit is semantically tied to queue fields at code value 0x40' 'no uncommented queue-field/0x40 mapping was found'
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
    Add-Result (Test-NewQueueValidityBit $source) $Scope 'consumer mirrors queue-family validity bit 0x40 in uncommented queue-field code' 'no uncommented queue-field/0x40 mapping was found'
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
    [Console]::Error.WriteLine("Contract test infrastructure error: $($_.Exception.Message)")
    exit 2
}
Write-Output "SUMMARY checks=$script:Checks failures=$($script:Failures.Count)"
if ($script:Failures.Count -gt 0) { Write-Output 'V2A.1 CONTRACT: FAIL'; exit 1 }
Write-Output 'V2A.1 CONTRACT: PASS'
exit 0
