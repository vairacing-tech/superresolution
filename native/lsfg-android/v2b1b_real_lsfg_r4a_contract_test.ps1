# v2b1b_real_lsfg_r4a_contract_test.ps1
# Contract test for REAL-LSFG R4-A Delta L2 Terminal Bypass Experiment

$ErrorActionPreference = "Stop"
$failures = @()

function Assert-Condition($cond, $msg) {
    if (-not $cond) {
        Write-Host "[FAIL] $msg" -ForegroundColor Red
        $script:failures += $msg
    } else {
        Write-Host "[PASS] $msg" -ForegroundColor Green
    }
}

Write-Host "=== REAL-LSFG R4-A CONTRACT TEST ===" -ForegroundColor Cyan

# 1. Inspect lsfg_3_1.hpp for ABI & API safety
$headerPath = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\public\lsfg_3_1.hpp"
Assert-Condition (Test-Path $headerPath) "Header lsfg_3_1.hpp exists"

$headerContent = Get-Content $headerPath -Raw

# Check frozen R2 ABI preserved
Assert-Condition ($headerContent -match "struct\s+LsfgStageProfilingInfo\s*\{[^}]*bool\s+enabled[^}]*VkQueryPool\s+queryPool[^}]*uint32_t\s+queryBase[^}]*PFN_vkCmdWriteTimestamp\s+cmdWriteTimestamp[^}]*\}") "R2 LsfgStageProfilingInfo preserved exactly"
Assert-Condition ($headerContent -match "lsfg_record_generation_profiled\s*\(") "R2 lsfg_record_generation_profiled function exists"

# Check frozen R3 ABI preserved
Assert-Condition ($headerContent -match "struct\s+LsfgDispatchProfilingInfo\s*\{[^}]*bool\s+enabled[^}]*VkQueryPool\s+queryPool[^}]*uint32_t\s+queryBase[^}]*PFN_vkCmdWriteTimestamp\s+cmdWriteTimestamp[^}]*\}") "R3 LsfgDispatchProfilingInfo preserved exactly"
Assert-Condition ($headerContent -match "lsfg_record_generation_profiled_r3\s*\(") "R3 lsfg_record_generation_profiled_r3 function exists"

# Check new R4-A versioned API exists
Assert-Condition ($headerContent -match "struct\s+LsfgR4AOptions\s*\{") "R4-A LsfgR4AOptions struct exists"
Assert-Condition ($headerContent -match "lsfg_record_generation_profiled_r4a\s*\(") "R4-A lsfg_record_generation_profiled_r4a entry point declared"

# 2. Inspect lsfg.cpp for Delta L2 bypass logic and query preservation
$lsfgCppPath = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\v3.1_src\lsfg.cpp"
Assert-Condition (Test-Path $lsfgCppPath) "lsfg.cpp exists"
$lsfgContent = Get-Content $lsfgCppPath -Raw

Assert-Condition ($lsfgContent -match "lsfg_record_generation_profiled_r4a") "lsfg.cpp implements lsfg_record_generation_profiled_r4a"
Assert-Condition ($lsfgContent -match "deltaL2Bypass") "lsfg.cpp supports deltaL2Bypass"
# Verify Delta L2 bypass writes Q90..Q99 markers without dispatch
Assert-Condition ($lsfgContent -match "70\s*\+\s*2\s*\*\s*10\s*\+\s*p" -or $lsfgContent -match "90\s*\+\s*p") "lsfg.cpp emits Q90..Q99 bypass markers"

# 3. Inspect interposer for R4-A gate and summary
$interposerPath = "C:\Proyectos\amethyst_worktree_real_lsfg_r4a\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
if (-not (Test-Path $interposerPath)) {
    $interposerPath = "C:\Proyectos\amethyst_worktree_real_lsfg_r3_abi_corrected\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
}
$interposerContent = Get-Content $interposerPath -Raw

Assert-Condition ($interposerContent -match "AMETHYST_LSFG_R4A_DELTA_L2_BYPASS") "Interposer checks AMETHYST_LSFG_R4A_DELTA_L2_BYPASS"
Assert-Condition ($interposerContent -match "LSFG-REAL-R4A-SUMMARY") "Interposer logs LSFG-REAL-R4A-SUMMARY"
Assert-Condition ($interposerContent -match "executedDispatches") "Summary reports executedDispatches"
Assert-Condition ($interposerContent -match "bypassedDispatches") "Summary reports bypassedDispatches"
Assert-Condition ($interposerContent -match "deltaExecutedMean") "Summary reports deltaExecutedMean"
Assert-Condition ($interposerContent -match "deltaBypassMarkerMean") "Summary reports deltaBypassMarkerMean"

# 4. Verify no proprietary shader modifications
$repoDir = "C:\Proyectos\amethyst_worktree_real_lsfg_r4a"
if (-not (Test-Path $repoDir)) { $repoDir = "C:\Proyectos\amethyst" }
$dlls = Get-ChildItem -Path $repoDir -Recurse -Filter "Lossless.dll" -ErrorAction SilentlyContinue
Assert-Condition ($dlls.Count -eq 0) "No Lossless.dll found in repository"
$dxbcs = Get-ChildItem -Path $repoDir -Recurse -Filter "*.dxbc" -ErrorAction SilentlyContinue
Assert-Condition ($dxbcs.Count -eq 0) "No *.dxbc found in repository"
$spvs = Get-ChildItem -Path $repoDir -Recurse -Filter "res_*.spv" -ErrorAction SilentlyContinue
Assert-Condition ($spvs.Count -eq 0) "No res_*.spv found in repository"

Write-Host "=== R4-A CONTRACT TEST SUMMARY ===" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    Write-Host "FAILED with $($failures.Count) error(s):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "ALL R4-A CONTRACTS PASSED!" -ForegroundColor Green
    exit 0
}
