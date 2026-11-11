# READ-ONLY: report the boot-mode pins of the Zynq UltraScale+ on the connected board.
# Run: xsdb hw_bootmode.tcl   (C:\AMDDesignTools\2026.1\Vitis\bin\xsdb.bat)
# Reads CRL_APB BOOT_MODE_POR (0xFF5E0204, read-only, pin state at power-on reset) and
# BOOT_MODE_USER (0xFF5E0200). Boot mode 0x0 = JTAG. Writes nothing.
connect
puts "HW: targets:"
puts [targets]
if {[catch {targets -set -nocase -filter {name =~ "*PSU*"}} err]} {
    puts "HW: could not select the PSU target: $err"
    exit 0
}
if {[catch {
    set por  [mrd -value 0xFF5E0204]
    set user [mrd -value 0xFF5E0200]
    puts [format "HW: BOOT_MODE_POR  = 0x%08X  (pins: 0x%X)" $por  [expr {$por  & 0xF}]]
    puts [format "HW: BOOT_MODE_USER = 0x%08X  (mode: 0x%X)" $user [expr {$user & 0xF}]]
    if {($por & 0xF) == 0} { puts "HW: boot pins say JTAG (0000)" } else { puts "HW: boot pins are NOT JTAG" }
} err]} {
    puts "HW: register read failed: $err"
}
exit 0
