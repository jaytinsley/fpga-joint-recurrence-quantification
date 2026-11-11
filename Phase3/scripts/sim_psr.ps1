# Embedding block check over a full-length sample file (exercises the history buffer wrap).
# Usage: .\sim_psr.ps1 -Samples bench_logistic_full_x.hex -Ns 4096 -M 5 -Tau 3 [-MaxM 6] [-MaxTau 16] [-Module released|jrp]
param(
  [Parameter(Mandatory)][string]$Samples,
  [Parameter(Mandatory)][int]$Ns,
  [int]$M = 5, [int]$Tau = 3, [int]$MaxM = 6, [int]$MaxTau = 16,
  [ValidateSet('released','jrp')][string]$Module = 'released'
)
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$gold = Join-Path (Split-Path -Parent $p3) 'Phase1\golden'
$B = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$work = Join-Path $p3 "build\sim_psr_$Module"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
function Run($bat, $argString) { cmd /c "`"$B\$bat`" $argString 2>&1" }
if ($Module -eq 'released') { $src = "$p3\released\rtl\phase_space_reconstruction.v"; $dut = 'phase_space_reconstruction' }
else { $src = "$p3\rtl\jrp_psr.v"; $dut = 'jrp_psr' }
Run 'xvlog.bat' "-sv -d `"PSR_DUT=$dut`" `"$src`" `"$p3\tb\tb_psr_check.sv`"" | Select-String 'ERROR' | ForEach-Object { $_.Line }
Run 'xelab.bat' "tb_psr_check -s snap -generic_top `"MAX_M=$MaxM`" -generic_top `"MAX_TAU=$MaxTau`" -debug off" | Select-String 'ERROR' | ForEach-Object { $_.Line }
$kv = @("SAMPLES=$(($gold + '\' + $Samples).Replace('\','/'))", "NS=$Ns", "M=$M", "TAU=$Tau")
$pa = ($kv | ForEach-Object { "-testplusarg `"$_`"" }) -join ' '
Run 'xsim.bat' "snap -runall $pa" | Select-String 'PASS|FAIL|ERROR|vector|comp|VECTOR' | ForEach-Object { $_.Line }
