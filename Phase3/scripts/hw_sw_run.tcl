# Run the bare-metal driver (sw/rt_app.elf) on Cortex-A53 core 0 and print its log.
# Prerequisites: build/jrp_rt_board.xsa (with the PS master port) unpacked to build/xsa_rt and loaded with hw_load.tcl,
# the sample image in OCM at 0xFFFD0000 (hw_ocm_load.tcl build/rtcase/<case>.bin 0xFFFD0000).
# Run from Phase3/build:  xsdb ../scripts/hw_sw_run.tcl
set here [file normalize [file dirname [info script]]]
set elfname [expr {[llength $argv] > 0 ? [lindex $argv 0] : "rt_app.elf"}]   ;# rt_soak.elf for the steady-state test
set maxwait [expr {[llength $argv] > 1 ? [lindex $argv 1] : 240}]
set elf  [file normalize $here/../sw/$elfname]
set LOG 0xFFFCF000
connect
targets -set -nocase -filter {name =~ "*PSU*"}
mwr 0xFFCA0038 0x1FF
mwr $LOG 0 4
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor -clear-registers
dow $elf
puts "SW: running"
con
set t0 [clock seconds]
while {1} {
    after 500
    targets -set -nocase -filter {name =~ "*PSU*"}
    set magic [lindex [mrd -value $LOG 1] 0]
    set stage [lindex [mrd -value [expr {$LOG + 4}] 1] 0]
    if {$magic == 0x52544C47} break
    if {[clock seconds] - $t0 > $maxwait} { puts "SW: TIMEOUT, stage $stage"; break }
}
set nruns [lindex [mrd -value [expr {$LOG + 8}] 1] 0]
set id [lindex [mrd -value [expr {$LOG + 12}] 1] 0]
puts [format "SW: ID 0x%08X, %d runs, stage 0x%X" $id $nruns $stage]
puts "SW: run period frames dropped gapfr occmax windows checked mism lat_max proc_max dma_sr rt_sr duration drop seq(hex nibbles, 1-based window id) lat_ack_max first_mism target transfers seq(first 8 window ids, decimal of hex nibbles) occ_after_flush flush_occ0(+topped<<31) flush_junk_windows dma_sr_after_reset(+exit<<16)"
for {set r 0} {$r < $nruns} {incr r} {
    set w [mrd -value [expr {$LOG + 32 + 96 * $r}] 24]
    puts "SW: $r $w"
}
exit 0
