# Counters + histograms for every golden case that has per-pair flags, with the derived extractor
# (expected: PASS everywhere) and with the released extractor (documents the lost histogram events).
$gold = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Phase1\golden'
$cases = Get-ChildItem $gold -Filter '*_flags.hex' | ForEach-Object { $_.Name -replace '_flags\.hex$', '' } | Sort-Object
$rows = @()
foreach ($c in $cases) {
  $maxm = if ($c -eq 'edge_max_embedding') { 10 } else { 6 }
  $res = @{}
  foreach ($mode in 'derived', 'released') {
    $a = @{ Case = $c; MaxM = $maxm }
    if ($mode -eq 'released') { $a.Released = $true }
    $out = & "$PSScriptRoot\sim_extract.ps1" @a 2>&1 | Where-Object { $_ -notmatch 'XPM_MEMORY' }
    $line = ($out | Where-Object { $_ -match '^(PASS|FAIL|SKIP)' } | Select-Object -First 1)
    $bad = ($out | Where-Object { $_ -match 'MISMATCH|hist bin' }).Count
    $res[$mode] = if ($line) { ($line -split ' ')[0] } else { 'ERROR' }
    $res["$mode`_bad"] = $bad
  }
  $rows += [pscustomobject]@{ case = $c; max_m = $maxm; derived = $res.derived; released = $res.released;
                              released_mismatch_lines = $res.released_bad }
  Write-Host ("{0,-28} derived={1,-5} released={2,-5} (released mismatches shown: {3})" -f $c, $res.derived, $res.released, $res.released_bad)
}
$rows | Export-Csv "$PSScriptRoot\..\reports\sim_extract_results.csv" -NoTypeInformation
