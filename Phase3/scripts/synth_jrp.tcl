# Out-of-context synthesis of the new design (XCZU4EV, 150 MHz target).
# Run from Phase3/build:  vivado -mode batch -source ../scripts/synth_jrp.tcl -tclargs <top> <MAX_M> <tag>
# Reports go to Phase3/reports/synth_<tag>_*.rpt. Synthesis timing is a pre-placement estimate.
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/..]
set top  [lindex $::argv 0]; if {$top eq ""} { set top jrp_top }
set mm   [lindex $::argv 1]; if {$mm eq ""}  { set mm 6 }
set tag  [lindex $::argv 2]; if {$tag eq ""} { set tag ${top}_m$mm }
set rep  $root/reports
file mkdir $rep

read_verilog [glob $root/released/rtl/distance_threshold_calculation.v $root/released/rtl/axi_perf_mon.v \
                   $root/released/rtl/tdp_bram_fw.v]
read_verilog [glob $root/rtl/*.v]
set gen [list -generic MAX_M=$mm]
if {$top ne "jrp_top"} { set gen {} }
synth_design -top $top -part xczu4ev-sfvc784-1-e -mode out_of_context {*}$gen
if {[llength [get_ports -quiet clk]] > 0} { create_clock -period 6.667 -name clk [get_ports clk] }
report_utilization -file $rep/synth_${tag}_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file $rep/synth_${tag}_hier.rpt
report_timing_summary -file $rep/synth_${tag}_timing.rpt -max_paths 5
puts "synth done: $tag"
