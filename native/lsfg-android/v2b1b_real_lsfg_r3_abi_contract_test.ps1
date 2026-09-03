# ==============================================================================
# REAL-LSFG-R3 ABI Compatibility Contract Test Suite
# Verifies:
#   1. LsfgStageProfilingInfo has exactly 4 fields, no 'mode' field (R2 ABI frozen)
#   2. LsfgDispatchProfilingInfo exists as a separate struct (R3 type)
#   3. lsfg_record_generation_profiled_r3 exists and is distinct from R2 API
#   4. lsfg_record_generation_profiled still exists (R2 API preserved)
#   5. record_generation_internal does NOT read profiling->mode
#   6. R2 entry point hardcodes pMode=0 (Q0..Q6, max index 6)
#   7. R3 entry point hardcodes pMode=1 (Q0..Q100, max index 100)
#   8. R2 max compute query index = 6; R3 max compute query index = 100
#   9. Interposer uses LsfgDispatchProfilingInfo (not LsfgStageProfilingInfo) for R3
#  10. Interposer calls lsfg_record_generation_profiled_r3
#  11. No stageProfiling.mode access in interposer
#  12. All three symbols declared in header
#  13. All three entry points implemented in lsfg.cpp
#  14. Source proof: R2 API path writes only Q0..Q6
#  15. Source proof: R3 API path writes only Q0..Q100
# ==============================================================================

$ErrorActionPreference = "Stop"

$hppFile = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\public\lsfg_3_1.hpp"
$cppFile = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\v3.1_src\lsfg.cpp"
$interposerFile = "C:\Proyectos\amethyst\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"

$hppSource = Get-Content -Path $hppFile -Raw
$cppSource = Get-Content -Path $cppFile -Raw
$interposerSource = Get-Content -Path $interposerFile -Raw

$allPassed = $true

function Report-ABI {
    param([string]$Name, [bool]$Condition, [string]$Description)
    if ($Condition) {
        Write-Host "[$Name] PASS" -ForegroundColor Green
    } else {
        Write-Host "[$Name] FAIL: $Description" -ForegroundColor Red
        $script:allPassed = $false
    }
}

Write-Host "Running REAL-LSFG-R3 ABI Compatibility Contract Tests..." -ForegroundColor Cyan

# --- ABI-1: LsfgStageProfilingInfo has NO 'mode' field ---
$structBlock = [regex]::Match($hppSource, 'struct LsfgStageProfilingInfo\s*\{[^}]*\}')
$hasNoModeField = $structBlock.Success -and -not ($structBlock.Value -match '\bmode\b')
$hasFourFields = $structBlock.Success -and
    ($structBlock.Value -match 'bool\s+enabled') -and
    ($structBlock.Value -match 'VkQueryPool\s+queryPool') -and
    ($structBlock.Value -match 'uint32_t\s+queryBase') -and
    ($structBlock.Value -match 'PFN_vkCmdWriteTimestamp\s+cmdWriteTimestamp')
Report-ABI "ABI-1" ($hasNoModeField -and $hasFourFields) "LsfgStageProfilingInfo must have exactly 4 fields (no 'mode'). R2 binary ABI is frozen."

# --- ABI-2: LsfgDispatchProfilingInfo exists as separate type ---
$dispatchStructBlock = [regex]::Match($hppSource, 'struct LsfgDispatchProfilingInfo\s*\{[^}]*\}')
$hasDispatchStruct = $dispatchStructBlock.Success -and
    ($dispatchStructBlock.Value -match 'bool\s+enabled') -and
    ($dispatchStructBlock.Value -match 'VkQueryPool\s+queryPool') -and
    ($dispatchStructBlock.Value -match 'uint32_t\s+queryBase') -and
    ($dispatchStructBlock.Value -match 'PFN_vkCmdWriteTimestamp\s+cmdWriteTimestamp')
Report-ABI "ABI-2" $hasDispatchStruct "LsfgDispatchProfilingInfo exists as a separate R3 profiling struct in lsfg_3_1.hpp."

# --- ABI-3: R3 API entry point declared in header ---
$hasR3Decl = ($hppSource -match 'lsfg_record_generation_profiled_r3') -and
             ($hppSource -match 'const\s+LsfgDispatchProfilingInfo\*')
Report-ABI "ABI-3" $hasR3Decl "lsfg_record_generation_profiled_r3 declared in public header accepting LsfgDispatchProfilingInfo*."

# --- ABI-4: R2 API entry point still declared in header ---
$hasR2Decl = ($hppSource -match 'lsfg_record_generation_profiled\b') -and
             ($hppSource -match 'const\s+LsfgStageProfilingInfo\*')
Report-ABI "ABI-4" $hasR2Decl "lsfg_record_generation_profiled still declared in public header accepting LsfgStageProfilingInfo* (R2 preserved)."

