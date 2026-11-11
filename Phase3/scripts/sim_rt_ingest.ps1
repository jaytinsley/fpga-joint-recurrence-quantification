# Unit test of jrp_rt_ingest. Usage: & .\sim_rt_ingest.ps1 -TestArgs 'NRAW=64','HOP=0','PERIOD=0','SCAN=500','TOTAL=1600','PV=30','DROP=0'
param([string[]]$TestArgs = @())
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$B = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$work = Join-Path $p3 'build\sim_rt_ingest'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }
Run 'xvlog.bat' "-sv `"$p3\rtl\jrp_rt_ingest.v`" `"$p3\tb\tb_rt_ingest.sv`"" | Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_rt_ingest -s snap -debug off" | Select-String 'ERROR' | ForEach-Object { $_.Line }
$pa = ($TestArgs | ForEach-Object { "-testplusarg `"$_`"" }) -join ' '
Run 'xsim.bat' "snap -runall $pa" | Select-String 'PASS|FAIL|ERROR|mismatch|frame|OCC|dropped|gap|TIMEOUT|FRAMES|tlast|overrun|!=|acks' | ForEach-Object { $_.Line }
