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
    return Mask-CppDisabledPreprocessorBlocks (-join $chars)
}

function Split-CppTopLevelOperator {
    param([string]$Expression, [string]$Operator)
    $parts = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $start = 0
    for ($i = 0; $i -lt $Expression.Length; $i++) {
        if ($Expression[$i] -eq '(') { $depth++; continue }
        if ($Expression[$i] -eq ')') { if ($depth -gt 0) { $depth-- }; continue }
        if ($depth -eq 0 -and $i + $Operator.Length -le $Expression.Length -and $Expression.Substring($i, $Operator.Length) -eq $Operator) {
            $parts.Add($Expression.Substring($start, $i - $start).Trim())
            $start = $i + $Operator.Length
            $i += $Operator.Length - 1
        }
    }
    if ($parts.Count -eq 0) { return @($Expression) }
    $parts.Add($Expression.Substring($start).Trim())
    return @($parts)
}

function Test-CppPreprocessorExpressionEnabled {
    param([string]$Expression)
    $normalized = $Expression.Trim()
    while ($normalized -match '^\(\s*(?<inner>[\s\S]*)\s*\)$') { $normalized = $Matches['inner'].Trim() }
    if ($normalized -match '^0(?:[uUlL]*)$') { return $false }

    $andParts = @(Split-CppTopLevelOperator $normalized '&&')
    if ($andParts.Count -gt 1) {
        foreach ($part in $andParts) {
            if (-not (Test-CppPreprocessorExpressionEnabled $part)) { return $false }
        }
        return $true
    }

    $orParts = @(Split-CppTopLevelOperator $normalized '||')
    if ($orParts.Count -gt 1) {
        foreach ($part in $orParts) {
            if (Test-CppPreprocessorExpressionEnabled $part) { return $true }
        }
        return $false
    }

    if ($normalized -match '^!\s*0(?:[uUlL]*)$') { return $true }
    return $true
}