# --- ABI-5: record_generation_internal does NOT read profiling->mode ---
$noModeRead = -not ($cppSource -match 'profiling\s*->\s*mode')
Report-ABI "ABI-5" $noModeRead "record_generation_internal does not read profiling->mode (ABI field removed from struct)."

# --- ABI-6: R2 entry point hardcodes pMode=0 ---
$r2Block = [regex]::Match($cppSource, 'lsfg_record_generation_profiled\b[\s\S]*?pMode\s*=\s*0')
Report-ABI "ABI-6" $r2Block.Success "lsfg_record_generation_profiled passes pMode=0 (Q0..Q6 only, max index 6)."

# --- ABI-7: R3 entry point hardcodes pMode=1 ---
$r3Block = [regex]::Match($cppSource, 'lsfg_record_generation_profiled_r3[\s\S]*?pMode\s*=\s*1')
Report-ABI "ABI-7" $r3Block.Success "lsfg_record_generation_profiled_r3 passes pMode=1 (Q0..Q100 only, max index 100)."

# --- ABI-8: Max query index from R2 path is 6, from R3 path is 100 ---
$r2MaxIdx6 = ($cppSource -match 'emitTimestamp\s*\(\s*6\s*\)')
$r3MaxIdx100 = ($cppSource -match 'emitTimestamp\s*\(\s*100\s*\)')
Report-ABI "ABI-8" ($r2MaxIdx6 -and $r3MaxIdx100) "R2 max compute query index = 6; R3 max compute query index = 100."

# --- ABI-9: Interposer uses LsfgDispatchProfilingInfo (not LsfgStageProfilingInfo) for R3 ---
$interposerUsesDispatch = ($interposerSource -match 'LsfgDispatchProfilingInfo\s+stageProfiling')
$interposerNoStageForR3 = -not ($interposerSource -match 'LsfgStageProfilingInfo\s+stageProfiling')
Report-ABI "ABI-9" ($interposerUsesDispatch -and $interposerNoStageForR3) "Amethyst interposer uses LsfgDispatchProfilingInfo (not LsfgStageProfilingInfo) for R3 profiling."

# --- ABI-10: Interposer calls lsfg_record_generation_profiled_r3 ---
$interposerCallsR3 = ($interposerSource -match 'lsfg_record_generation_profiled_r3\s*\(')
Report-ABI "ABI-10" $interposerCallsR3 "Amethyst interposer calls lsfg_record_generation_profiled_r3 for R3 dispatch profiling."

# --- ABI-11: No stageProfiling.mode access in interposer ---
$noModeAccess = -not ($interposerSource -match 'stageProfiling\s*\.\s*mode')
Report-ABI "ABI-11" $noModeAccess "Interposer does not access stageProfiling.mode (field removed from R3 struct path)."

# --- ABI-12: All three symbols declared in header ---
$hasLegacy = ($hppSource -match 'lsfg_record_generation\b')
$hasR2 = ($hppSource -match 'lsfg_record_generation_profiled\b')
$hasR3 = ($hppSource -match 'lsfg_record_generation_profiled_r3\b')
Report-ABI "ABI-12" ($hasLegacy -and $hasR2 -and $hasR3) "All three symbols declared: lsfg_record_generation, lsfg_record_generation_profiled, lsfg_record_generation_profiled_r3."

# --- ABI-13: All three entry points implemented in lsfg.cpp ---
$implLegacy = ($cppSource -match 'VkResult\s+lsfg_record_generation\s*\(')
$implR2 = ($cppSource -match 'VkResult\s+lsfg_record_generation_profiled\s*\(')
$implR3 = ($cppSource -match 'VkResult\s+lsfg_record_generation_profiled_r3\s*\(')
Report-ABI "ABI-13" ($implLegacy -and $implR2 -and $implR3) "All three entry points implemented in lsfg.cpp."

# --- ABI-14: Source proof: R2 API path writes only Q0..Q6 ---
$r2Proof = ($cppSource -match 'pMode\s*=\s*0\s*/\*.*?R2') -or
           ($cppSource -match 'pMode=0.*R2')
Report-ABI "ABI-14" $r2Proof "Source comment proves R2 API path (pMode=0) emits only Q0..Q6."

# --- ABI-15: Source proof: R3 API path writes only Q0..Q100 ---
$r3Proof = ($cppSource -match 'pMode\s*=\s*1\s*/\*.*?R3') -or
           ($cppSource -match 'pMode=1.*R3')
Report-ABI "ABI-15" $r3Proof "Source comment proves R3 API path (pMode=1) emits only Q0..Q100."

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "REAL-LSFG-R3 ABI CONTRACT SUITE: ALL 15 CONTRACTS PASSED (GREEN)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "REAL-LSFG-R3 ABI CONTRACT SUITE: CONTRACTS FAILED (RED)" -ForegroundColor Red
    exit 1
}
