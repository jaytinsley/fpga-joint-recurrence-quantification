# Run one golden case on the board through the JTAG-to-AXI master and compare with the expected counters.
# Prerequisite: the bitstream is loaded (scripts/hw_load.tcl) and python scripts/gen_hw_case.py <case> has run.
# Run from Phase3/build:  vivado -mode batch -source ../scripts/hw_axi_run.tcl -tclargs <case> [dry] [<clock_mhz>]
#   dry: parse the case file and print the plan, do not touch hardware.
# Writes build/hwresults/<case>.json. Only reads and writes registers of the loaded design.
set here  [file normalize [file dirname [info script]]]
set root  [file normalize $here/..]
set name  [lindex $::argv 0]
set dry   [expr {[lindex $::argv 1] eq "dry"}]
source $root/build/hwcase/$name.tcl

set CTRL 0x00000; set RQA 0x20000; set PERF 0x40000; set FEED 0x60000; set CLKC 0x80000
set HIST_K 8192

proc hx {v} { return [format %08X [expr {$v}]] }

proc wr_many {axi pairs} {
    set chunk 128
    set total [llength $pairs]
    for {set s 0} {$s < $total} {incr s $chunk} {
        set objs {}
        set e [expr {min($s + $chunk, $total) - 1}]
        for {set k $s} {$k <= $e} {incr k} {
            lassign [lindex $pairs $k] a d
            create_hw_axi_txn -force w$k $axi -type write -address [hx $a] -data [hx $d] -len 1
            lappend objs [get_hw_axi_txns w$k]
        }
        run_hw_axi -quiet $objs
        delete_hw_axi_txn $objs
    }
}

proc rd_many {axi addrs} {
    set chunk 128
    set total [llength $addrs]
    set res {}
    for {set s 0} {$s < $total} {incr s $chunk} {
        set objs {}
        set e [expr {min($s + $chunk, $total) - 1}]
        for {set k $s} {$k <= $e} {incr k} {
            create_hw_axi_txn -force r$k $axi -type read -address [hx [lindex $addrs $k]] -len 1
            lappend objs [get_hw_axi_txns r$k]
        }
        run_hw_axi -quiet $objs
        foreach o $objs { lappend res [expr {"0x[get_property DATA $o]"}] }
        delete_hw_axi_txn $objs
    }
    return $res
}
proc wr1 {axi a d} { wr_many $axi [list [list $a $d]] }
proc rd1 {axi a}   { return [lindex [rd_many $axi [list $a]] 0] }

puts "CASE $case(name): samples $case(ns), joint vectors $case(n), m=$case(mx)/$case(my), tau=$case(tx)/$case(ty)"
if {$dry} {
    puts "DRY: x words [llength $case(x)], y words [llength $case(y)], expected $case(expect)"
    puts "DRY: det hist entries [expr {[llength $case(det_hist)]/2}], lam hist entries [expr {[llength $case(lam_hist)]/2}]"
    exit 0
}

open_hw_manager
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices xczu5*] 0]
refresh_hw_device [current_hw_device]
set axis [get_hw_axis -quiet]
if {[llength $axis] == 0} { puts "HWRUN: no JTAG-AXI core found: is the bitstream loaded?"; exit 1 }
set axi [lindex $axis 0]
set errors 0

# ---- identification and the real clock frequency ----
set id [rd1 $axi [expr {$CTRL + 0x48}]]
puts [format "HWRUN: ID register 0x%08X (want 0x4A525031)" $id]
if {$id != 0x4A525031} { puts "HWRUN: wrong ID, aborting"; exit 1 }
set t0 [clock milliseconds]; set c0 [rd_many $axi [list [expr {$CLKC}] [expr {$CLKC + 4}]]]; set t1 [clock milliseconds]
after 3000
set t2 [clock milliseconds]; set c1 [rd_many $axi [list [expr {$CLKC}] [expr {$CLKC + 4}]]]; set t3 [clock milliseconds]
set cyc0 [expr {[lindex $c0 1] * 4294967296 + [lindex $c0 0]}]
set cyc1 [expr {[lindex $c1 1] * 4294967296 + [lindex $c1 0]}]
set dt [expr {(($t2 + $t3) - ($t0 + $t1)) / 2000.0}]
set fmhz [expr {($cyc1 - $cyc0) / $dt / 1e6}]
puts [format "HWRUN: measured PL clock %.2f MHz (%d cycles in %.3f s)" $fmhz [expr {$cyc1 - $cyc0}] $dt]

# ---- configure ----
set cfg [list \
    [list [expr {$CTRL + 0x008}] $case(ns)] [list [expr {$CTRL + 0x00C}] $case(mx)] [list [expr {$CTRL + 0x010}] $case(tx)] \
    [list [expr {$CTRL + 0x014}] $case(e2x)] [list [expr {$CTRL + 0x024}] $case(my)] [list [expr {$CTRL + 0x028}] $case(ty)] \
    [list [expr {$CTRL + 0x02C}] $case(e2y)] [list [expr {$CTRL + 0x018}] 2] [list [expr {$CTRL + 0x01C}] 2] \
    [list [expr {$CTRL + 0x034}] $case(base_x)] [list [expr {$CTRL + 0x038}] $case(base_y)] [list [expr {$CTRL + 0x03C}] $case(n)]]
wr_many $axi $cfg
set got [rd1 $axi [expr {$CTRL + 0x03C}]]
if {$got != $case(n)} { puts "HWRUN: N_JOINT readback $got, want $case(n)"; incr errors }

