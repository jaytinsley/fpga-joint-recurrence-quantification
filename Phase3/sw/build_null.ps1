# Build the independence-baseline driver: sw/rt_null.elf from sw/null_main.c and the sw/null_tables.h that
# scripts/gen_null_set.py wrote last.  Usage: & .\build_null.ps1
$ErrorActionPreference = 'Stop'
$sw = $PSScriptRoot
$gcc = 'C:\AMDDesignTools\2026.1\Vitis\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-gcc.exe'
& $gcc -O2 -Wall -mgeneral-regs-only -mcpu=cortex-a53 -ffreestanding -nostdlib -fno-builtin -I $sw -T "$sw\link.ld" "$sw\start.S" "$sw\null_main.c" -o "$sw\rt_null.elf" "-Wl,--no-warn-rwx-segments"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
& ($gcc -replace 'gcc.exe$', 'size.exe') "$sw\rt_null.elf"