function Mask-CppDisabledPreprocessorBlocks {
    param([string]$TriviaFreeSource)
    $chars = $TriviaFreeSource.ToCharArray()
    $stack = [System.Collections.Generic.List[object]]::new()
    $active = $true
    foreach ($line in [regex]::Matches($TriviaFreeSource, '(?m)^[^\r\n]*(?:\r?\n|$)')) {
        if ($line.Length -eq 0) { continue }
        $directive = [regex]::Match($line.Value, '^\s*#\s*(?<kind>if|ifdef|ifndef|elif|else|endif)\b(?<expression>[^\r\n]*)')
        if ($directive.Success) {
            for ($i = $line.Index; $i -lt $line.Index + $line.Length; $i++) {
                if ($chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
            }
            $kind = $directive.Groups['kind'].Value
            switch ($kind) {
                'if' {
                    $branchEnabled = Test-CppPreprocessorExpressionEnabled $directive.Groups['expression'].Value
                    $frame = [pscustomobject]@{ ParentActive = $active; AnyBranchTaken = $branchEnabled; Active = ($active -and $branchEnabled) }
                    $stack.Add($frame); $active = $frame.Active
                }
                'ifdef' {
                    $frame = [pscustomobject]@{ ParentActive = $active; AnyBranchTaken = $true; Active = $active }
                    $stack.Add($frame); $active = $frame.Active
                }
                'ifndef' {
                    $frame = [pscustomobject]@{ ParentActive = $active; AnyBranchTaken = $true; Active = $active }
                    $stack.Add($frame); $active = $frame.Active
                }
                'elif' {
                    if ($stack.Count -gt 0) {
                        $frame = $stack[$stack.Count - 1]
                        $branchEnabled = -not $frame.AnyBranchTaken -and (Test-CppPreprocessorExpressionEnabled $directive.Groups['expression'].Value)
                        if ($branchEnabled) { $frame.AnyBranchTaken = $true }
                        $frame.Active = $frame.ParentActive -and $branchEnabled
                        $active = $frame.Active
                    }
                }
                'else' {
                    if ($stack.Count -gt 0) {
                        $frame = $stack[$stack.Count - 1]
                        $branchEnabled = -not $frame.AnyBranchTaken
                        $frame.AnyBranchTaken = $true
                        $frame.Active = $frame.ParentActive -and $branchEnabled
                        $active = $frame.Active
                    }
                }
                'endif' {
                    if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
                    $active = if ($stack.Count -gt 0) { $stack[$stack.Count - 1].Active } else { $true }
                }
            }
            continue
        }
        if (-not $active) {
            for ($i = $line.Index; $i -lt $line.Index + $line.Length; $i++) {
                if ($chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
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
    foreach ($elseMatch in [regex]::Matches($TriviaFreeSource, '\belse\b')) {
        $cursor = $elseMatch.Index + $elseMatch.Length
        while ($cursor -lt $TriviaFreeSource.Length -and [char]::IsWhiteSpace($TriviaFreeSource[$cursor])) { $cursor++ }
        if ($cursor -lt $TriviaFreeSource.Length -and $TriviaFreeSource[$cursor] -eq '{') {
            $closeBrace = Get-MatchingBraceIndex $TriviaFreeSource $cursor
            if ($closeBrace -ge 0) {
                $intervals.Add([pscustomobject]@{ Start = $elseMatch.Index; OpenBrace = $cursor; End = $closeBrace; Kind = 'else' })
            }
        } elseif ($cursor -lt $TriviaFreeSource.Length) {
            $statementEnd = $TriviaFreeSource.IndexOf(';', $cursor)
            if ($statementEnd -ge 0) {
                $intervals.Add([pscustomobject]@{ Start = $elseMatch.Index; OpenBrace = $cursor; End = $statementEnd; Kind = 'else' })
            }
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
    if (Test-Pattern $prefix '(?:\b(?:if|for|while|switch)\s*\([^;{}]*\)|\belse)\s*$') { return $false }
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

function Get-ExactPresentModesParametersPattern {
    return '\s*uint64_t\s+expectedGeneration\s*,\s*VkSwapchainKHR\s+swapchain\s*,\s*uint32_t\s*\*\s*pCount\s*,\s*VkPresentModeKHR\s*\*\s*pModes\s*'
}

function Test-ExactPresentModesSignature {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $parameters = Get-ExactPresentModesParametersPattern
    $consumerTypedef = "\btypedef\s+int32_t\s*\(\s*\*\s*PFN_lsfg_interposer_bridge_get_present_modes_v2\s*\)\s*\($parameters\)\s*;"
    return Test-Pattern $clean $consumerTypedef
}

function Test-ExactPresentModesProducerSignature {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $parameters = Get-ExactPresentModesParametersPattern
    $producer = "\bint32_t\s+lsfg_interposer_bridge_get_present_modes_v2\s*\($parameters\)\s*\{"
    return Test-Pattern $clean $producer
}

function Assert-ExactPresentModesSignature {
    param([string]$Source, [string]$Scope)
    Add-Result (Test-ExactPresentModesSignature $Source) $Scope 'consumer declares the canonical present-mode copy-out typedef with expectedGeneration, swapchain, pCount, and pModes' 'the exact consumer PFN typedef is absent or structurally different'
}

function Assert-ExactPresentModesProducerSignature {
    param([string]$Source, [string]$Scope)
    Add-Result (Test-ExactPresentModesProducerSignature $Source) $Scope 'producer exposes the exact present-mode copy-out function with expectedGeneration, swapchain, pCount, and pModes' 'the exact producer function signature is absent or structurally different'
}

function Get-CppStringLiteralTexts {
    param([string]$Source)
    $literals = [System.Collections.Generic.List[string]]::new()
    $state = 'code'
    $builder = $null
    for ($i = 0; $i -lt $Source.Length; $i++) {
        $ch = $Source[$i]
        $next = if ($i + 1 -lt $Source.Length) { $Source[$i + 1] } else { [char]0 }
        switch ($state) {
            'code' {
                if ($ch -eq '/' -and $next -eq '/') { $i++; $state = 'line-comment' }
                elseif ($ch -eq '/' -and $next -eq '*') { $i++; $state = 'block-comment' }
                elseif ($ch -eq '"') { $builder = [System.Text.StringBuilder]::new(); $state = 'string' }
                elseif ($ch -eq "'") { $state = 'character' }
            }
            'line-comment' { if ($ch -eq "`n") { $state = 'code' } }
            'block-comment' { if ($ch -eq '*' -and $next -eq '/') { $i++; $state = 'code' } }
            'string' {
                if ($ch -eq '\' -and $i + 1 -lt $Source.Length) {
                    [void]$builder.Append($ch); [void]$builder.Append($next); $i++
                } elseif ($ch -eq '"') {
                    $literals.Add($builder.ToString()); $builder = $null; $state = 'code'
                } else { [void]$builder.Append($ch) }
            }
            'character' {
                if ($ch -eq '\' -and $i + 1 -lt $Source.Length) { $i++ }
                elseif ($ch -eq "'") { $state = 'code' }
            }
        }
    }
    return @($literals)
}

function Get-CppEmittedStringLiteralTexts {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $literals = [System.Collections.Generic.List[string]]::new()
    $logPattern = '\b(?:LOG[IVDWE]|ALOG[IVDWE]|__android_log_(?:print|write)|printf|fprintf|log)\s*\('
    foreach ($call in [regex]::Matches($clean, $logPattern)) {
        $open = $clean.IndexOf('(', $call.Index)
        if ($open -lt 0) { continue }
        $close = Get-MatchingParenIndex $clean $open
        if ($close -lt 0) { continue }
        $callSource = $Source.Substring($call.Index, $close - $call.Index + 1)
        foreach ($literal in Get-CppStringLiteralTexts $callSource) { $literals.Add($literal) }
    }
    return @($literals)
}

function Test-V2A1DiagnosticBlock {
    param([string]$Source, [string[]]$RequiredLabels)
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($function in Get-CppFunctionInfos $Source) {
        if ($function.Name -match '(?i)(?:present|callback)' -and $function.Name -notmatch '(?i)v2a1_metadata') { continue }
        $hasDiagnosticPathName = $function.Name -match '(?i)(?:v2a1|metadata|snapshot|diagnostic|probe)'
        $hasOneShotGate = Test-Pattern $function.CleanBody '(?i)(?:v2a1|metadata|snapshot)[A-Za-z0-9_]*(?:diagnostic|logged|log|reported|started)?[A-Za-z0-9_]*\s*\.\s*exchange\s*\(\s*true\s*\)'
        if (-not $hasDiagnosticPathName -and -not $hasOneShotGate) { continue }
        $literalText = @(Get-CppEmittedStringLiteralTexts $function.Body) -join "`n"
        if ($literalText -notmatch [regex]::Escape('[LSFG-V2A1]')) { continue }
        $candidates.Add($function.Name)
        $complete = $true
        foreach ($label in $RequiredLabels) {
            if ($literalText -notmatch [regex]::Escape($label)) { $complete = $false; break }
        }
        if ($complete) { return [pscustomobject]@{ Complete = $true; CandidateFunctions = @($candidates); CompleteFunction = $function.Name } }
    }
    return [pscustomobject]@{ Complete = $false; CandidateFunctions = @($candidates); CompleteFunction = $null }
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
    $customCallableTypes = Get-CppFunctionPointerTypedefNames $clean
    $realVulkanTypes = @(Get-CppRealVulkanFunctionPointerTypedefNames $clean $customCallableTypes)
    foreach ($typeName in $realVulkanTypes) {
        foreach ($match in [regex]::Matches($clean, "\b$([regex]::Escape($typeName))\s+(?<name>[A-Za-z_]\w*)\s*(?=[=;,\)\{])")) {
            [void]$names.Add($match.Groups['name'].Value)
        }
    }
    $customTypeAlternation = if ($customCallableTypes.Count -gt 0) { '|' + ((@($customCallableTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|') } else { '' }
    $callableType = "(?:(?:const|volatile)\s+)*(?:auto|PFN_vk[A-Za-z0-9_]*$customTypeAlternation)(?:\s+(?:const|volatile))*"
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
    $safeBridgeNames = Get-SafeBridgeMetadataIndirectCallNames $clean $clean
    foreach ($safeBridgeName in $safeBridgeNames) { [void]$names.Remove($safeBridgeName) }
    return $names
}

function Find-RealVulkanCallsUnderStateMutex {
    param([string]$Source)
    $clean = Remove-CppTrivia $Source
    $lockData = Get-StateMutexLockIntervals $Source
    $pfnNames = Get-CachedRealVulkanPfnNames $Source
    $violations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $functions = @(Get-CppFunctionInfos $Source)
    $customCallableTypes = Get-CppFunctionPointerTypedefNames $clean
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
            $callPatterns = @("\b$escapedPfn\s*\(", "(?:->|\.)\s*$escapedPfn\s*\(", "\(\s*\*\s*$escapedPfn\s*\)\s*\(", "\bstd::invoke\s*\(\s*(?:\*\s*)?$escapedPfn\s*,")
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
        foreach ($interval in $functionIntervals) {
            $relativeStart = [Math]::Max(0, $interval.Start - $function.BodyStart)
            $relativeEnd = [Math]::Min($function.CleanBody.Length, $interval.End - $function.BodyStart)
            if ($relativeEnd -le $relativeStart) { continue }
            $lockedBody = $function.CleanBody.Substring($relativeStart, $relativeEnd - $relativeStart)
            $lockedView = [pscustomobject]@{ CleanBody = $lockedBody }
            $functionAliases = Get-CppLocalFunctionAliases $function.CleanBody $functions $customCallableTypes
            $directHelpers = @(Get-CppDirectLocalCallees $lockedView $functions $customCallableTypes $functionAliases)
            foreach ($helper in Get-CppReachableFunctions $functions $directHelpers $customCallableTypes) {
                foreach ($pfnName in @($pfnNames)) {
                    if (Test-CppCallableInvocation $helper.CleanBody $pfnName) {
                        [void]$violations.Add("$($function.Name): lock remains active through helper $($helper.Name) calling real Vulkan PFN $pfnName()")
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
        foreach ($assignment in [regex]::Matches($clean, '\b(?:(?:const|volatile)\s+)*(?:auto|[A-Za-z_]\w*(?:::\w+)*(?:\s*\*)?)(?:\s+(?:const|volatile))*\s+(?<lhs>[A-Za-z_]\w*)\s*(?:=|\{|\()\s*std::(?:(?:ranges)::)?(?:next|prev)\s*\(\s*(?<rhs>[A-Za-z_]\w*)\b[^;]*;')) {
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

function Test-StaleGenerationMismatchCondition {
    param([string]$Condition)
    $normalized = $Condition.Trim()
    while ($normalized -match '^\(\s*(?<inner>[\s\S]*)\s*\)$') { $normalized = $Matches['inner'].Trim() }
    $parts = @(Split-CppTopLevelOperator $normalized '&&')
    $hasMismatch = $false
    foreach ($part in $parts) {
        $term = $part.Trim()
        while ($term -match '^\(\s*(?<inner>[\s\S]*)\s*\)$') { $term = $Matches['inner'].Trim() }
        if ($term -match '^expectedGeneration\s*!=\s*(?<current>[A-Za-z_]\w*(?:(?:\.|->)\s*\w+)*)$' -or
            $term -match '^(?<current>[A-Za-z_]\w*(?:(?:\.|->)\s*\w+)*)\s*!=\s*expectedGeneration$') {
            if ($Matches['current'] -notmatch '(?i)(?:generation|gen)') { return $false }
            if ($hasMismatch) { return $false }
            $hasMismatch = $true
            continue
        }
        if ($term -match '^expectedGeneration\s*!=\s*0(?:[uUlL]*)$') { continue }
        return $false
    }
    return $hasMismatch
}

function Get-CopyCountSources {
    param([string]$TriviaFreeBody)
    $sources = @{}
    foreach ($match in [regex]::Matches($TriviaFreeBody, '\b(?<count>[A-Za-z_]\w*)\s*=\s*(?<source>[A-Za-z_]\w*)\s*\.\s*size\s*\(\s*\)\s*;')) {
        $sources[$match.Groups['count'].Value] = $match.Groups['source'].Value
    }
    return $sources
}

function Test-CopySourceMatchesRequired {
    param([hashtable]$CountSources, [string]$SourceName, [string]$CountExpression)
    $source = $SourceName.Trim()
    $count = [regex]::Replace($CountExpression.Trim(), '\s+', '')
    if ($count -eq "$source.size()") { return $true }
    if ($CountSources.ContainsKey($count) -and $CountSources[$count] -eq $source) { return $true }
    return $false
}

function Get-CompleteCallerBufferCopyProof {
    param([string]$TriviaFreeBody, [string]$OutputPointer)
    $invalid = [pscustomobject]@{ Valid = $false; Source = $null; CountExpression = $null; Kind = $null }
    $pointer = [regex]::Escape($OutputPointer)
    $countSources = Get-CopyCountSources $TriviaFreeBody
    if ($countSources.Count -eq 0) { return $invalid }

    $rangePattern = "\bstd::(?:ranges::)?copy\s*\(\s*(?<source>[A-Za-z_]\w*)\s*\.\s*begin\s*\(\s*\)\s*,\s*\k<source>\s*\.\s*end\s*\(\s*\)\s*,\s*$pointer\b"
    foreach ($match in [regex]::Matches($TriviaFreeBody, $rangePattern)) {
        $source = $match.Groups['source'].Value
        foreach ($countName in @($countSources.Keys)) {
            if ($countSources[$countName] -eq $source) { return [pscustomobject]@{ Valid = $true; Source = $source; CountExpression = [string]$countName; Kind = 'full-range copy' } }
        }
    }

    $containerPattern = "\bstd::ranges::copy\s*\(\s*(?<source>[A-Za-z_]\w*)\s*,\s*$pointer\b"
    foreach ($match in [regex]::Matches($TriviaFreeBody, $containerPattern)) {
        $source = $match.Groups['source'].Value
        foreach ($countName in @($countSources.Keys)) {
            if ($countSources[$countName] -eq $source) { return [pscustomobject]@{ Valid = $true; Source = $source; CountExpression = [string]$countName; Kind = 'ranges container copy' } }
        }
    }

    $copyNPattern = "\bstd::(?:ranges::)?copy_n\s*\(\s*(?<source>[A-Za-z_]\w*)\s*\.\s*begin\s*\(\s*\)\s*,\s*(?<count>[^,]+?)\s*,\s*$pointer\b"
    foreach ($match in [regex]::Matches($TriviaFreeBody, $copyNPattern)) {
        $source = $match.Groups['source'].Value
        $count = $match.Groups['count'].Value.Trim()
        if (Test-CopySourceMatchesRequired $countSources $source $count) { return [pscustomobject]@{ Valid = $true; Source = $source; CountExpression = $count; Kind = 'copy_n' } }
    }

    $memcpyPattern = "\b(?:std::)?mem(?:cpy|move)\s*\(\s*(?:&\s*)?$pointer\b[^,]*,\s*(?<source>[A-Za-z_]\w*)\s*\.\s*data\s*\(\s*\)\s*,\s*(?<bytes>[^;]+)\)\s*;"
    foreach ($match in [regex]::Matches($TriviaFreeBody, $memcpyPattern)) {
        $source = $match.Groups['source'].Value
        $bytes = $match.Groups['bytes'].Value
        foreach ($countName in @($countSources.Keys)) {
            $countPattern = "\b$([regex]::Escape([string]$countName))\b"
            if ($countSources[$countName] -eq $source -and (Test-Pattern $bytes $countPattern)) {
                return [pscustomobject]@{ Valid = $true; Source = $source; CountExpression = [string]$countName; Kind = 'memcpy' }
            }
        }
    }

    $loopPattern = "\bfor\s*\([^;]*?(?<index>[A-Za-z_]\w*)\s*=\s*0(?:u|U)?\s*;\s*\k<index>\s*<\s*(?<count>[A-Za-z_]\w*)\s*;[^)]*\)\s*\{(?<body>[^{}]*)\}"
    foreach ($loop in [regex]::Matches($TriviaFreeBody, $loopPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        if ($loop.Groups['body'].Value -match '\b(?:break|continue|goto|return|throw)\b') { continue }
        $index = [regex]::Escape($loop.Groups['index'].Value)
        $write = [regex]::Match($loop.Groups['body'].Value, "\b$pointer\s*\[\s*$index\s*\]\s*=\s*(?<source>[A-Za-z_]\w*)\s*\[\s*$index\s*\]")
        if ($write.Success -and (Test-CopySourceMatchesRequired $countSources $write.Groups['source'].Value $loop.Groups['count'].Value)) {
            return [pscustomobject]@{ Valid = $true; Source = $write.Groups['source'].Value; CountExpression = $loop.Groups['count'].Value; Kind = 'indexed loop' }
        }
    }
    return $invalid
}

function Test-CompleteCallerBufferCopy {
    param([string]$TriviaFreeBody, [string]$OutputPointer)
    return (Get-CompleteCallerBufferCopyProof $TriviaFreeBody $OutputPointer).Valid
}

function Test-CountExpressionsEquivalent {
    param([hashtable]$CountSources, [string]$Left, [string]$Right)
    $leftCompact = [regex]::Replace($Left.Trim(), '\s+', '')
    $rightCompact = [regex]::Replace($Right.Trim(), '\s+', '')
    if ($leftCompact -eq $rightCompact) { return $true }
    $leftSource = $null
    $rightSource = $null
    if ($CountSources.ContainsKey($leftCompact)) { $leftSource = $CountSources[$leftCompact] }
    elseif ($leftCompact -match '^(?<source>[A-Za-z_]\w*)\.size\(\)$') { $leftSource = $Matches['source'] }
    if ($CountSources.ContainsKey($rightCompact)) { $rightSource = $CountSources[$rightCompact] }
    elseif ($rightCompact -match '^(?<source>[A-Za-z_]\w*)\.size\(\)$') { $rightSource = $Matches['source'] }
    return $null -ne $leftSource -and $leftSource -eq $rightSource
}

function Test-CapacityGuardMatchesCopy {
    param([string]$Condition, [hashtable]$CountSources, [object]$CopyProof)
    if ($null -eq $CopyProof -or -not $CopyProof.Valid) { return $false }
    $normalized = $Condition.Trim()
    while ($normalized -match '^\(\s*(?<inner>[\s\S]*)\s*\)$') { $normalized = $Matches['inner'].Trim() }
    foreach ($pattern in @(
        '^\*\s*pCount\s*<\s*(?<count>[A-Za-z_]\w*(?:\s*\.\s*size\s*\(\s*\))?)$',
        '^(?<count>[A-Za-z_]\w*(?:\s*\.\s*size\s*\(\s*\))?)\s*>\s*\*\s*pCount$'
    )) {
        if ($normalized -match $pattern) {
            return Test-CountExpressionsEquivalent $CountSources $Matches['count'] $CopyProof.CountExpression
        }
    }
    return $false
}

function Test-ReturnedCountMatchesCopy {
    param([string]$TriviaFreeBody, [int]$FirstDataWrite, [object]$CopyProof)
    if ($FirstDataWrite -lt 0 -or $null -eq $CopyProof -or -not $CopyProof.Valid) { return $false }
    $countSources = Get-CopyCountSources $TriviaFreeBody
    foreach ($match in [regex]::Matches($TriviaFreeBody, '\*\s*pCount\s*=\s*(?<value>[^;]+)\s*;')) {
        if ($match.Index -le $FirstDataWrite) { continue }
        if (Test-CountExpressionsEquivalent $countSources $match.Groups['value'].Value $CopyProof.CountExpression) { return $true }
    }
    return $false
}

function Get-CopyOutAnalysis {
    param([string]$Source, [string]$FunctionName, [string]$OutputPointer)
    $body = Get-CppNamedBody $Source $FunctionName
    if ($null -eq $body) { return [pscustomobject]@{ Exists = $false; StaleDominates = $false; Coherent = $false; CapacitySafe = $false; Detail = 'function body was not found' } }
    $clean = Remove-CppTrivia $body
    $allWrites = @(Get-CallerOutputWrites $body $OutputPointer -IncludeCount)
    $dataWrites = @(Get-CallerOutputWrites $body $OutputPointer)
    $staleMatch = [regex]::Match($clean, 'if\s*\((?<condition>[^;{}]*expectedGeneration[^;{}]*)\)\s*\{?\s*return\s+-4\s*;')
    $staleSemantics = $staleMatch.Success -and (Test-StaleGenerationMismatchCondition $staleMatch.Groups['condition'].Value)
    $staleDominates = $staleSemantics -and (Test-CppGuardDominatesWrites $clean $staleMatch $allWrites)
    $lockData = Get-StateMutexLockIntervals $body
    $coherent = $false
    if ($staleMatch.Success -and $allWrites.Count -gt 0) {
        foreach ($interval in $lockData.Intervals) {
            $staleInside = $staleMatch.Index -ge $interval.Start -and ($staleMatch.Index + $staleMatch.Length) -lt $interval.End
            $allWritesInside = @($allWrites | Where-Object { $_.Index -lt $interval.Start -or $_.Index -ge $interval.End }).Count -eq 0
            if ($staleInside -and $allWritesInside) { $coherent = $true; break }
        }
    }
    $capacityMatch = [regex]::Match($clean, 'if\s*\((?<condition>[^{};]*(?:\*\s*pCount\s*<|>\s*\*\s*pCount)[^{};]*)\)\s*\{?\s*return\s+-(?!4\b)\d+\s*;')
    $firstDataWrite = if ($dataWrites.Count -gt 0) { $dataWrites[0].Index } else { -1 }
    $copyProof = Get-CompleteCallerBufferCopyProof $clean $OutputPointer
    $completeCopy = $copyProof.Valid
    $countSources = Get-CopyCountSources $clean
    $returnedCountSafe = Test-ReturnedCountMatchesCopy $clean $firstDataWrite $copyProof
    $capacityCountSafe = $capacityMatch.Success -and (Test-CapacityGuardMatchesCopy $capacityMatch.Groups['condition'].Value $countSources $copyProof)
    $capacitySafe = $firstDataWrite -ge 0 -and $completeCopy -and $returnedCountSafe -and $capacityCountSafe -and (Test-CppGuardDominatesWrites $clean $capacityMatch $dataWrites)
    if (Test-Pattern $clean '(?:std::min\s*\(\s*\*\s*pCount|\btoCopy\b[\s\S]{0,160}?return\s+0)') { $capacitySafe = $false }
    $details = [System.Collections.Generic.List[string]]::new()
    if (-not $staleDominates) { $details.Add('a correct current-vs-expected generation mismatch returning stale -4 does not precede every pCount/buffer write') }
    if (-not $coherent) { $details.Add('stale check and all caller writes are not one coherent g_stateMutex-locked copy') }
    if (-not $capacitySafe) { $details.Add('insufficient capacity can reach a partial/unchecked data write, an inconsistent returned count, an unmatched capacity/count guard, or no provably complete required-count copy is present') }
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
    return Test-Pattern $Text "(?:\b$escaped\s*\(|\(\s*\*\s*$escaped\s*\)\s*\(|\bstd::invoke\s*\(\s*(?:\*\s*)?$escaped\s*,)"
}

function Get-CppFunctionPointerTypedefNames {
    param([string]$TriviaFreeSource)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\btypedef\b[^;{}]*\(\s*(?:VKAPI_PTR\s*)?\*\s*(?<name>[A-Za-z_]\w*)\s*\)\s*\([^;{}]*\)\s*;')) {
        [void]$names.Add($match.Groups['name'].Value)
    }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\busing\s+(?<name>[A-Za-z_]\w*)\s*=\s*[^;{}]*\(\s*(?:VKAPI_PTR\s*)?\*\s*\)\s*\([^;{}]*\)\s*;')) {
        [void]$names.Add($match.Groups['name'].Value)
    }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\btypedef\s+PFN_[A-Za-z0-9_]+\s+(?<name>[A-Za-z_]\w*)\s*;')) { [void]$names.Add($match.Groups['name'].Value) }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\busing\s+(?<name>[A-Za-z_]\w*)\s*=\s*PFN_[A-Za-z0-9_]+\s*;')) { [void]$names.Add($match.Groups['name'].Value) }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\btypedef\s+std::function\s*<[^;{}]+>\s+(?<name>[A-Za-z_]\w*)\s*;')) { [void]$names.Add($match.Groups['name'].Value) }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\busing\s+(?<name>[A-Za-z_]\w*)\s*=\s*std::function\s*<[^;{}]+>\s*;')) { [void]$names.Add($match.Groups['name'].Value) }
    return ,$names
}

function Get-CppRealVulkanFunctionPointerTypedefNames {
    param([string]$TriviaFreeSource, [System.Collections.Generic.HashSet[string]]$CustomCallableTypes)
    $realTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($typeName in @($CustomCallableTypes)) {
        if ($typeName -match '(?i)(?:real|vulkan|(?:^|_)vk(?:_|$))') { [void]$realTypes.Add($typeName) }
    }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\btypedef\s+PFN_vk[A-Za-z0-9_]*\s+(?<name>[A-Za-z_]\w*)\s*;')) { [void]$realTypes.Add($match.Groups['name'].Value) }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\busing\s+(?<name>[A-Za-z_]\w*)\s*=\s*PFN_vk[A-Za-z0-9_]*\s*;')) { [void]$realTypes.Add($match.Groups['name'].Value) }
    $aliases = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\btypedef\s+(?<rhs>[A-Za-z_]\w*)\s+(?<lhs>[A-Za-z_]\w*)\s*;')) { $aliases.Add($match) }
    foreach ($match in [regex]::Matches($TriviaFreeSource, '\busing\s+(?<lhs>[A-Za-z_]\w*)\s*=\s*(?<rhs>[A-Za-z_]\w*)\s*;')) { $aliases.Add($match) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($alias in $aliases) {
            if ($realTypes.Contains($alias.Groups['rhs'].Value) -and $realTypes.Add($alias.Groups['lhs'].Value)) { $changed = $true }
        }
    }
    return ,$realTypes
}

function Get-CppLocalFunctionAliases {
    param([string]$CleanBody, [object[]]$Functions, [System.Collections.Generic.HashSet[string]]$CustomCallableTypes)
    $functionNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($function in $Functions) { [void]$functionNames.Add($function.Name) }
    $aliases = @{}
    $declaredCallableNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $customAlternation = if ($null -ne $CustomCallableTypes -and $CustomCallableTypes.Count -gt 0) { '|' + ((@($CustomCallableTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|') } else { '' }
    $callableType = "(?:(?:const|volatile)\s+)*(?:auto|PFN_[A-Za-z0-9_]+$customAlternation|std::function\s*<[^;{}]+>)(?:\s+(?:const|volatile))*"
    $assignments = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*=\s*&?\s*(?<rhs>[A-Za-z_]\w*)\s*;")) {
        [void]$declaredCallableNames.Add($match.Groups['lhs'].Value)
        $assignments.Add([pscustomobject]@{ Lhs = $match.Groups['lhs'].Value; Rhs = $match.Groups['rhs'].Value })
    }
    foreach ($match in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*(?:\{\s*&?\s*(?<rhsBrace>[A-Za-z_]\w*)\s*\}|\(\s*&?\s*(?<rhsParen>[A-Za-z_]\w*)\s*\))\s*;")) {
        [void]$declaredCallableNames.Add($match.Groups['lhs'].Value)
        $rhs = if ($match.Groups['rhsBrace'].Success) { $match.Groups['rhsBrace'].Value } else { $match.Groups['rhsParen'].Value }
        $assignments.Add([pscustomobject]@{ Lhs = $match.Groups['lhs'].Value; Rhs = $rhs })
    }
    foreach ($match in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*;")) { [void]$declaredCallableNames.Add($match.Groups['lhs'].Value) }
    foreach ($match in [regex]::Matches($CleanBody, '(?<!\.)\b(?<lhs>[A-Za-z_]\w*)\s*=\s*&?\s*(?<rhs>[A-Za-z_]\w*)\s*;')) {
        if ($declaredCallableNames.Contains($match.Groups['lhs'].Value)) {
            $assignments.Add([pscustomobject]@{ Lhs = $match.Groups['lhs'].Value; Rhs = $match.Groups['rhs'].Value })
        }
    }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($assignment in $assignments) {
            $target = if ($functionNames.Contains($assignment.Rhs)) { $assignment.Rhs } elseif ($aliases.ContainsKey($assignment.Rhs)) { $aliases[$assignment.Rhs] } else { $null }
            if ($null -ne $target -and (-not $aliases.ContainsKey($assignment.Lhs) -or $aliases[$assignment.Lhs] -ne $target)) {
                $aliases[$assignment.Lhs] = $target
                $changed = $true
            }
        }
    }
    return $aliases
}

function Get-CppDirectLocalCallees {
    param(
        [object]$Function,
        [object[]]$Functions,
        [System.Collections.Generic.HashSet[string]]$CustomCallableTypes,
        [hashtable]$PrecomputedAliases = $null
    )
    $callees = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($candidate in $Functions) {
        if (Test-CppCallableInvocation $Function.CleanBody $candidate.Name) { [void]$callees.Add($candidate.Name) }
    }
    $aliases = if ($null -ne $PrecomputedAliases) { $PrecomputedAliases } else { Get-CppLocalFunctionAliases $Function.CleanBody $Functions $CustomCallableTypes }
    foreach ($alias in $aliases.Keys) {
        if (Test-CppCallableInvocation $Function.CleanBody $alias) { [void]$callees.Add([string]$aliases[$alias]) }
    }
    return @($callees)
}

function Get-CppReachableFunctions {
    param([object[]]$Functions, [string[]]$RootNames, [System.Collections.Generic.HashSet[string]]$CustomCallableTypes)
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
        foreach ($callee in Get-CppDirectLocalCallees $function $Functions $CustomCallableTypes) {
            if (-not $visited.Contains($callee)) { $pending.Enqueue($callee) }
        }
    }
    return @($closure)
}

function Get-V2A1PathFunctions {
    param([string]$Source)
    $functions = @(Get-CppFunctionInfos $Source)
    $customCallableTypes = Get-CppFunctionPointerTypedefNames (Remove-CppTrivia $Source)
    $roots = @($functions | Where-Object { $_.Name -match '(?i)(v2a1|v2a_snapshot|metadata.*(?:worker|probe)|snapshot.*(?:worker|probe))' } | ForEach-Object Name)
    return @(Get-CppReachableFunctions $functions $roots $customCallableTypes)
}

function Get-ConsumerWorkerArrangement {
    param([string]$Source)
    $functions = @(Get-CppFunctionInfos $Source)
    $customCallableTypes = Get-CppFunctionPointerTypedefNames (Remove-CppTrivia $Source)
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
    $initReachable = @(Get-CppReachableFunctions $functions @($initRoots | ForEach-Object Name) $customCallableTypes)
    $everyFrameRoots = @($functions | Where-Object {
        $_.Name -match '(?i)(update|step|loop|render|frame|tick|acquire|observer|callback|present|^on_)' -or
        (Test-Pattern $_.CleanBody '\b(?:vkQueuePresentKHR|pPresentInfo|frameSerial|renderFrame)\b')
    })
    $everyFrameReachable = @(Get-CppReachableFunctions $functions @($everyFrameRoots | ForEach-Object Name) $customCallableTypes)
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
    foreach ($function in Get-CppFunctionInfos $Source) {
        $body = $function.CleanBody
        $bitAssignments = @([regex]::Matches($body, '(?<receiver>[A-Za-z_]\w*)\s*(?<access>\.|->)\s*validMask\s*\|=\s*0x40(?:u|U)?\s*;'))
        foreach ($bitAssignment in $bitAssignments) {
            $receiver = $bitAssignment.Groups['receiver'].Value
            $fieldPrefix = "\b$([regex]::Escape($receiver))\s*(?:\.|->)\s*"
            $beforeBit = $body.Substring(0, $bitAssignment.Index)
            $flagsAssigned = Test-Pattern $beforeBit "${fieldPrefix}queueFamilyFlags\s*=\s*[^;]*\bqueueFlags\b"
            $countAssigned = Test-Pattern $beforeBit "${fieldPrefix}queueFamilyQueueCount\s*=\s*[^;]*\bqueueCount\b"
            if ($flagsAssigned -and $countAssigned) { return $true }
        }

        foreach ($ifMatch in [regex]::Matches($body, '\bif\s*\(')) {
            $openParen = $body.IndexOf('(', $ifMatch.Index)
            $closeParen = Get-MatchingParenIndex $body $openParen
            if ($closeParen -lt 0) { continue }
            $condition = $body.Substring($openParen + 1, $closeParen - $openParen - 1)
            if ($condition -match '!\s*\(?\s*[A-Za-z_]\w*\s*(?:\.|->)\s*validMask' -or $condition -match '==\s*0\b') { continue }
            $bitMatch = [regex]::Match($condition, '(?<receiver>[A-Za-z_]\w*)\s*(?:\.|->)\s*validMask\s*&\s*0x40(?:u|U)?\b')
            if (-not $bitMatch.Success) { continue }
            $cursor = $closeParen + 1
            while ($cursor -lt $body.Length -and [char]::IsWhiteSpace($body[$cursor])) { $cursor++ }
            if ($cursor -ge $body.Length -or $body[$cursor] -ne '{') { continue }
            $closeBrace = Get-MatchingBraceIndex $body $cursor
            if ($closeBrace -lt 0) { continue }
            $receiver = [regex]::Escape($bitMatch.Groups['receiver'].Value)
            $scopeBody = $body.Substring($cursor + 1, $closeBrace - $cursor - 1)
            $flagsUsed = Test-Pattern $scopeBody "\b$receiver\s*(?:\.|->)\s*queueFamilyFlags\b"
            $countUsed = Test-Pattern $scopeBody "\b$receiver\s*(?:\.|->)\s*queueFamilyQueueCount\b"
            if ($flagsUsed -and $countUsed) { return $true }
        }
    }
    return $false
}

function Get-SafeBridgeMetadataIndirectCallNames {
    param([string]$CleanSource, [string]$CleanBody)
    $safeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $typedAtomics = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $bridgePfnType = 'PFN_lsfg_interposer_bridge_(?:get_snapshot_v2|get_swapchain_images_v2|get_present_modes_v2)'
    foreach ($declaration in [regex]::Matches($CleanSource, "\bstd::atomic\s*<\s*$bridgePfnType\s*>\s+(?<name>[A-Za-z_]\w*)")) {
        [void]$typedAtomics.Add($declaration.Groups['name'].Value)
    }
    foreach ($declaration in [regex]::Matches($CleanSource, "\b$bridgePfnType(?:\s+(?:const|volatile))*\s+(?<name>[A-Za-z_]\w*)\b")) {
        [void]$safeNames.Add($declaration.Groups['name'].Value)
    }

    $callableType = '(?:(?:const|volatile)\s+)*(?:auto|PFN_[A-Za-z0-9_]+)(?:\s+(?:const|volatile))*'
    $loadAliases = [System.Collections.Generic.List[object]]::new()
    foreach ($declaration in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*=\s*(?<rhs>[A-Za-z_]\w*)\s*\.\s*load\s*\([^;]*\)\s*;")) { $loadAliases.Add($declaration) }
    foreach ($declaration in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*(?:\{\s*(?<rhsBrace>[A-Za-z_]\w*)\s*\.\s*load\s*\([^;{}]*\)\s*\}|\(\s*(?<rhsParen>[A-Za-z_]\w*)\s*\.\s*load\s*\([^;()]*\)\s*\))\s*;")) { $loadAliases.Add($declaration) }
    foreach ($declaration in $loadAliases) {
        $rhs = if ($declaration.Groups['rhs'].Success) { $declaration.Groups['rhs'].Value } elseif ($declaration.Groups['rhsBrace'].Success) { $declaration.Groups['rhsBrace'].Value } else { $declaration.Groups['rhsParen'].Value }
        if ($typedAtomics.Contains($rhs)) { [void]$safeNames.Add($declaration.Groups['lhs'].Value) }
    }

    $aliases = [System.Collections.Generic.List[object]]::new()
    foreach ($declaration in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*=\s*&?\s*(?<rhs>[A-Za-z_]\w*)\s*;")) { $aliases.Add($declaration) }
    foreach ($declaration in [regex]::Matches($CleanBody, "\b$callableType\s+(?<lhs>[A-Za-z_]\w*)\s*(?:\{\s*&?\s*(?<rhsBrace>[A-Za-z_]\w*)\s*\}|\(\s*&?\s*(?<rhsParen>[A-Za-z_]\w*)\s*\))\s*;")) { $aliases.Add($declaration) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($declaration in $aliases) {
            $rhs = if ($declaration.Groups['rhs'].Success) { $declaration.Groups['rhs'].Value } elseif ($declaration.Groups['rhsBrace'].Success) { $declaration.Groups['rhsBrace'].Value } else { $declaration.Groups['rhsParen'].Value }
            if ($safeNames.Contains($rhs) -and $safeNames.Add($declaration.Groups['lhs'].Value)) { $changed = $true }
        }
    }
    return ,$safeNames
}

function Get-CppDeclaredFunctionPointerNames {
    param([string]$CleanSource, [System.Collections.Generic.HashSet[string]]$CustomCallableTypes)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $customAlternation = if ($CustomCallableTypes.Count -gt 0) { '|' + ((@($CustomCallableTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|') } else { '' }
    $callableType = "(?:(?:const|volatile)\s+)*(?:PFN_[A-Za-z0-9_]+$customAlternation)(?:\s+(?:const|volatile))*"
    foreach ($declaration in [regex]::Matches($CleanSource, "\b$callableType\s+(?<name>[A-Za-z_]\w*)\b")) {
        [void]$names.Add($declaration.Groups['name'].Value)
    }
    foreach ($declaration in [regex]::Matches($CleanSource, '\bstd::function\s*<[^;{}]+>\s+(?<name>[A-Za-z_]\w*)\b')) {
        [void]$names.Add($declaration.Groups['name'].Value)
    }
    return ,$names
}

function Get-UnresolvedIndirectCallNames {
    param(
        [string]$CleanBody,
        [object[]]$Functions,
        [System.Collections.Generic.HashSet[string]]$KnownVulkanPfns,
        [System.Collections.Generic.HashSet[string]]$SafeBridgeMetadataPfns,
        [System.Collections.Generic.HashSet[string]]$CustomCallableTypes,
        [System.Collections.Generic.HashSet[string]]$DeclaredCallableNames
    )
    $resolved = Get-CppLocalFunctionAliases $CleanBody $Functions $CustomCallableTypes
    $unresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($call in [regex]::Matches($CleanBody, '\(\s*\*\s*(?<name>[A-Za-z_]\w*)\s*\)\s*\(')) {
        $name = $call.Groups['name'].Value
        if (-not $resolved.ContainsKey($name) -and -not $KnownVulkanPfns.Contains($name) -and -not $SafeBridgeMetadataPfns.Contains($name)) { [void]$unresolved.Add($name) }
    }
    $customAlternation = if ($CustomCallableTypes.Count -gt 0) { '|' + ((@($CustomCallableTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|') } else { '' }
    $callableType = "(?:(?:const|volatile)\s+)*(?:auto|PFN_[A-Za-z0-9_]+$customAlternation)(?:\s+(?:const|volatile))*"
    foreach ($declaration in [regex]::Matches($CleanBody, "\b$callableType\s+(?<name>[A-Za-z_]\w*)\s*(?:=|\{|\()")) {
        $name = $declaration.Groups['name'].Value
        if ((Test-CppCallableInvocation $CleanBody $name) -and -not $resolved.ContainsKey($name) -and -not $KnownVulkanPfns.Contains($name) -and -not $SafeBridgeMetadataPfns.Contains($name)) {
            [void]$unresolved.Add($name)
        }
    }
    foreach ($name in @($DeclaredCallableNames)) {
        if ((Test-CppCallableInvocation $CleanBody $name) -and -not $resolved.ContainsKey($name) -and -not $KnownVulkanPfns.Contains($name) -and -not $SafeBridgeMetadataPfns.Contains($name)) {
            [void]$unresolved.Add($name)
        }
    }
    return @($unresolved)
}

function Find-PassivePathViolations {
    param([string]$Source)
    $violations = [System.Collections.Generic.List[string]]::new()
    $cleanSource = Remove-CppTrivia $Source
    $cachedVulkanPfns = Get-CachedRealVulkanPfnNames $Source
    $functions = @(Get-CppFunctionInfos $Source)
    $customCallableTypes = Get-CppFunctionPointerTypedefNames $cleanSource
    $declaredCallableNames = Get-CppDeclaredFunctionPointerNames $cleanSource $customCallableTypes
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
        $safeBridgeMetadataPfns = Get-SafeBridgeMetadataIndirectCallNames $cleanSource $clean
        foreach ($name in Get-UnresolvedIndirectCallNames $clean $functions $cachedVulkanPfns $safeBridgeMetadataPfns $customCallableTypes $declaredCallableNames) {
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
        @{ Text = 'auto const out = std::next(pModes, 1); *out = mode;'; Kind = 'pointer write' },
        @{ Text = 'auto const out{std::next(pModes, 1)}; *out = mode;'; Kind = 'pointer write' }
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
    $elseStaleCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); if (skipValidation) { observe(); } else { if (expectedGeneration != generation) { return -4; } }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; } std::copy(cachedModes.begin(), cachedModes.end(), pModes); return 0;
}
'@
    $elseCapacityCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (skipCapacity) { observe(); } else { if (*pCount < required) { return -5; } }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); return 0;
}
'@
    $goodAnalysis = Get-CopyOutAnalysis $goodCopy 'copy_modes' 'pModes'
    $badAnalysis = Get-CopyOutAnalysis $badCopy 'copy_modes' 'pModes'
    $badAddressAnalysis = Get-CopyOutAnalysis $badAddressCopy 'copy_modes' 'pModes'
    $conditionalStaleAnalysis = Get-CopyOutAnalysis $conditionalStaleCopy 'copy_modes' 'pModes'
    $conditionalCapacityAnalysis = Get-CopyOutAnalysis $conditionalCapacityCopy 'copy_modes' 'pModes'
    $elseStaleAnalysis = Get-CopyOutAnalysis $elseStaleCopy 'copy_modes' 'pModes'
    $elseCapacityAnalysis = Get-CopyOutAnalysis $elseCapacityCopy 'copy_modes' 'pModes'
    Assert-SelfCheck ($goodAnalysis.StaleDominates -and $goodAnalysis.Coherent -and $goodAnalysis.CapacitySafe) 'copy-out audit accepts coherent locked non-partial copy'
    Assert-SelfCheck (-not $badAnalysis.StaleDominates) 'copy-out audit rejects caller write before stale check'
    Assert-SelfCheck (-not $badAddressAnalysis.StaleDominates) 'copy-out audit rejects &pModes[0] destination before stale check'
    Assert-SelfCheck (-not $conditionalStaleAnalysis.StaleDominates) 'copy-out audit rejects stale guard nested in an optional branch'
    Assert-SelfCheck (-not $conditionalCapacityAnalysis.CapacitySafe) 'copy-out audit rejects capacity guard nested in an optional branch'
    Assert-SelfCheck (-not $elseStaleAnalysis.StaleDominates) 'copy-out audit rejects stale guard nested in else branch'
    Assert-SelfCheck (-not $elseCapacityAnalysis.CapacitySafe) 'copy-out audit rejects capacity guard nested in else branch'
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
    $passiveBridgeMetadataGetterGood = @'
typedef int32_t (*PFN_lsfg_interposer_bridge_get_snapshot_v2)(LsfgBridgeSnapshotV2 *outSnapshot);
std::atomic<PFN_lsfg_interposer_bridge_get_snapshot_v2> g_getSnapshotV2Fn{nullptr};
void v2a1_metadata_worker() {
    auto fn = g_getSnapshotV2Fn.load(std::memory_order_relaxed);
    LsfgBridgeSnapshotV2 snapshot{};
    fn(&snapshot);
}
'@
    $passiveOutside = 'void v2a1_metadata_worker() { query_metadata(); } void lsfg_vkQueuePresentKHR() { vkQueuePresentKHR(queue, info); }'
    $initWorkerGood = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void discover_bridge_exports() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }'
    $transitiveInitWorkerGood = 'std::atomic<bool> g_metadataWorkerStarted; void v2a1_metadata_worker() {} void start_probe() { if (!g_metadataWorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void discover_bridge_exports() { start_probe(); }'
    $everyFrameWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void render_frame() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }'
    $indirectEveryFrameWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void initialize_metadata() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void render_frame() { initialize_metadata(); }'
    $updateWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void initialize_metadata() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void update() { initialize_metadata(); }'
    $acquireWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void initialize_metadata() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void acquire_next_image() { initialize_metadata(); }'
    $observerWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void initialize_metadata() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } } void metadata_observer() { initialize_metadata(); }'
    $splitGateWorkerBad = 'std::atomic<bool> g_v2a1WorkerStarted; void v2a1_metadata_worker() {} void discover_bridge_exports() { std::thread worker(v2a1_metadata_worker); } void unrelated_once() { g_v2a1WorkerStarted.exchange(true); }'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveBad).Count -gt 0) 'passive audit rejects active Vulkan operation in V2A.1 path'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveCachedBad).Count -gt 0) 'passive audit rejects cached Vulkan PFN in V2A.1 path'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveHelperBad).Count -gt 0) 'passive audit transitively rejects active helper called by worker'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveIndirectHelperBad).Count -gt 0) 'passive audit rejects active helper reached through function-pointer alias'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveConstIndirectHelperBad).Count -gt 0) 'passive audit rejects active helper reached through const function-pointer alias'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveUnresolvedIndirectBad).Count -gt 0) 'passive audit conservatively rejects unresolved indirect worker call'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveBridgeMetadataGetterGood).Count -eq 0) 'passive audit accepts bridge metadata getter loaded from typed atomic'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveOutside).Count -eq 0) 'passive audit ignores existing wrapper outside V2A.1 path'
    Assert-SelfCheck (Get-ConsumerWorkerArrangement $initWorkerGood).InitializationTied 'worker audit accepts one-shot launch in export-discovery path'
    Assert-SelfCheck (Get-ConsumerWorkerArrangement $transitiveInitWorkerGood).InitializationTied 'worker audit ties delegated launch to parsed export-discovery root'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $everyFrameWorkerBad).InitializationTied) 'worker audit rejects one-shot launch from every-frame path'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $indirectEveryFrameWorkerBad).InitializationTied) 'worker audit rejects indirect every-frame reachability into init-named launcher'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $updateWorkerBad).InitializationTied) 'worker audit rejects update reachability into init-named launcher'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $acquireWorkerBad).InitializationTied) 'worker audit rejects acquire reachability into init-named launcher'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $observerWorkerBad).InitializationTied) 'worker audit rejects observer reachability into init-named launcher'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $splitGateWorkerBad).LaunchAndOneShot) 'worker audit rejects file-wide one-shot gate detached from launch root'

    $partialDirectCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != 0 && expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (pModes == nullptr) { *pCount = required; return 0; }
 if (*pCount < required) { return -5; } pModes[0] = cachedModes[0]; *pCount = required; return 0;
}
'@
    $invertedStaleCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration == generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); *pCount = required; return 0;
}
'@
    $completeLoopCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != 0 && expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 for (uint32_t i = 0; i < required; ++i) { pModes[i] = cachedModes[i]; }
 *pCount = required; return 0;
}
'@
    $earlyBreakLoopCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != 0 && expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 for (uint32_t i = 0; i < required; ++i) { if (stop) break; pModes[i] = cachedModes[i]; }
 *pCount = required; return 0;
}
'@
    $optionalInlineStaleCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != generation && validationEnabled) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); *pCount = required; return 0;
}
'@
    $completeCopyN = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != 0 && expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy_n(cachedModes.begin(), cachedModes.size(), pModes); *pCount = required; return 0;
}
'@
    $mismatchedRangeCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy(oneMode.begin(), oneMode.end(), pModes); *pCount = required; return 0;
}
'@
    $mismatchedCountCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy_n(oneMode.begin(), required, pModes); *pCount = required; return 0;
}
'@
    $fallthroughStaleCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration; int32_t status = 0;
 if (expectedGeneration != generation) { status = -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); *pCount = required; return status;
}
'@
    $reverseCapacityGuardCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (required > *pCount) { return -5; }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); *pCount = required; return 0;
}
'@
    $wrongCapacityCountCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); uint32_t wrongRequired = oneMode.size(); if (*pCount < wrongRequired) { return -5; }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); *pCount = required; return 0;
}
'@
    $wrongReturnedCountCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); *pCount = required - 1; return 0;
}
'@
    $missingReturnedCountCopy = @'
