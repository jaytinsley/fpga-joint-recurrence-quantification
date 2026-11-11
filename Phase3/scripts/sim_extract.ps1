# Run the scan engine + released RQA extractor testbench for one golden case; compares the integer
# counters and histograms read over AXI-Lite with the Phase 1 expected counters.
# Usage: .\sim_extract.ps1 -Case jrp_mixedparams_small [-MaxM 6]
param(
  [Parameter(Mandatory)][string]$Case,
  [int]$MaxM = 6,
  [switch]$Released   # use the released extractor instead of the derived one
)
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$gold = Join-Path (Split-Path -Parent $p3) 'Phase1\golden'
$py = Join-Path (Split-Path -Parent $p3) 'Phase1\.venv\Scripts\python.exe'
$B = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$j = Get-Content "$gold\$Case.json" -Raw | ConvertFrom-Json
$dual = ($j.channels -eq 2)
$mx = $j.x.m; $my = if ($dual) { $j.y.m } else { 1 }
$e2x = $j.eps_x.eps2_hex; $e2y = if ($dual) { $j.eps_y.eps2_hex } else { 'FFFFFFFF' }
$n = $j.n_vectors
if ($mx -gt $MaxM -or ($dual -and $my -gt $MaxM)) { Write-Host "SKIP $Case (m > MAX_M=$MaxM)"; exit 0 }

& $py "$PSScriptRoot\gen_counters_hex.py" $Case | Out-Null
$cnt = ("$p3\build\counters\${Case}_counters.hex").Replace('\', '/')

$work = Join-Path $p3 "build\sim_extract_$Case"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$rtl = Join-Path $p3 'rtl'; $rel = Join-Path $p3 'released\rtl'
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }

if ($Released) {
  $extractor = "-d RELEASED_EXTRACTOR `"$rel\RQA_extractor_nobitmap.v`" `"$rel\RQA_extractor_axi.v`""
} else {
  $extractor = "`"$rtl\jrp_rqa_extractor.v`" `"$rtl\jrp_rqa_extractor_axi.v`""
}
Run 'xvlog.bat' "-sv `"$rel\distance_threshold_calculation.v`" `"$rtl\jrp_vector_buffer.v`" `"$rtl\jrp_pair_gen.v`" `"$rtl\jrp_lane.v`" `"$rtl\jrp_scan_engine.v`" `"$rel\tdp_bram_fw.v`" $extractor `"$p3\tb\tb_jrp_extract.sv`"" |
  Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_jrp_extract -s snap -L xpm -generic_top `"MAX_M=$MaxM`" -debug off" |
  Select-String 'ERROR' | ForEach-Object { $_.Line }
$pfx = ($gold + '\' + $Case).Replace('\', '/')
$kv = @("PFX=$pfx", "CNT=$cnt", "N=$n", "MX=$mx", "MY=$my", "E2X=$e2x", "E2Y=$e2y", "HAS_Y=$([int]$dual)")
$pa = ($kv | ForEach-Object { "-testplusarg `"$_`"" }) -join ' '
Run 'xsim.bat' "snap -runall $pa" |
  Select-String 'PASS|FAIL|ERROR|MISMATCH|hist bin|frame took|TIMEOUT|lost|align|overflow' | ForEach-Object { $_.Line }
