/* Application in the low 56 KB of OCM; the run log sits at 0xFFFCF000; sample data from 0xFFFD0000 (192 KB). */
ENTRY(_start)
MEMORY
{
    OCM_APP (rwx) : ORIGIN = 0xFFFC0000, LENGTH = 0xE000
}
SECTIONS
{
    .text : { *(.text.start) *(.text*) } > OCM_APP
    .rodata : { . = ALIGN(8); *(.rodata*) } > OCM_APP
    .data : { . = ALIGN(8); *(.data*) } > OCM_APP
    .bss (NOLOAD) : { . = ALIGN(8); __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(8); __bss_end = .; } > OCM_APP
    __stack_top = 0xFFFCE000;
}
