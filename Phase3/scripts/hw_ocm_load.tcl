# Write a sample file into PS on-chip memory (OCM) over JTAG, read a sample back, and optionally read OCM through
# the DMA path later. Volatile: OCM contents are lost at power-off.
# Run from Phase3/build:  xsdb ../scripts/hw_ocm_load.tcl <file.bin>
# Prerequisite: scripts/hw_load.tcl has run (PS initialised, debug access enabled).
set bin [lindex $argv 0]
set base [expr {[llength $argv] > 1 ? [lindex $argv 1] : 0xFFFC0000}]   ;# the bare-metal app uses 0xFFFD0000
set size [file size $bin]
set words [expr {($size + 3) / 4}]
connect
targets -set -nocase -filter {name =~ "*PSU*"}
mwr 0xFFCA0038 0x1FF
puts [format "OCM: writing %d bytes to 0x%X" $size $base]
mwr -bin -file $bin $base $words
set first [mrd -value $base 2]
set lastaddr [expr {$base + 4 * ($words - 2)}]
set last [mrd -value $lastaddr 2]
puts [format "OCM: first words %s, last words %s" $first $last]
puts "OCM: done"
exit 0