int32_t copy_modes(uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes) {
 std::lock_guard lock(g_stateMutex); uint64_t generation = g_metadataGeneration;
 if (expectedGeneration != generation) { return -4; }
 uint32_t required = cachedModes.size(); if (*pCount < required) { return -5; }
 std::copy(cachedModes.begin(), cachedModes.end(), pModes); return 0;
}
'@
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $partialDirectCopy 'copy_modes' 'pModes').CapacitySafe) 'copy-out audit rejects a single indexed write after a capacity guard'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $invertedStaleCopy 'copy_modes' 'pModes').StaleDominates) 'copy-out audit rejects inverted expected-generation equality as stale validation'
    Assert-SelfCheck (Get-CopyOutAnalysis $completeLoopCopy 'copy_modes' 'pModes').CapacitySafe 'copy-out audit accepts a required-count complete indexed loop'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $earlyBreakLoopCopy 'copy_modes' 'pModes').CapacitySafe) 'copy-out audit rejects a required-count loop with an early exit'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $optionalInlineStaleCopy 'copy_modes' 'pModes').StaleDominates) 'copy-out audit rejects a generation mismatch weakened by an optional predicate'
    Assert-SelfCheck (Get-CopyOutAnalysis $completeCopyN 'copy_modes' 'pModes').CapacitySafe 'copy-out audit accepts copy_n when source size and required count agree'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $mismatchedRangeCopy 'copy_modes' 'pModes').CapacitySafe) 'copy-out audit rejects a full range from a source smaller than required'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $mismatchedCountCopy 'copy_modes' 'pModes').CapacitySafe) 'copy-out audit rejects copy_n when source and required count disagree'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $fallthroughStaleCopy 'copy_modes' 'pModes').StaleDominates) 'copy-out audit rejects stale status assignment that falls through to data copy'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $wrongCapacityCountCopy 'copy_modes' 'pModes').CapacitySafe) 'copy-out audit rejects a capacity guard for a count different from the copied source'
    Assert-SelfCheck (Get-CopyOutAnalysis $reverseCapacityGuardCopy 'copy_modes' 'pModes').CapacitySafe 'copy-out audit accepts the equivalent reversed capacity guard'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $wrongReturnedCountCopy 'copy_modes' 'pModes').CapacitySafe) 'copy-out audit rejects a returned count different from the copied element count'
    Assert-SelfCheck (-not (Get-CopyOutAnalysis $missingReturnedCountCopy 'copy_modes' 'pModes').CapacitySafe) 'copy-out audit rejects a copy that never reports the copied count'

    $lockTransitiveHelper = @'