# ---- load the samples ----
puts "HWRUN: loading $case(ns) sample pairs"
set tl0 [clock milliseconds]
wr1 $axi [expr {$FEED + 0x00}] 2
set pairs {}
for {set i 0} {$i < $case(ns)} {incr i} {
    lappend pairs [list [expr {$FEED + 0x0C}] "0x[lindex $case(x) $i]"]
    lappend pairs [list [expr {$FEED + 0x10}] "0x[lindex $case(y) $i]"]
}
wr_many $axi $pairs
wr1 $axi [expr {$FEED + 0x08}] $case(ns)
set st [rd1 $axi [expr {$FEED + 0x04}]]
if {($st >> 16) != $case(ns)} { puts "HWRUN: feeder holds [expr {$st >> 16}] samples, want $case(ns)"; incr errors }
puts [format "HWRUN: load took %.1f s" [expr {([clock milliseconds] - $tl0) / 1000.0}]]

# ---- run the frame ----
wr1 $axi [expr {$PERF + 0x00}] 2
wr1 $axi [expr {$PERF + 0x00}] 1
wr1 $axi [expr {$CTRL + 0x00}] 1
wr1 $axi [expr {$FEED + 0x00}] 1
set done 0
for {set p 0} {$p < 600 && !$done} {incr p} {
    set s [rd1 $axi [expr {$CTRL + 0x04}]]
    if {$s & 0x8} { set done 1 } else { after 200 }
}
if {!$done} { puts "HWRUN: TIMEOUT waiting for metrics_valid"; incr errors }
if {($s >> 4) & 0x7} { puts [format "HWRUN: STATUS error bits set: 0x%X" [expr {($s >> 4) & 0x7}]]; incr errors }

# ---- hardware cycle counts ----
lassign [rd_many $axi [list [expr {$PERF+0x18}] [expr {$PERF+0x20}] [expr {$PERF+0x28}] [expr {$PERF+0x30}] [expr {$PERF+0x38}] [expr {$PERF+0x0C}]]] ts tl tp tc tsc total
set feedc [rd1 $axi [expr {$FEED + 0x14}]]
# T_START is latched by a separate host write, so (T_LOAD - T_START) and the total include JTAG latency of the host.
# Hardware numbers: the stream duration of the feeder, and the scan phase from scan start to metrics valid.
set hwframe [expr {$tsc - $tl}]
puts "HWRUN: hardware cycles: sample stream $feedc, scan start to last pair [expr {$tp-$tl}], to last flag [expr {$tc-$tl}], flags to metrics [expr {$tsc-$tc}], scan start to metrics valid $hwframe"
puts "HWRUN: (host-latency inclusive: start to scan start [expr {$tl-$ts}] cycles, start to metrics valid $total cycles)"
set pairsN [expr {$case(n) * $case(n)}]
puts [format "HWRUN: scan phase %.3f ms at the measured %.2f MHz (%.3f ms at 150 MHz); pairs alone %.3f ms (%d pairs)"     [expr {$hwframe / ($fmhz * 1e3)}] $fmhz [expr {$hwframe / 150e3}] [expr {$pairsN / ($fmhz * 1e3)}] $pairsN]

# ---- counters ----
set names {rr_count det_points det_lines l_max lam_points lam_lines v_max}
set offs  {0x008 0x010 0x018 0x01C 0x020 0x028 0x02C}
set vals {}
foreach o $offs { lappend vals [rd1 $axi [expr {$RQA + $o}]] }
for {set k 0} {$k < 7} {incr k} {
    if {[lindex $vals $k] != [lindex $case(expect) $k]} {
        puts "HWRUN: MISMATCH [lindex $names $k]: got [lindex $vals $k] want [lindex $case(expect) $k]"; incr errors
    }
}
set acc [rd1 $axi [expr {$RQA + 0x038}]]
if {$acc != $pairsN} { puts "HWRUN: MISMATCH cells_accepted: got $acc want $pairsN"; incr errors }

# ---- histograms: every bin up to max(l_max, v_max) + 1; higher bins are zero by construction ----
set top [expr {min([expr {max([lindex $case(expect) 3], [lindex $case(expect) 6])}] + 1, $HIST_K - 1)}]
array set expd $case(det_hist); array set expl $case(lam_hist)
foreach {which base arr} [list DET [expr {$RQA + 0x1000}] expd LAM [expr {$RQA + 0x1000 + 4*$HIST_K}] expl] {
    set addrs {}
    for {set b 0} {$b <= $top} {incr b} { lappend addrs [expr {$base + 4*$b}] }
    set got [rd_many $axi $addrs]
    set bad 0
    for {set b 0} {$b <= $top} {incr b} {
        upvar 0 $arr a
        set want [expr {[info exists a($b)] ? $a($b) : 0}]
        if {[lindex $got $b] != $want} { incr bad; if {$bad <= 5} { puts "HWRUN: $which hist bin $b: got [lindex $got $b] want $want" } }
    }
    if {$bad} { puts "HWRUN: $which histogram: $bad bad bins of [expr {$top+1}] read"; incr errors $bad }
}

set result [expr {$errors == 0 ? "PASS" : "FAIL"}]
puts "HWRUN: $result $case(name) ($errors errors)"
file mkdir $root/build/hwresults
set fh [open $root/build/hwresults/$case(name).json w]
puts $fh [format "{\"case\": \"%s\", \"result\": \"%s\", \"errors\": %d, \"clock_mhz\": %.3f, \"total_cycles\": %d, \"scan_cycles\": %d, \"pairs\": %d}" \
    $case(name) $result $errors $fmhz $total [expr {$tc - $tl}] $pairsN]
close $fh
close_hw_target
disconnect_hw_server
exit 0
