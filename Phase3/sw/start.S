/* Minimal AArch64 start-up for the A53 core 0, entered by the debugger at EL3 with the MMU and caches off. */
    .section .text.start, "ax"
    .global _start
_start:
    ldr     x0, =__stack_top
    mov     sp, x0
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:  bl      main
3:  wfe
    b       3b