void query_modes_helper() { realGetModes(physicalDevice, surface, &count, modes); }
void bad_locked_helper() { std::lock_guard lock(g_stateMutex); query_modes_helper(); }
'@
    $lockCustomTypedef = @'
typedef VkResult (*RealVulkanPresentModesFn)(VkPhysicalDevice, VkSurfaceKHR, uint32_t *, VkPresentModeKHR *);
RealVulkanPresentModesFn cachedModes;
void bad_custom_typedef() { std::lock_guard lock(g_stateMutex); cachedModes(physicalDevice, surface, &count, modes); }
'@
    $lockAliasedVulkanTypedef = @'
typedef PFN_vkGetPhysicalDeviceSurfacePresentModesKHR ModesGetter;
ModesGetter cachedModes;
void bad_aliased_vulkan_typedef() { std::lock_guard lock(g_stateMutex); cachedModes(physicalDevice, surface, &count, modes); }
'@
    $lockStdInvoke = @'
PFN_vkGetPhysicalDeviceSurfacePresentModesKHR cachedModes;
void bad_std_invoke() { std::lock_guard lock(g_stateMutex); std::invoke(cachedModes, physicalDevice, surface, &count, modes); }
'@
    $lockMapMethodSafe = 'void map_lookup_is_not_a_pfn() { std::lock_guard lock(g_stateMutex); auto it = stateBySwapchain.find(swapchain); }'
    $lockPostDeclarationHelper = @'
