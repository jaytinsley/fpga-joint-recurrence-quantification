# Run sw/rt_null.elf on Cortex-A53 core 0 and print its log: one line per window
#   NULL: w hw_joint hw_x hw_y exp_joint exp_x exp_y status cycles      (status 0 ok, 1 mismatch, 2 timeout)
# Prerequisites: an m<=10 (or matching) bitstream loaded with hw_load.tcl, the OCM image build/rtcase/null_<name>.bin written
# at 0xFFFD0000 with hw_ocm_load.tcl. Run from Phase3/build:  xsdb ../scripts/hw_null_run.tcl
set here [file normalize [file dirname [info script]]]
set elf  [file normalize $here/../sw/rt_null.elf]
set LOG 0xFFFCF000
connect
targets -set -nocase -filter {name =~ "*PSU*"}
mwr 0xFFCA0038 0x1FF
mwr $LOG 0 4
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor -clear-registers
dow $elf
con
set t0 [clock seconds]
while {1} {
    after 300
    targets -set -nocase -filter {name =~ "*PSU*"}
    if {[lindex [mrd -value $LOG 1] 0] == 0x52544C47} break
    if {[clock seconds] - $t0 > 120} { puts "NULL: TIMEOUT stage [lindex [mrd -value [expr {$LOG + 4}] 1] 0]"; break }
}
set nwin [lindex [mrd -value [expr {$LOG + 8}] 1] 0]
puts "NULL: ID [format 0x%08X [lindex [mrd -value [expr {$LOG + 12}] 1] 0]] windows $nwin"
for {set w 0} {$w < $nwin} {incr w} {
    set v [mrd -value [expr {$LOG + 32 + 32 * $w}] 8]
    puts "NULL: $w [join $v { }]"
}
exit 0
