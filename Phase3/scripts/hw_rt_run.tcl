# Real-time path on the board: AXI-DMA streams NREP windows of one golden case from PS on-chip memory (OCM) into
# jrp_rt_core; the ring FIFO and the frame sequencer start every window; each result is read and compared with the
# golden counters and histograms, then acknowledged. No START write, no sample feeder.
# Prerequisites: build/jrp_rt_board.xsa unpacked to build/xsa_rt and loaded (scripts/hw_load.tcl <dir>), samples in OCM
# (python gen_rt_case.py <case> --nrep N; xsdb hw_ocm_load.tcl build/rtcase/<case>.bin).
# Run from Phase3/build:  vivado -mode batch -source ../scripts/hw_rt_run.tcl -tclargs <case> <nrep> [<period>] [<drop>]
#   period: pacer, clocks per sample (0 = off, DMA at full speed, backpressure); drop: 1 = drop mode instead of backpressure
set here  [file normalize [file dirname [info script]]]
set root  [file normalize $here/..]
set name  [lindex $::argv 0]
set nrep  [lindex $::argv 1]
set period [expr {[lindex $::argv 2] eq "" ? 0 : [lindex $::argv 2]}]
set drop   [expr {[lindex $::argv 3] eq "" ? 0 : [lindex $::argv 3]}]
source $root/build/hwcase/$name.tcl

set CTRL 0x00000; set RQA 0x20000; set PERF 0x40000; set RT 0x60000; set CLKC 0x80000; set DMA 0x100000
set HIST_K 8192
set OCM 0xFFFC0000

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

puts "CASE $case(name): samples $case(ns), joint vectors $case(n), $nrep windows, pacer period $period, drop mode $drop"
open_hw_manager
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices xczu5*] 0]
refresh_hw_device [current_hw_device]
set axis [get_hw_axis -quiet]
if {[llength $axis] == 0} { puts "RTRUN: no JTAG-AXI core found: is the bitstream loaded?"; exit 1 }
set axi [lindex $axis 0]
set errors 0

set id [rd1 $axi [expr {$CTRL + 0x48}]]
puts [format "RTRUN: ID register 0x%08X (want 0x4A525031)" $id]
if {$id != 0x4A525031} { puts "RTRUN: wrong ID, aborting"; exit 1 }
set t0 [clock milliseconds]; set c0 [rd_many $axi [list [expr {$CLKC}] [expr {$CLKC + 4}]]]; set t1 [clock milliseconds]
after 2000
set t2 [clock milliseconds]; set c1 [rd_many $axi [list [expr {$CLKC}] [expr {$CLKC + 4}]]]; set t3 [clock milliseconds]
set cyc0 [expr {[lindex $c0 1] * 4294967296 + [lindex $c0 0]}]
set cyc1 [expr {[lindex $c1 1] * 4294967296 + [lindex $c1 0]}]
set dt [expr {(($t2 + $t3) - ($t0 + $t1)) / 2000.0}]
set fmhz [expr {($cyc1 - $cyc0) / $dt / 1e6}]
puts [format "RTRUN: measured PL clock %.2f MHz" $fmhz]

# ---- configure the core, disable the sequencer, clear counters ----
wr1 $axi [expr {$RT + 0x00}] 0x2
set cfg [list \
    [list [expr {$CTRL + 0x008}] $case(ns)] [list [expr {$CTRL + 0x00C}] $case(mx)] [list [expr {$CTRL + 0x010}] $case(tx)] \
    [list [expr {$CTRL + 0x014}] $case(e2x)] [list [expr {$CTRL + 0x024}] $case(my)] [list [expr {$CTRL + 0x028}] $case(ty)] \
    [list [expr {$CTRL + 0x02C}] $case(e2y)] [list [expr {$CTRL + 0x018}] 2] [list [expr {$CTRL + 0x01C}] 2] \
    [list [expr {$CTRL + 0x034}] $case(base_x)] [list [expr {$CTRL + 0x038}] $case(base_y)] [list [expr {$CTRL + 0x03C}] $case(n)] \
    [list [expr {$RT + 0x08}] 0] [list [expr {$RT + 0x0C}] $period]]
wr_many $axi $cfg
set got [rd1 $axi [expr {$CTRL + 0x03C}]]
if {$got != $case(n)} { puts "RTRUN: N_JOINT readback $got, want $case(n)"; incr errors }

# ---- DMA: reset, then check the registers respond ----
wr1 $axi [expr {$DMA + 0x00}] 0x4
after 100
set dmasr [rd1 $axi [expr {$DMA + 0x04}]]
puts [format "RTRUN: DMA status after reset 0x%08X (halted bit expected)" $dmasr]

# ---- enable the sequencer, start the DMA ----
set ctrl_en [expr {1 | ($drop ? 8 : 0)}]
wr1 $axi [expr {$RT + 0x00}] $ctrl_en
set bytes [expr {$nrep * $case(ns) * 8}]
wr1 $axi [expr {$DMA + 0x00}] 0x1
wr1 $axi [expr {$DMA + 0x18}] $OCM
wr1 $axi [expr {$DMA + 0x1C}] 0
set tstart [clock milliseconds]
wr1 $axi [expr {$DMA + 0x28}] $bytes
puts "RTRUN: DMA started, $bytes bytes from OCM"

set names {rr_count det_points det_lines l_max lam_points lam_lines v_max}
set offs  {0x008 0x010 0x018 0x01C 0x020 0x028 0x02C}
set pairsN [expr {$case(n) * $case(n)}]