void query_modes_helper() { realGetModes(physicalDevice, surface, &count, modes); }
void bad_locked_post_alias() { std::lock_guard lock(g_stateMutex); auto invoke; invoke = query_modes_helper; invoke(); }
'@
    $lockStdFunctionTypeAlias = @'
using HelperCallable = std::function<void()>;
void query_modes_helper() { realGetModes(physicalDevice, surface, &count, modes); }
void bad_std_function_type_alias() { HelperCallable invoke; invoke = query_modes_helper; std::lock_guard lock(g_stateMutex); invoke(); }
'@
    $lockStdFunctionVulkan = @'
PFN_vkGetPhysicalDeviceSurfacePresentModesKHR cachedModes;
void bad_std_function_vulkan() { std::function<VkResult(VkPhysicalDevice, VkSurfaceKHR, uint32_t *, VkPresentModeKHR *)> invoke; invoke = cachedModes; std::lock_guard lock(g_stateMutex); invoke(physicalDevice, surface, &count, modes); }
'@
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockTransitiveHelper).Count -gt 0) 'lock audit follows a locked caller into a real-Vulkan helper'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockCustomTypedef).Count -gt 0) 'lock audit rejects a custom-typedef cached Vulkan function pointer'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockAliasedVulkanTypedef).Count -gt 0) 'lock audit rejects a custom typedef aliased from a Vulkan PFN type'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockStdInvoke).Count -gt 0) 'lock audit rejects std::invoke of a cached Vulkan PFN'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockMapMethodSafe).Count -eq 0) 'lock audit preserves ordinary map method calls under the mutex'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockPostDeclarationHelper).Count -gt 0) 'lock audit follows a helper alias assigned after declaration'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockStdFunctionVulkan).Count -gt 0) 'lock audit rejects a std::function wrapper for a real Vulkan PFN'
    Assert-SelfCheck (@(Find-RealVulkanCallsUnderStateMutex $lockStdFunctionTypeAlias).Count -gt 0) 'lock audit rejects a using std::function alias for a real-Vulkan helper'

    $passiveExactMetadataGettersGood = @'
