# Out-of-context implementation (synthesis + place + route) of jrp_top on the XCZU4EV.
# Run from Phase3/build:  vivado -mode batch -source ../scripts/impl_jrp.tcl -tclargs <MAX_M> <period_ns> <tag> [<part> [<K>]]
# The period only constrains the tools; Fmax is estimated as 1 / (period - WNS) after routing.
# OOC implementation has no I/O timing, so this is the fabric-internal result only.
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/..]
set mm     [lindex $::argv 0]; if {$mm eq ""}     { set mm 6 }
set period [lindex $::argv 1]; if {$period eq ""} { set period 6.667 }
set tag    [lindex $::argv 2]; if {$tag eq ""}    { set tag impl_m${mm}_${period}ns }
set part   [lindex $::argv 3]; if {$part eq ""}   { set part xczu4ev-sfvc784-1-e }
set kk     [lindex $::argv 4]; if {$kk eq ""}     { set kk 1 }
set rep $root/reports
file mkdir $rep

read_verilog [glob $root/released/rtl/distance_threshold_calculation.v $root/released/rtl/axi_perf_mon.v \
                   $root/released/rtl/tdp_bram_fw.v]
read_verilog [glob $root/rtl/*.v]
synth_design -top jrp_top -part $part -mode out_of_context -generic MAX_M=$mm -generic K=$kk
create_clock -period $period -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $rep/${tag}_utilization.rpt
report_timing_summary -file $rep/${tag}_timing.rpt -max_paths 10
report_route_status -file $rep/${tag}_route.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]]
set fmax [expr {1000.0 / ($period - $wns)}]
set fh [open $rep/${tag}_summary.txt w]
puts $fh "MAX_M=$mm K=$kk period_ns=$period WNS_ns=$wns Fmax_estimate_MHz=$fmax"
close $fh
puts "impl done: period=$period wns=$wns fmax=$fmax MHz"
