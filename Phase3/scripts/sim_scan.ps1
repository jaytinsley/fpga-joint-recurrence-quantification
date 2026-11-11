# Run the L2 scan-engine testbench for one golden case.
# Usage: .\sim_scan.ps1 -Case jrp_mixedparams_small [-MaxM 6] [-Stall 0]
# Reads the case parameters from the Phase 1 golden JSON, so nothing is typed by hand.
param(
  [Parameter(Mandatory)][string]$Case,
  [int]$MaxM = 6,
  [int]$Stall = 0
)
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$gold = Join-Path (Split-Path -Parent $p3) 'Phase1\golden'
$B = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$j = Get-Content "$gold\$Case.json" -Raw | ConvertFrom-Json
$dual = ($j.channels -eq 2)
$mx = $j.x.m; $my = if ($dual) { $j.y.m } else { 1 }
$e2x = $j.eps_x.eps2_hex; $e2y = if ($dual) { $j.eps_y.eps2_hex } else { 'FFFFFFFF' }
$n = $j.n_vectors
if ($mx -gt $MaxM -or ($dual -and $my -gt $MaxM)) { Write-Host "SKIP $Case (m > MAX_M=$MaxM)"; exit 0 }

$work = Join-Path $p3 "build\sim_scan_$Case"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$rtl = Join-Path $p3 'rtl'; $rel = Join-Path $p3 'released\rtl'

# cmd /c keeps arguments containing '=' and ':' intact (PowerShell splits them for .bat files)
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }

Run 'xvlog.bat' "-sv `"$rel\distance_threshold_calculation.v`" `"$rtl\jrp_vector_buffer.v`" `"$rtl\jrp_pair_gen.v`" `"$rtl\jrp_lane.v`" `"$rtl\jrp_scan_engine.v`" `"$p3\tb\tb_jrp_scan_engine.sv`"" |
  Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_jrp_scan_engine -s snap -L xpm -generic_top `"MAX_M=$MaxM`" -debug off" |
  Select-String 'ERROR' | ForEach-Object { $_.Line }
$pfx = ($gold + '\' + $Case).Replace('\', '/')
$kv = @("PFX=$pfx", "N=$n", "MX=$mx", "MY=$my", "E2X=$e2x", "E2Y=$e2y", "HAS_Y=$([int]$dual)", "STALL=$Stall")
$pa = ($kv | ForEach-Object { "-testplusarg `"$_`"" }) -join ' '
Run 'xsim.bat' "snap -runall $pa" |
  Select-String 'PASS|FAIL|ERROR|first beat|ORDER|FLAG|BEAT|THROUGHPUT|lost|align|completion' | ForEach-Object { $_.Line }