typedef int32_t (*PFN_lsfg_interposer_bridge_get_snapshot_v2)(LsfgBridgeSnapshotV2 *);
typedef int32_t (*PFN_lsfg_interposer_bridge_get_swapchain_images_v2)(uint64_t, VkSwapchainKHR, uint32_t *, VkImage *);
typedef int32_t (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(uint64_t, VkSwapchainKHR, uint32_t *, VkPresentModeKHR *);
std::atomic<PFN_lsfg_interposer_bridge_get_snapshot_v2> snapshotGetter;
std::atomic<PFN_lsfg_interposer_bridge_get_swapchain_images_v2> imageGetter;
std::atomic<PFN_lsfg_interposer_bridge_get_present_modes_v2> modeGetter;
void v2a1_metadata_worker() { auto s = snapshotGetter.load(); auto i = imageGetter.load(); auto m = modeGetter.load(); s(&snapshot); i(generation, swapchain, &imageCount, images); m(generation, swapchain, &modeCount, modes); }
'@
    $passiveMadeUpBridgePfnBad = @'
typedef int32_t (*PFN_lsfg_interposer_bridge_submit_active)(VkQueue, const VkSubmitInfo *);
PFN_lsfg_interposer_bridge_submit_active submitActive;
void v2a1_metadata_worker() { submitActive(queue, submitInfo); }
'@
    $passiveUnknownCustomCallableBad = @'
typedef int32_t (*MetadataCallable)(void *);
MetadataCallable metadataCallable;
void v2a1_metadata_worker() { metadataCallable(&snapshot); }
'@
    $passiveUnknownStdFunctionTypeAliasBad = @'
using UnknownCallable = std::function<void()>;
void v2a1_metadata_worker() { UnknownCallable invoke; invoke = external_callable; invoke(); }
'@
    $passiveUnknownStdFunctionBad = @'
void v2a1_metadata_worker() { std::function<void()> invoke; invoke = external_callable; invoke(); }
'@
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveExactMetadataGettersGood).Count -eq 0) 'passive audit accepts only explicitly typed exact metadata getter PFNs'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveMadeUpBridgePfnBad).Count -gt 0) 'passive audit rejects a made-up active bridge PFN'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveUnknownCustomCallableBad).Count -gt 0) 'passive audit conservatively rejects an unknown custom callable type'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveUnknownStdFunctionBad).Count -gt 0) 'passive audit conservatively rejects an unknown std::function worker call'
    Assert-SelfCheck (@(Find-PassivePathViolations $passiveUnknownStdFunctionTypeAliasBad).Count -gt 0) 'passive audit conservatively rejects an unknown using std::function type alias'

    $usingStdFunctionEveryFrameWorkerBad = @'
