# v2b1b_real_lsfg_r4b_contract_test.ps1
# Contract test for REAL-LSFG R4-B Gamma L6 + Delta L2 Terminal Bypass Experiment

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

Write-Host "=== REAL-LSFG R4-B CONTRACT TEST ===" -ForegroundColor Cyan

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

# Check frozen R4-A API preserved
Assert-Condition ($headerContent -match "struct\s+LsfgR4AOptions\s*\{") "R4-A LsfgR4AOptions struct preserved"
Assert-Condition ($headerContent -match "lsfg_record_generation_profiled_r4a\s*\(") "R4-A lsfg_record_generation_profiled_r4a entry point preserved"

# Check new R4-B versioned API exists
Assert-Condition ($headerContent -match "struct\s+LsfgR4BOptions\s*\{[^}]*bool\s+gammaL6Bypass") "R4-B LsfgR4BOptions struct exists with gammaL6Bypass"
Assert-Condition ($headerContent -match "float\s+flowScale\s*=\s*1\.0f") "R4-B LsfgR4BOptions defaults flowScale to 1.0f"
Assert-Condition ($headerContent -match "lsfg_record_generation_profiled_r4b\s*\(") "R4-B lsfg_record_generation_profiled_r4b entry point declared"

# 2. Inspect lsfg.cpp for Gamma L6 & Delta L2 bypass logic and query preservation
$lsfgCppPath = "C:\Proyectos\LS-FG\lsfg-vk-android\framegen\v3.1_src\lsfg.cpp"
Assert-Condition (Test-Path $lsfgCppPath) "lsfg.cpp exists"
$lsfgContent = Get-Content $lsfgCppPath -Raw

Assert-Condition ($lsfgContent -match "lsfg_record_generation_profiled_r4b") "lsfg.cpp implements lsfg_record_generation_profiled_r4b"
Assert-Condition ($lsfgContent -match "gammaL6Bypass") "lsfg.cpp supports gammaL6Bypass"
Assert-Condition ($lsfgContent -match "deltaL2Bypass") "lsfg.cpp supports deltaL2Bypass"
# Verify Gamma L6 bypass writes Q65..Q69 markers without dispatch
Assert-Condition ($lsfgContent -match "35\s*\+\s*6\s*\*\s*5\s*\+\s*p" -or $lsfgContent -match "65\s*\+\s*p") "lsfg.cpp emits Q65..Q69 bypass markers"
# Verify Delta L2 bypass writes Q90..Q99 markers without dispatch
Assert-Condition ($lsfgContent -match "70\s*\+\s*2\s*\*\s*10\s*\+\s*p" -or $lsfgContent -match "90\s*\+\s*p") "lsfg.cpp emits Q90..Q99 bypass markers"

# 3. Inspect interposer for R4-B gate, coupling matrix enforcement, and summary
$interposerPath = "C:\Proyectos\amethyst_worktree_real_lsfg_r4b\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
if (-not (Test-Path $interposerPath)) {
    $interposerPath = "C:\Proyectos\amethyst_worktree_real_lsfg_r4a\app_pojavlauncher\src\main\jni\lsfg_vulkan_interposer.cpp"
}
$interposerContent = Get-Content $interposerPath -Raw

Assert-Condition ($interposerContent -match "AMETHYST_LSFG_R4B_GAMMA_L6_BYPASS") "Interposer checks AMETHYST_LSFG_R4B_GAMMA_L6_BYPASS"
Assert-Condition ($interposerContent -match "LSFG-REAL-R4B-SUMMARY") "Interposer logs LSFG-REAL-R4B-SUMMARY"
Assert-Condition ($interposerContent -match "flowScale\s*=\s*2\.0f") "Interposer sets flowScale = 2.0f when R4-B is active"
Assert-Condition ($interposerContent -match "r4bBypass\s*&&\s*!r4aBypass") "Interposer rejects/guards against R4-B without R4-A"
Assert-Condition ($interposerContent -match "gammaL6Bypassed") "Summary reports gammaL6Bypassed"
Assert-Condition ($interposerContent -match "gammaL6MarkerMean") "Summary reports gammaL6MarkerMean"
# Verify profiling pointer safety: r4bOptions.profiling assigned address-of &stageProfiling and NOT value copy
Assert-Condition ($interposerContent -match "r4bOptions\.profiling\s*=\s*(timingActiveForSlot\s*\?\s*)?&stageProfiling" -and -not ($interposerContent -match "r4bOptions\.profiling\s*=\s*stageProfiling;")) "Profiling pointer uses valid address-of &stageProfiling and not value copy"

# 4. Verify no proprietary shader modifications
$repoDir = "C:\Proyectos\amethyst_worktree_real_lsfg_r4b"
if (-not (Test-Path $repoDir)) { $repoDir = "C:\Proyectos\amethyst_worktree_real_lsfg_r4a" }
$dlls = Get-ChildItem -Path $repoDir -Recurse -Filter "Lossless.dll" -ErrorAction SilentlyContinue
Assert-Condition ($dlls.Count -eq 0) "No Lossless.dll found in repository"
$dxbcs = Get-ChildItem -Path $repoDir -Recurse -Filter "*.dxbc" -ErrorAction SilentlyContinue
Assert-Condition ($dxbcs.Count -eq 0) "No *.dxbc found in repository"
$spvs = Get-ChildItem -Path $repoDir -Recurse -Filter "res_*.spv" -ErrorAction SilentlyContinue
Assert-Condition ($spvs.Count -eq 0) "No res_*.spv found in repository"

Write-Host "=== R4-B CONTRACT TEST SUMMARY ===" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    Write-Host "FAILED with $($failures.Count) error(s):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "ALL R4-B CONTRACTS PASSED!" -ForegroundColor Green
    exit 0
}
