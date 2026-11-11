# Phase 3 task 0: out-of-context synthesis of the released single-channel modules.
# Part: XCZU4EV, 150 MHz target. Run from Phase3/build:
#   vivado -mode batch -source ../scripts/synth_released.tcl -tclargs <only-top-or-all>
# Outputs: reports/synth_<top>_utilization.rpt, reports/synth_<top>_timing.rpt, reports/synth_summary.csv
# Synthesis-only timing is a pre-placement estimate: it is not Fmax.

set here   [file normalize [file dirname [info script]]]
set root   [file normalize $here/..]
set rtl    $root/released/rtl
set rep    $root/reports
file mkdir $rep

set part   xczu4ev-sfvc784-1-e
set period 6.667

# top, generics (as instantiated by RPs_bruteforce where it overrides defaults)
set runs {
  {RPs_bruteforce                 {}}
  {vector_buffer                  {}}
  {phase_space_reconstruction     {MAX_TAU=16}}
  {distance_threshold_calculation {}}
  {compare_orchestrator           {}}
  {grid_index_gen                 {}}
  {RQA_extractor_nobitmap         {}}
  {RQA_extractor_axi              {}}
  {axi_lite_regs                  {}}
  {axi_perf_mon                   {}}
  {tdp_bram_fw                    {}}
}

set only "all"
if {[info exists ::argv] && [llength $::argv] > 0} { set only [lindex $::argv 0] }

set csv [open $rep/synth_summary.csv w]
puts $csv "top,generics,lut,lut_as_logic,lut_as_mem,ff,bram36,uram,dsp,wns_ns,status"

foreach r $runs {
  lassign $r top gen
  if {$only ne "all" && $only ne $top} { continue }
  puts "=== synthesising $top ($gen)"
  set args [list -top $top -part $part -mode out_of_context]
  foreach g $gen { lappend args -generic $g }
  set status ok
  if {[catch {
    read_verilog [glob $rtl/*.v]
    synth_design {*}$args
  } err]} {
    set status "FAILED: [string map {, ;} [string range $err 0 120]]"
    puts $csv "$top,\"$gen\",,,,,,,,,$status"
    flush $csv
    catch {close_design}
    continue
  }
  if {[llength [get_ports -quiet clk]] > 0} {
    create_clock -period $period -name clk [get_ports clk]
  }
  report_utilization -file $rep/synth_${top}_utilization.rpt
  report_timing_summary -file $rep/synth_${top}_timing.rpt -max_paths 3
  # pull numbers from the utilization report
  set fh [open $rep/synth_${top}_utilization.rpt]; set txt [read $fh]; close $fh
  proc grab {txt pat} {
    if {[regexp "\\|\\s*$pat\\s*\\|\\s*(\[0-9.\]+)\\s*\\|" $txt -> v]} { return $v }
    return ""
  }
  set lut   [grab $txt "CLB LUTs\\*?"]
  set lutl  [grab $txt "LUT as Logic"]
  set lutm  [grab $txt "LUT as Memory"]
  set ff    [grab $txt "CLB Registers"]
  set bram  [grab $txt "Block RAM Tile"]
  set uram  [grab $txt "URAM"]
  set dsp   [grab $txt "DSPs"]
  set wns ""
  catch { set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] }
  puts $csv "$top,\"$gen\",$lut,$lutl,$lutm,$ff,$bram,$uram,$dsp,$wns,$status"
  flush $csv
  close_design
}
close $csv
puts "done"
