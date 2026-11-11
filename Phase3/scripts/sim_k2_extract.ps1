# K = 2 extractor against random recurrence matrices (many frames in one run).
# Usage: .\sim_k2_extract.ps1 [-Gaps]   (run ..\scripts\gen_k2_random.py first)
param([switch]$Gaps, [string]$Dir = '', [switch]$Dbg)
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$B = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$rtl = Join-Path $p3 'rtl'
$work = Join-Path $p3 'build\sim_k2_extract'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }
Run 'xvlog.bat' "-sv `"$rtl\jrp_tdp_bram_fw.v`" `"$rtl\jrp_run_cell.v`" `"$rtl\jrp_hist_unit.v`" `"$rtl\jrp_rqa_extractor_k2.v`" `"$rtl\jrp_rqa_extractor_k2_axi.v`" `"$p3\tb\tb_k2_extract.sv`"" |
  Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_k2_extract -s snap -L xpm -debug off" | Select-String 'ERROR' | ForEach-Object { $_.Line }
$dir = ("$p3\build\k2rand").Replace('\', '/')
$pa = "-testplusarg `"DIR=$dir`" -testplusarg `"GAPS=$([int]$Gaps.IsPresent)`" -testplusarg `"DBG=$([int]$Dbg.IsPresent)`""
Run 'xsim.bat' "snap -runall $pa" | Select-String 'PASS|FAIL|ERROR|MISMATCH|TIMEOUT|cases |LAM ev|DET ev|sweep' | ForEach-Object { $_.Line }
