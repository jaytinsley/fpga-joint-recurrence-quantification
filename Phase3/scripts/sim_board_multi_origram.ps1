# Several golden cases back to back on one instance of jrp_board_core (reset once), like the board.
# Usage: & .\sim_board_multi.ps1 -Cases a,b,c [-Tag name]
param([Parameter(Mandatory)][string]$Cases, [string]$Tag = 'multi', [int]$MaxM = 6)
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$gold = Join-Path (Split-Path -Parent $p3) 'Phase1\golden'
$py = Join-Path (Split-Path -Parent $p3) 'Phase1\.venv\Scripts\python.exe'
$B = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$list = $Cases -split ','
& $py "$PSScriptRoot\gen_counters_hex.py" @list | Out-Null
$lines = @()
foreach ($c in $list) {
  $j = Get-Content "$gold\$c.json" -Raw | ConvertFrom-Json
  $dual = ($j.channels -eq 2)
  $my = if ($dual) { $j.y.m } else { 1 }; $ty = if ($dual) { $j.y.tau } else { 1 }
  $e2y = if ($dual) { $j.eps_y.eps2_hex } else { 'FFFFFFFF' }
  $pfx = ("$gold\$c").Replace('\', '/'); $cnt = ("$p3\build\counters\${c}_counters.hex").Replace('\', '/')
  $lines += "$pfx $cnt $($j.n_vectors) $($j.N_samples) $($j.x.m) $my $($j.x.tau) $ty $($j.eps_x.eps2_hex) $e2y $([int]$dual)"
}
$work = Join-Path $p3 "build\sim_$Tag"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$plan = Join-Path $work 'plan.txt'
Set-Content $plan $lines -Encoding ascii
$rtl = Join-Path $p3 'rtl'; $rel = Join-Path $p3 'released\rtl'
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }
$files = @("$rel\distance_threshold_calculation.v", "$rel\axi_perf_mon.v", "$rel\tdp_bram_fw.v",
  "$rtl\jrp_psr.v", "$rtl\jrp_vector_buffer.v", "$rtl\jrp_pair_gen.v", "$rtl\jrp_lane.v", "$rtl\jrp_scan_engine.v",
  "$p3\build\origram\jrp_rqa_extractor.v", "$rtl\jrp_rqa_extractor_axi.v", "$rtl\jrp_axi_regs.v", "$rtl\jrp_top.v",
  "$rtl\jrp_sample_feeder.v", "$rtl\jrp_axil_decode.v", "$rtl\jrp_board_core.v", "$p3\tb\tb_board_multi.sv")
$fl = ($files | ForEach-Object { "`"$_`"" }) -join ' '
Run 'xvlog.bat' "-sv $fl" | Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_board_multi -s snap -L xpm -generic_top `"MAX_M=$MaxM`" -debug off" | Select-String 'ERROR' | ForEach-Object { $_.Line }
$dbg = if ($env:JRP_DEBUG) { ' -testplusarg "DEBUG=1"' } else { '' }
Run 'xsim.bat' "snap -runall -testplusarg `"PLAN=$($plan.Replace('\','/'))`"$dbg" | Select-String 'PASS|FAIL|ALLPASS|SOMEFAIL|got|TIMEOUT|ERROR|frame|col ' | ForEach-Object { $_.Line }
