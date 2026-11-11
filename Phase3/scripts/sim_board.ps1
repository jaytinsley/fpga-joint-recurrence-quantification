# L3: jrp_board_core through its single AXI-Lite port (as the JTAG-to-AXI master will) for one golden case.
# Usage: & .\sim_top.ps1 -Case jrp_mixedparams_small [-MaxM 6] [-FullHist 1]
param(
  [Parameter(Mandatory)][string]$Case,
  [int]$MaxM = 6,
  [int]$FullHist = 1,
  [int]$K = 1
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

& $py "$PSScriptRoot\gen_counters_hex.py" $Case | Out-Null
$cnt = ("$p3\build\counters\${Case}_counters.hex").Replace('\', '/')
$work = Join-Path $p3 "build\sim_board_${Case}_k$K"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$rtl = Join-Path $p3 'rtl'; $rel = Join-Path $p3 'released\rtl'
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }

$files = @("$rel\distance_threshold_calculation.v", "$rel\axi_perf_mon.v", "$rtl\jrp_tdp_bram_fw.v",
  "$rtl\jrp_psr.v", "$rtl\jrp_vector_buffer.v", "$rtl\jrp_pair_gen.v", "$rtl\jrp_lane.v", "$rtl\jrp_scan_engine.v",
  "$rtl\jrp_rqa_extractor.v", "$rtl\jrp_rqa_extractor_axi.v", "$rtl\jrp_vector_buffer3.v", "$rtl\jrp_pair_gen_k2.v", "$rtl\jrp_scan_engine_k2.v", "$rtl\jrp_run_cell.v", "$rtl\jrp_hist_unit.v", "$rtl\jrp_rqa_extractor_k2.v", "$rtl\jrp_rqa_extractor_k2_axi.v", "$rtl\jrp_axi_regs.v", "$rtl\jrp_top.v", "$rtl\jrp_sample_feeder.v", "$rtl\jrp_axil_decode.v",
  "$rtl\jrp_board_core.v", "$p3\tb\tb_board_core.sv")
$list = ($files | ForEach-Object { "`"$_`"" }) -join ' '
Run 'xvlog.bat' "-sv $list" | Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_board_core -s snap -L xpm -generic_top `"MAX_M=$MaxM`" -generic_top `"K=$K`" -debug off" | Select-String 'ERROR' | ForEach-Object { $_.Line }
$pfx = ($gold + '\' + $Case).Replace('\', '/')
$kv = @("PFX=$pfx", "CNT=$cnt", "N=$n", "NS=$ns", "MX=$mx", "MY=$my", "TX=$tx", "TY=$ty", "E2X=$e2x", "E2Y=$e2y",
        "HAS_Y=$([int]$dual)", "FULLHIST=$FullHist")
$pa = ($kv | ForEach-Object { "-testplusarg `"$_`"" }) -join ' '
Run 'xsim.bat' "snap -runall $pa" |
  Select-String 'PASS|FAIL|ERROR|MISMATCH|hist bin|TIMEOUT|STATUS|feeder|clock|stream|completion|perf|scan duration' | ForEach-Object { $_.Line }