std::atomic<bool> g_v2a1WorkerStarted;
void v2a1_metadata_worker() {}
void discover_bridge_exports() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }
using MetadataStarter = std::function<void()>;
void render_frame() { MetadataStarter invoke; invoke = discover_bridge_exports; invoke(); }
'@
    $customAliasEveryFrameWorkerBad = @'
std::atomic<bool> g_v2a1WorkerStarted;
void v2a1_metadata_worker() {}
void initialize_metadata() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }
typedef void (*MetadataStarter)();
void render_frame() { MetadataStarter starter = initialize_metadata; starter(); }
'@
    $postDeclarationEveryFrameWorkerBad = @'
std::atomic<bool> g_v2a1WorkerStarted;
void v2a1_metadata_worker() {}
void discover_bridge_exports() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }
void render_frame() { auto invoke; invoke = discover_bridge_exports; invoke(); }
'@
    $customPostDeclarationEveryFrameWorkerBad = @'
std::atomic<bool> g_v2a1WorkerStarted;
void v2a1_metadata_worker() {}
void discover_bridge_exports() { if (!g_v2a1WorkerStarted.exchange(true)) { std::thread worker(v2a1_metadata_worker); } }
typedef void (*MetadataStarter)();
void render_frame() { MetadataStarter invoke; invoke = discover_bridge_exports; invoke(); }
'@
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $customAliasEveryFrameWorkerBad).InitializationTied) 'worker audit rejects render reachability through a custom function-pointer typedef alias'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $postDeclarationEveryFrameWorkerBad).InitializationTied) 'worker audit rejects render reachability through an auto alias assigned after declaration'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $customPostDeclarationEveryFrameWorkerBad).InitializationTied) 'worker audit rejects render reachability through a custom typedef alias assigned after declaration'
    Assert-SelfCheck (-not (Get-ConsumerWorkerArrangement $usingStdFunctionEveryFrameWorkerBad).InitializationTied) 'worker audit rejects render reachability through a using std::function alias'

    $disabledCompleteAbi = @'
#if 0
#if 1
struct LsfgBridgeSnapshotV2 {
uint32_t abiVersion; uint32_t structSize; uint64_t generation; VkInstance instance; VkPhysicalDevice physicalDevice; VkDevice device;
VkQueue presentQueue; uint32_t queueFamilyIndex; uint32_t queueIndex; VkDeviceQueueCreateFlags queueFlags; VkSurfaceKHR surface; VkSwapchainKHR swapchain;
VkFormat imageFormat; VkColorSpaceKHR imageColorSpace; VkExtent2D imageExtent; uint32_t imageArrayLayers; VkImageUsageFlags imageUsage; VkSharingMode imageSharingMode;
VkSurfaceTransformFlagBitsKHR preTransform; VkCompositeAlphaFlagBitsKHR compositeAlpha; VkPresentModeKHR presentMode; VkBool32 clipped; VkSwapchainKHR oldSwapchain;
uint32_t requestedMinImageCount; uint32_t actualImageCount; uint32_t imageCapacity; VkImage images[LSFG_BRIDGE_MAX_SWAPCHAIN_IMAGES];
VkSurfaceCapabilitiesKHR surfaceCapabilities; uint32_t supportedPresentModeCount; uint32_t presentModeCapacity;
VkPresentModeKHR supportedPresentModes[LSFG_BRIDGE_MAX_PRESENT_MODES]; uint32_t validMask; VkQueueFlags queueFamilyFlags; uint32_t queueFamilyQueueCount;
};
int32_t lsfg_interposer_bridge_get_snapshot_v2(LsfgBridgeSnapshotV2 *outSnapshot) { hostSnapshot.device = dev; hostSnapshot.validMask |= 0x01; return 0; }
#endif
#endif
'@
    Assert-SelfCheck (-not (Test-V2AbiLayout $disabledCompleteAbi).Prefix) 'preprocessor audit masks nested disabled ABI declarations'
    Assert-SelfCheck (@(Get-CppFunctionInfos $disabledCompleteAbi).Count -eq 0) 'preprocessor audit masks functions in nested disabled blocks'
    Assert-SelfCheck (-not (Get-ExistingValidityBitAnalysis $disabledCompleteAbi).Core) 'preprocessor audit masks validity mappings in nested disabled blocks'
    $disabledLeftCompound = $disabledCompleteAbi.Replace('#if 0', '#if 0 && defined(X)')
    $disabledRightCompound = $disabledCompleteAbi.Replace('#if 0', '#if defined(X) && 0')
    $disabledNegatedCompound = $disabledCompleteAbi.Replace('#if 0', '#if !defined(X) && 0')
    Assert-SelfCheck (@(Get-CppFunctionInfos $disabledLeftCompound).Count -eq 0) 'preprocessor audit masks nested code under #if 0 && defined(X)'
    Assert-SelfCheck (@(Get-CppFunctionInfos $disabledRightCompound).Count -eq 0) 'preprocessor audit masks nested code under #if defined(X) && 0'
    Assert-SelfCheck (@(Get-CppFunctionInfos $disabledNegatedCompound).Count -eq 0) 'preprocessor audit masks nested code under #if !defined(X) && 0'

    $queueBitEnumOnly = 'enum BridgeValidity { LSFG_BRIDGE_VALID_QUEUE = 0x40 };'
    $queueBitLive = 'void consume_snapshot() { if (snapshot.validMask & 0x40) { log(snapshot.queueFamilyFlags, snapshot.queueFamilyQueueCount); } }'
    $queueBitProducerLive = 'void make_snapshot() { hostSnapshot.queueFamilyFlags = props.queueFlags; hostSnapshot.queueFamilyQueueCount = props.queueCount; hostSnapshot.validMask |= 0x40; }'
    $queueBitInverted = 'void consume_snapshot() { if (!(snapshot.validMask & 0x40)) { log(snapshot.queueFamilyFlags, snapshot.queueFamilyQueueCount); } }'
    $queueBitProximityOnly = 'void consume_snapshot() { if (snapshot.validMask & 0x40) { log(other.queueFamilyFlags, other.queueFamilyQueueCount); } }'
    $queueBitTextOnly = 'void make_snapshot() { snapshot.queueFamilyFlags = props.queueFlags; snapshot.queueFamilyQueueCount = props.queueCount; }'
    Assert-SelfCheck (-not (Test-NewQueueValidityBit $queueBitEnumOnly)) 'queue validity audit rejects an unused enum-only 0x40 declaration'
    Assert-SelfCheck (Test-NewQueueValidityBit $queueBitLive) 'queue validity audit accepts a live 0x40 queue-field consumer check'
    Assert-SelfCheck (Test-NewQueueValidityBit $queueBitProducerLive) 'queue validity audit accepts producer assignment of both queue fields before setting 0x40'
    Assert-SelfCheck (-not (Test-NewQueueValidityBit $queueBitInverted)) 'queue validity audit rejects an inverted 0x40 consumer check'
    Assert-SelfCheck (-not (Test-NewQueueValidityBit $queueBitProximityOnly)) 'queue validity audit rejects fields from the wrong queue-family object'
    Assert-SelfCheck (-not (Test-NewQueueValidityBit $queueBitTextOnly)) 'queue validity audit rejects queue fields that are never emitted or validated by 0x40'

    $presentModesTypedef = 'typedef int32_t (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes);'
    $presentModesProducer = 'int32_t lsfg_interposer_bridge_get_present_modes_v2(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes) { return 0; }'
    $wrongPresentModesTypedefs = @(
        @{ Name = 'wrong argument order'; Text = 'typedef int32_t (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(VkSwapchainKHR swapchain, uint64_t expectedGeneration, uint32_t *pCount, VkPresentModeKHR *pModes);' },
        @{ Name = 'wrong swapchain type'; Text = 'typedef int32_t (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(uint64_t expectedGeneration, VkSurfaceKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes);' },
        @{ Name = 'missing expectedGeneration'; Text = 'typedef int32_t (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes);' },
        @{ Name = 'wrong present-mode pointer'; Text = 'typedef int32_t (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkImage *pModes);' },
        @{ Name = 'wrong return type'; Text = 'typedef void (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes);' }
    )
    $wrongConsumerTypedefWithProducer = 'typedef void (*PFN_lsfg_interposer_bridge_get_present_modes_v2)(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes); int32_t lsfg_interposer_bridge_get_present_modes_v2(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes) { return 0; }'
    Assert-SelfCheck (Test-ExactPresentModesSignature $presentModesTypedef) 'present-mode signature audit accepts the canonical consumer typedef declaration'
    Assert-SelfCheck (Test-ExactPresentModesProducerSignature $presentModesProducer) 'present-mode signature audit accepts the exact producer definition independently'
    $presentModesProducerDeclarationOnly = 'int32_t lsfg_interposer_bridge_get_present_modes_v2(uint64_t expectedGeneration, VkSwapchainKHR swapchain, uint32_t *pCount, VkPresentModeKHR *pModes);'
    Assert-SelfCheck (-not (Test-ExactPresentModesProducerSignature $presentModesProducerDeclarationOnly)) 'present-mode signature audit rejects a declaration without a producer definition'
    Assert-SelfCheck (-not (Test-ExactPresentModesSignature $wrongConsumerTypedefWithProducer)) 'consumer present-mode ABI audit rejects a void typedef even when a producer-style function is present'
    foreach ($fixture in $wrongPresentModesTypedefs) {
        Assert-SelfCheck (-not (Test-ExactPresentModesSignature $fixture.Text)) "consumer present-mode ABI audit rejects $($fixture.Name)"
    }

    $allV2A1Labels = @('generation=', 'currentExtent=', 'minImageExtent=', 'maxImageExtent=', 'maxImageArrayLayers=', 'supportedTransforms=', 'currentTransform=', 'supportedCompositeAlpha=', 'supportedUsageFlags=', 'queueFamilyFlags=', 'queueFamilyQueueCount=', 'supportedPresentModeCount=', 'supportedPresentModes=', 'swapchainImageCount=', 'swapchainImageCopyOutStatus=')
    $legacyGenerationOnly = 'void legacy_log() { LOGI("[LSFG-V2A] generation="); } void emit_v2a1() { LOGI("[LSFG-V2A1] currentExtent= minImageExtent= maxImageExtent= maxImageArrayLayers= supportedTransforms= currentTransform= supportedCompositeAlpha= supportedUsageFlags= queueFamilyFlags= queueFamilyQueueCount= supportedPresentModeCount= supportedPresentModes= swapchainImageCount= swapchainImageCopyOutStatus="); }'
    $completeV2A1Log = $legacyGenerationOnly.Replace('[LSFG-V2A1] currentExtent=', '[LSFG-V2A1] generation= currentExtent=')
    $deadDiagnostic = @'
