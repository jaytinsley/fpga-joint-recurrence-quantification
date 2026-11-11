# Run one exported golden case (e.g. an insect pair from Phase1/scripts/export_insect_golden.py) on the loaded
# board and write reports/insect_<case>.md. The board must already be programmed (hw_load.tcl) and in JTAG mode.
# Usage: .\run_insect.ps1 -Case insect_pair01
param([Parameter(Mandatory)][string]$Case)
$ErrorActionPreference = 'Stop'
$p3 = Split-Path -Parent $PSScriptRoot
$py = Join-Path (Split-Path -Parent $p3) 'Phase1\.venv\Scripts\python.exe'
$viv = 'C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat'
& $py "$PSScriptRoot\gen_hw_case.py" $Case
Set-Location (Join-Path $p3 'build')
cmd /c "`"$viv`" -mode batch -source ..\scripts\hw_axi_run.tcl -tclargs $Case -nolog -nojournal 2>&1" | Where-Object { $_ -match '^HWRUN' }
& $py "$PSScriptRoot\insect_report.py" $Case
