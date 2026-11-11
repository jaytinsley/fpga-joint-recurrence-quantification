# Run every golden case on the loaded board (PL loaded with build/jrp_board.bit, PS initialised).
# Only reads and writes registers of the loaded design. Cases with m > MAX_M (6) are skipped.
# Usage: & .\run_all_hw.ps1 [-Small] [-Full]   (default both)
param([switch]$Small, [switch]$Full, [switch]$Reverse)
if (-not $Small -and -not $Full) { $Small = $true; $Full = $true }
$p3 = Split-Path -Parent $PSScriptRoot
$gold = Join-Path (Split-Path -Parent $p3) 'Phase1\golden'
$py = Join-Path (Split-Path -Parent $p3) 'Phase1\.venv\Scripts\python.exe'
$viv = 'C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat'
$MAXM = 6
Set-Location (Join-Path $p3 'build')
$cases = Get-ChildItem $gold -Filter '*.json' | Where-Object { $_.Name -ne 'index.json' } | ForEach-Object { $_.BaseName } | Sort-Object -Descending:$Reverse
$rows = @()
foreach ($c in $cases) {
  $isFull = $c -match '_full$'
  if (($isFull -and -not $Full) -or (-not $isFull -and -not $Small)) { continue }
  $j = Get-Content "$gold\$c.json" -Raw | ConvertFrom-Json
  if (-not $j.expected_counters_full_scan) { continue }
  if ($j.x.m -gt $MAXM -or ($j.channels -eq 2 -and $j.y.m -gt $MAXM)) {
    Write-Host ("{0,-28} SKIP (m > MAX_M = {1} in this bitstream)" -f $c, $MAXM)
    $rows += [pscustomobject]@{ case = $c; result = 'SKIP'; detail = "m > $MAXM" }
    continue
  }
  & $py "$PSScriptRoot\gen_hw_case.py" $c | Out-Null
  $out = & cmd /c "`"$viv`" -mode batch -source ..\scripts\hw_axi_run.tcl -tclargs $c -nolog -nojournal 2>&1" | Where-Object { $_ -match '^HWRUN' }
  $res = ($out | Where-Object { $_ -match 'HWRUN: (PASS|FAIL)' } | Select-Object -First 1)
  $scan = ($out | Where-Object { $_ -match 'scan phase' } | Select-Object -First 1)
  $clk = ($out | Where-Object { $_ -match 'measured PL clock' } | Select-Object -First 1)
  $result = if ($res) { ($res -split ' ')[1] } else { 'ERROR' }
  Write-Host ("{0,-28} {1,-5} {2}" -f $c, $result, $scan)
  if ($result -ne 'PASS') { $out | Where-Object { $_ -match 'MISMATCH|bin |TIMEOUT|STATUS|wrong|no JTAG' } | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" } }
  $rows += [pscustomobject]@{ case = $c; result = $result; detail = "$scan | $clk" }
}
$rows | Export-Csv "$p3\reports\hw_results.csv" -NoTypeInformation
Write-Host ("`n{0} passed, {1} failed, {2} skipped" -f ($rows | Where-Object result -eq 'PASS').Count, ($rows | Where-Object { $_.result -ne 'PASS' -and $_.result -ne 'SKIP' }).Count, ($rows | Where-Object result -eq 'SKIP').Count)