#if 0
void emit_v2a1_dead() { LOGI("[LSFG-V2A1] generation= currentExtent= minImageExtent= maxImageExtent= maxImageArrayLayers= supportedTransforms= currentTransform= supportedCompositeAlpha= supportedUsageFlags= queueFamilyFlags= queueFamilyQueueCount= supportedPresentModeCount= supportedPresentModes= swapchainImageCount= swapchainImageCopyOutStatus="); }
#endif
'@
    $unrelatedDiagnostic = @'
void unrelated_helper() { LOGI("[LSFG-V2A1] generation= currentExtent= minImageExtent= maxImageExtent= maxImageArrayLayers= supportedTransforms= currentTransform= supportedCompositeAlpha= supportedUsageFlags= queueFamilyFlags= queueFamilyQueueCount= supportedPresentModeCount= supportedPresentModes= swapchainImageCount= swapchainImageCopyOutStatus="); }
'@
    $presentCallbackDiagnostic = @'
void lsfg_present_observer_callback_v1() { LOGI("[LSFG-V2A1] generation= currentExtent= minImageExtent= maxImageExtent= maxImageArrayLayers= supportedTransforms= currentTransform= supportedCompositeAlpha= supportedUsageFlags= queueFamilyFlags= queueFamilyQueueCount= supportedPresentModeCount= supportedPresentModes= swapchainImageCount= swapchainImageCopyOutStatus="); }
'@
    $unusedCompleteV2A1String = 'void emit_v2a1() { const char *unused = "[LSFG-V2A1] generation= currentExtent= minImageExtent= maxImageExtent= maxImageArrayLayers= supportedTransforms= currentTransform= supportedCompositeAlpha= supportedUsageFlags= queueFamilyFlags= queueFamilyQueueCount= supportedPresentModeCount= supportedPresentModes= swapchainImageCount= swapchainImageCopyOutStatus="; LOGI("metadata unavailable"); }'
    Assert-SelfCheck (-not (Test-V2A1DiagnosticBlock $legacyGenerationOnly $allV2A1Labels).Complete) 'V2A.1 log audit rejects generation supplied only by a legacy V2A diagnostic'
    Assert-SelfCheck (-not (Test-V2A1DiagnosticBlock $unusedCompleteV2A1String $allV2A1Labels).Complete) 'V2A.1 log audit rejects complete labels in an unused string variable'
    Assert-SelfCheck (-not (Test-V2A1DiagnosticBlock $deadDiagnostic $allV2A1Labels).Complete) 'V2A.1 log audit rejects labels in a disabled diagnostic function'
    Assert-SelfCheck (-not (Test-V2A1DiagnosticBlock $unrelatedDiagnostic $allV2A1Labels).Complete) 'V2A.1 log audit rejects a complete diagnostic in an unrelated function'
    Assert-SelfCheck (-not (Test-V2A1DiagnosticBlock $presentCallbackDiagnostic $allV2A1Labels).Complete) 'V2A.1 log audit rejects a complete diagnostic inside the present callback'
    Assert-SelfCheck (Test-V2A1DiagnosticBlock $completeV2A1Log $allV2A1Labels).Complete 'V2A.1 log audit accepts all labels in one emitted literal-tagged diagnostic block'
}

function Invoke-ProducerChecks {
    $scope = 'producer'; $source = Read-RequiredSource $ProducerPath
    Assert-V2AbiLayout $source $scope
    Assert-ExistingValidityBits $source $scope
    Add-Result (Test-NewQueueValidityBit $source) $scope 'new queue-family capability validity bit is semantically tied to queue fields at code value 0x40' 'no uncommented queue-field/0x40 mapping was found'
    Assert-StructSizeBoundedSnapshotCopy $source $scope
    Assert-ExactPresentModesProducerSignature $source $scope
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
    $v2a1Labels = @('generation=', 'currentExtent=', 'minImageExtent=', 'maxImageExtent=', 'maxImageArrayLayers=', 'supportedTransforms=', 'currentTransform=', 'supportedCompositeAlpha=', 'supportedUsageFlags=', 'queueFamilyFlags=', 'queueFamilyQueueCount=', 'supportedPresentModeCount=', 'supportedPresentModes=', 'swapchainImageCount=', 'swapchainImageCopyOutStatus=')
    $diagnostic = Test-V2A1DiagnosticBlock $source $v2a1Labels
    Add-Result ($diagnostic.CandidateFunctions.Count -gt 0) $Scope 'consumer emits the required one-shot [LSFG-V2A1] diagnostic label in a parsed function string literal' 'no parsed diagnostic function contains the exact literal tag'
    Assert-Pattern $clean '(?:v2a1|metadata|snapshot)[A-Za-z0-9_]*\s*\.\s*exchange\s*\(\s*true\s*\)' $Scope 'consumer guards the V2A.1 diagnostic with one-shot atomic exchange'
    Assert-Pattern $clean 'std::vector\s*<\s*VkImage\s*>' $Scope 'consumer allocates caller-owned swapchain-image storage outside the present callback'
    Assert-Pattern $clean 'actualImageCount[\s\S]{0,500}?(?:!=|==)[\s\S]{0,120}?(?:imageCount|copyOutImageCount)|(?:imageCount|copyOutImageCount)[\s\S]{0,120}?(?:!=|==)[\s\S]{0,500}?actualImageCount' $Scope 'consumer validates copied image count against snapshot.actualImageCount'
    Assert-Pattern $clean 'VkImage[\s\S]{0,700}?(?:==|!=)\s*VK_NULL_HANDLE' $Scope 'consumer validates every copied swapchain image handle is non-null'
    Assert-Pattern $clean 'std::vector\s*<\s*VkPresentModeKHR\s*>' $Scope 'consumer allocates caller-owned present-mode storage'
    foreach ($mode in @('VK_PRESENT_MODE_IMMEDIATE_KHR', 'VK_PRESENT_MODE_MAILBOX_KHR', 'VK_PRESENT_MODE_FIFO_KHR', 'VK_PRESENT_MODE_FIFO_RELAXED_KHR')) { Assert-Pattern $source ([regex]::Escape($mode)) $Scope "consumer decodes $mode symbolically" }
    Assert-Pattern $source '(?:UNKNOWN|unknown|numeric)[^\r\n]*%[diu]' $Scope 'consumer retains a numeric label for unknown/vendor present modes'
    foreach ($label in $v2a1Labels) { Add-Result $diagnostic.Complete $Scope "required V2A.1 log label $label is present in the same diagnostic function as literal [LSFG-V2A1]" 'labels split across legacy, unrelated, or incomplete diagnostic functions do not satisfy V2A.1' }
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