# expected values for window w: per-window arrays for a streaming set (gen_rt_stream.py), else the single case
proc load_expect {w} {
    global case wexp wdet wlam cur_expect cur_top
    catch {unset ::expd}; catch {unset ::expl}
    if {[info exists wexp($w)]} {
        set cur_expect $wexp($w); array set ::expd $wdet($w); array set ::expl $wlam($w)
    } else {
        set cur_expect $case(expect); array set ::expd $case(det_hist); array set ::expl $case(lam_hist)
    }
    set cur_top [expr {min([expr {max([lindex $cur_expect 3], [lindex $cur_expect 6])}] + 1, 8191)}]
}

proc check_window {axi w} {
    global RQA case names offs HIST_K pairsN cur_expect cur_top
    load_expect $w
    set top $cur_top
    upvar #0 expd expd expl expl
    set bad 0
    set vals {}
    foreach o $offs { lappend vals [rd1 $axi [expr {$RQA + $o}]] }
    for {set k 0} {$k < 7} {incr k} {
        if {[lindex $vals $k] != [lindex $cur_expect $k]} {
            puts "RTRUN: window $w MISMATCH [lindex $names $k]: got [lindex $vals $k] want [lindex $cur_expect $k]"; incr bad
        }
    }
    set acc [rd1 $axi [expr {$RQA + 0x038}]]
    if {$acc != $pairsN} { puts "RTRUN: window $w MISMATCH cells_accepted: got $acc want $pairsN"; incr bad }
    foreach {which base arr} [list DET [expr {$RQA + 0x1000}] expd LAM [expr {$RQA + 0x1000 + 4*$HIST_K}] expl] {
        set addrs {}
        for {set b 0} {$b <= $top} {incr b} { lappend addrs [expr {$base + 4*$b}] }
        set g [rd_many $axi $addrs]
        upvar 0 $arr a
        set nb 0
        for {set b 0} {$b <= $top} {incr b} {
            set want [expr {[info exists a($b)] ? $a($b) : 0}]
            if {[lindex $g $b] != $want} { incr nb; if {$nb <= 3} { puts "RTRUN: window $w $which bin $b: got [lindex $g $b] want $want" } }
        }
        incr bad $nb
    }
    return $bad
}

# ---- one result per window ----
set win 0
set deadline [expr {[clock milliseconds] + 600000}]
while {$win < $nrep && [clock milliseconds] < $deadline} {
    set st [rd1 $axi [expr {$RT + 0x04}]]
    if {$st & 1} {
        set tres [clock milliseconds]
        set bad [check_window $axi $win]
        incr win
        puts [format "RTRUN: window %d %s (status 0x%02X, %d ms since DMA start)" $win [expr {$bad ? "FAIL" : "PASS"}] $st [expr {$tres - $tstart}]]
        incr errors $bad
        wr1 $axi [expr {$RT + 0x00}] [expr {$ctrl_en | 4}]
    } else { after 20 }
}
if {$win < $nrep} { puts "RTRUN: TIMEOUT after $win of $nrep windows"; incr errors }

# ---- end state ----
after 300
set dmasr [rd1 $axi [expr {$DMA + 0x04}]]
puts [format "RTRUN: DMA status 0x%08X (idle bit 1 expected, error bits 4,5,6 clear)" $dmasr]
if {$dmasr & 0x70} { puts "RTRUN: DMA error bits set"; incr errors }
lassign [rd_many $axi [list [expr {$RT + 0x04}] [expr {$RT + 0x14}] [expr {$RT + 0x18}] [expr {$RT + 0x1C}] [expr {$RT + 0x20}] [expr {$RT + 0x24}] [expr {$RT + 0x28}] [expr {$RT + 0x2C}] [expr {$RT + 0x30}]]] rtst occmax dropped fdone trl trh twl twh gapf
puts [format "RTRUN: RT status 0x%X, FRAMES_DONE %d, OCC_MAX %d, DROPPED %d, gap frames %d" $rtst $fdone $occmax $dropped $gapf]
set tready [expr {$trh * 4294967296 + $trl}]; set tresult [expr {$twh * 4294967296 + $twl}]
puts [format "RTRUN: last window ready at cycle %d, result at cycle %d, ready-to-result %d cycles = %.3f ms at the measured clock" $tready $tresult [expr {$tresult - $tready}] [expr {($tresult - $tready) / ($fmhz * 1e3)}]]
if {$fdone != $nrep} { puts "RTRUN: FRAMES_DONE $fdone, want $nrep"; incr errors }
if {!$drop && $dropped != 0} { puts "RTRUN: unexpected drops $dropped"; incr errors }
if {$rtst & 0x20} { puts "RTRUN: cfg error flag set"; incr errors }

set result [expr {$errors == 0 ? "PASS" : "FAIL"}]
puts "RTRUN: $result $case(name) x$nrep ($errors errors)"
file mkdir $root/build/hwresults
set fh [open $root/build/hwresults/rt_$case(name).json w]
puts $fh [format "{\"case\": \"%s\", \"windows\": %d, \"result\": \"%s\", \"errors\": %d, \"clock_mhz\": %.3f, \"period\": %d, \"occ_max\": %d, \"dropped\": %d, \"latency_cycles\": %d}" \
    $case(name) $nrep $result $errors $fmhz $period $occmax $dropped [expr {$tresult - $tready}]]
close $fh
close_hw_target
disconnect_hw_server
exit 0
