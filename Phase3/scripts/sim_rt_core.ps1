# System test of jrp_rt_core: one golden case streamed NREP times through the AXI-Stream port, every window checked.
# Usage: & .\sim_rt_core.ps1 -Case jrp_mixedparams_small [-K 2] [-NRep 3] [-Period 0] [-Offer 100] [-Depth 8192]
param(
  [Parameter(Mandatory)][string]$Case,
  [int]$MaxM = 6, [int]$K = 2, [int]$NRep = 3, [int]$Period = 0, [int]$Offer = 100, [int]$Depth = 8192
)
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$gold = Join-Path (Split-Path -Parent $p3) 'Phase1\golden'
$py = Join-Path (Split-Path -Parent $p3) 'Phase1\.venv\Scripts\python.exe'
$B = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$j = Get-Content "$gold\$Case.json" -Raw | ConvertFrom-Json
$dual = ($j.channels -eq 2)
$mx = $j.x.m; $tx = $j.x.tau
$my = if ($dual) { $j.y.m } else { 1 }; $ty = if ($dual) { $j.y.tau } else { 1 }
$e2x = $j.eps_x.eps2_hex; $e2y = if ($dual) { $j.eps_y.eps2_hex } else { 'FFFFFFFF' }
$n = $j.n_vectors; $ns = $j.N_samples
if ($mx -gt $MaxM -or ($dual -and $my -gt $MaxM)) { Write-Host "SKIP $Case (m > MAX_M=$MaxM)"; exit 0 }
if ($ns -gt $Depth) { Write-Host "SKIP $Case (N_samples $ns > ring depth $Depth)"; exit 0 }

& $py "$PSScriptRoot\gen_counters_hex.py" $Case | Out-Null
$cnt = ("$p3\build\counters\${Case}_counters.hex").Replace('\', '/')
$work = Join-Path $p3 "build\sim_rt_${Case}_k$K"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$rtl = Join-Path $p3 'rtl'; $rel = Join-Path $p3 'released\rtl'
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }

$files = @("$rel\distance_threshold_calculation.v", "$rel\axi_perf_mon.v", "$rtl\jrp_tdp_bram_fw.v",
  "$rtl\jrp_psr.v", "$rtl\jrp_vector_buffer.v", "$rtl\jrp_pair_gen.v", "$rtl\jrp_lane.v", "$rtl\jrp_scan_engine.v",
  "$rtl\jrp_rqa_extractor.v", "$rtl\jrp_rqa_extractor_axi.v", "$rtl\jrp_vector_buffer3.v", "$rtl\jrp_pair_gen_k2.v", "$rtl\jrp_scan_engine_k2.v", "$rtl\jrp_run_cell.v", "$rtl\jrp_hist_unit.v", "$rtl\jrp_rqa_extractor_k2.v", "$rtl\jrp_rqa_extractor_k2_axi.v", "$rtl\jrp_axi_regs.v", "$rtl\jrp_top.v", "$rtl\jrp_rt_ingest.v", "$rtl\jrp_axil_decode.v",
  "$rtl\jrp_rt_core.v", "$p3\tb\tb_rt_core.sv")
$list = ($files | ForEach-Object { "`"$_`"" }) -join ' '
Run 'xvlog.bat' "-sv $list" | Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_rt_core -s snap -L xpm -generic_top `"MAX_M=$MaxM`" -generic_top `"K=$K`" -generic_top `"DEPTH=$Depth`" -debug off" | Select-String 'ERROR' | ForEach-Object { $_.Line }
$pfx = ($gold + '\' + $Case).Replace('\', '/')
$kv = @("PFX=$pfx", "CNT=$cnt", "N=$n", "NS=$ns", "MX=$mx", "MY=$my", "TX=$tx", "TY=$ty", "E2X=$e2x", "E2Y=$e2y",
        "HAS_Y=$([int]$dual)", "NREP=$NRep", "PERIOD=$Period", "PV=$Offer")
$pa = ($kv | ForEach-Object { "-testplusarg `"$_`"" }) -join ' '
Run 'xsim.bat' "snap -runall $pa" | Select-String 'PASS|FAIL|ERROR|MISMATCH|got|TIMEOUT|FRAMES|dropped|OCC|latency|bin' | ForEach-Object { $_.Line }

