# Initialise the PS (clocks only, DDR disabled) and load the PL bitstream over JTAG. VOLATILE:
# nothing is written to QSPI, eMMC or SD; a power cycle returns the board to its previous state.
# Run from Phase3/build:  xsdb ../scripts/hw_load.tcl
# Requires boot mode JTAG (SW1 = 0000). Aborts if the boot pins are not JTAG.
set here [file normalize [file dirname [info script]]]
set xsa  [file normalize $here/../build/xsa]
if {[llength $argv] > 0} { set xsa [file normalize [lindex $argv 0]] }   ;# optional: another unpacked XSA directory
connect
targets -set -nocase -filter {name =~ "*PSU*"}
set por [expr {[mrd -value 0xFF5E0204] & 0xF}]
if {$por != 0} { puts [format "HW: boot pins are 0x%X, not JTAG: refusing to load" $por]; exit 1 }

# make the PS accessible over JTAG, then run the generated init (PLLs, clocks, PL reset, no DDR)
mwr 0xFFCA0038 0x1FF
source $xsa/psu_init.tcl
puts "HW: running psu_init"
psu_init
after 500
puts "HW: removing PS-PL isolation"
psu_ps_pl_isolation_removal
after 500
puts "HW: configuring the PL"
targets -set -nocase -filter {name =~ "*PL*" && name !~ "*PSU*"}
set bitfile [lindex [glob $xsa/*.bit] 0]
fpga -file $bitfile
targets -set -nocase -filter {name =~ "*PSU*"}
psu_ps_pl_reset_config
puts "HW: load done"
exit 0
