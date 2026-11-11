# L3 over every golden case that has counters in its JSON (small cases and the N = 4096 cases).
# Usage: & .\run_all_top.ps1 [-Small] [-Full]   (default: both)
param([switch]$Small, [switch]$Full, [int]$K = 1)
if (-not $Small -and -not $Full) { $Small = $true; $Full = $true }
$gold = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Phase1\golden'
$cases = Get-ChildItem $gold -Filter '*.json' | Where-Object { $_.Name -ne 'index.json' } |
  ForEach-Object { $_.BaseName } | Sort-Object
$rows = @()
foreach ($c in $cases) {
  $isFull = $c -match '_full$'
  if (($isFull -and -not $Full) -or (-not $isFull -and -not $Small)) { continue }
  $j = Get-Content "$gold\$c.json" -Raw | ConvertFrom-Json
  if (-not $j.expected_counters_full_scan) { Write-Host "no counters in $c.json, skipped"; continue }
  $maxm = if ($c -eq 'edge_max_embedding') { 10 } else { 6 }
  $fullhist = 1
  $out = & "$PSScriptRoot\sim_top.ps1" -Case $c -MaxM $maxm -FullHist $fullhist -K $K 2>&1 | Where-Object { $_ -notmatch 'XPM_MEMORY' }
  $line = ($out | Where-Object { $_ -match '^(PASS|FAIL|SKIP)' } | Select-Object -First 1)
  $cyc = ($out | Where-Object { $_ -match 'start to metrics' } | Select-Object -First 1)
  $res = if ($line) { ($line -split ' ')[0] } else { 'ERROR' }
  $rows += [pscustomobject]@{ case = $c; max_m = $maxm; result = $res; detail = $cyc }
  Write-Host ("{0,-28} MAX_M={1,-2} {2,-5} {3}" -f $c, $maxm, $res, $cyc)
}
$rows | Export-Csv "$PSScriptRoot\..\reports\sim_top_results.csv" -NoTypeInformation
