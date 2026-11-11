# Run the L2 scan-engine testbench over every golden case that has per-pair flags.
# MAX_M = 6 (decision D5); the m = 10 edge case runs with MAX_M = 10 (the parameter is generic).
$gold = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Phase1\golden'
$cases = Get-ChildItem $gold -Filter '*_flags.hex' | ForEach-Object { $_.Name -replace '_flags\.hex$', '' } | Sort-Object
$rows = @()
foreach ($c in $cases) {
  $maxm = if ($c -eq 'edge_max_embedding') { 10 } else { 6 }
  $out = & "$PSScriptRoot\sim_scan.ps1" -Case $c -MaxM $maxm 2>&1 | Where-Object { $_ -notmatch 'XPM_MEMORY' }
  $res = ($out | Where-Object { $_ -match '^(PASS|FAIL|SKIP)' } | Select-Object -First 1)
  if (-not $res) { $res = 'FAIL (no result): ' + (($out | Select-Object -First 3) -join ' | ') }
  $rows += [pscustomobject]@{ case = $c; max_m = $maxm; result = ($res -replace '^(PASS|FAIL|SKIP)\s+\S+', '$1') }
  Write-Host ("{0,-32} MAX_M={1,-2} {2}" -f $c, $maxm, $rows[-1].result)
}
# delayed start: tready held low for 100 cycles after the start pulse (extractor still clearing histograms)
$out = & "$PSScriptRoot\sim_scan.ps1" -Case jrp_mixedparams_small -Stall 100 2>&1 | Where-Object { $_ -notmatch 'XPM_MEMORY' }
Write-Host ("{0,-32} stall=100 {1}" -f 'jrp_mixedparams_small', (($out | Where-Object { $_ -match '^(PASS|FAIL)' } | Select-Object -First 1) -replace '^(PASS|FAIL)\s+\S+', '$1'))
$rows | Export-Csv "$PSScriptRoot\..\reports\sim_scan_results.csv" -NoTypeInformation
