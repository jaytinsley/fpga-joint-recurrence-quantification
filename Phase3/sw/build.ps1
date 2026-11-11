# Build the bare-metal real-time driver (no BSP).  Usage: & .\build.ps1 [-Case rt_stream_demo] [-Soak]
#   default: sw/rt_app.elf (rate sweep, 7 rates, 6 windows each)   -Soak: sw/rt_soak.elf (steady-state test, hundreds of windows per rate)
param([string]$Case = 'rt_stream_demo', [switch]$Soak, [switch]$Quick)
$ErrorActionPreference = 'Stop'
$sw = $PSScriptRoot
$p3 = Split-Path -Parent $sw
$py = Join-Path (Split-Path -Parent $p3) 'Phase1\.venv\Scripts\python.exe'
$gcc = 'C:\AMDDesignTools\2026.1\Vitis\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-gcc.exe'
& $py "$p3\scripts\gen_sw_header.py" $Case
$elf = if ($Quick) { 'rt_soakq.elf' } elseif ($Soak) { 'rt_soak.elf' } else { 'rt_app.elf' }
$def = if ($Quick) { '-DSOAK -DSOAK_QUICK' } elseif ($Soak) { '-DSOAK' } else { '-DNOSOAK' }
& $gcc $def -O2 -Wall -Wno-unused-function -mgeneral-regs-only -mcpu=cortex-a53 -ffreestanding -nostdlib -fno-builtin -I $sw -T "$sw\link.ld" "$sw\start.S" "$sw\main.c" -o "$sw\$elf" "-Wl,--no-warn-rwx-segments"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
& ($gcc -replace 'gcc.exe$', 'size.exe') "$sw\$elf"
