# Rerun selected full-length (N = 4096) golden cases through jrp_top, one at a time (memory).
param([string[]]$Cases)
$rows = @()
$Cases = $Cases -split ","
foreach ($c in $Cases) {
  $out = & "$PSScriptRoot\sim_top.ps1" -Case $c 2>&1 | Where-Object { $_ -notmatch 'XPM_MEMORY' }
  $res = (($out | Where-Object { $_ -match '^(PASS|FAIL)' } | Select-Object -First 1) -split ' ')[0]
  $bad = ($out | Where-Object { $_ -match 'MISMATCH|hist bin' } | Select-Object -First 4) -join ' | '
  Write-Host ("{0,-26} {1} {2}" -f $c, $res, $bad)
}
