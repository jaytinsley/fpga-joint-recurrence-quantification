# Block design and bitstream for the ALINX AXU5EVB-P (XCZU5EV-2SFVC784I).
# Design: Zynq UltraScale+ PS (clock only, no DDR, peripherals off) -> pl_clk0 -> JTAG-to-AXI master ->
#         jrp_board_core (jrp_top + sample feeder + clock counter) at address 0x00000000, 1 MB window.
# Run from Phase3/build:
#   vivado -mode batch -source ../scripts/build_board.tcl -tclargs bd <clk_mhz> <K>    (create + validate, quick)
#   vivado -mode batch -source ../scripts/build_board.tcl -tclargs build <clk_mhz> <K>   (synth, impl, bitstream, XSA)
# Programs nothing: the outputs are build/jrp_board/jrp_board.runs/.../*.bit and build/jrp_board.xsa.
set here  [file normalize [file dirname [info script]]]
set root  [file normalize $here/..]
set stage [lindex $::argv 0]; if {$stage eq ""} { set stage bd }
set clk   [lindex $::argv 1]; if {$clk eq ""}   { set clk 100 }
set kk    [lindex $::argv 2]; if {$kk eq ""}    { set kk 1 }   ;# cells per cycle: 1 or 2
set part  xczu5ev-sfvc784-2-i
set proj  $root/build/jrp_board

if {$stage eq "bd"} {
    file delete -force $proj
    create_project jrp_board $proj -part $part -force
    add_files [glob $root/released/rtl/distance_threshold_calculation.v $root/released/rtl/axi_perf_mon.v]
    add_files [glob $root/rtl/*.v]
    update_compile_order -fileset sources_1

    create_bd_design design_1
    set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ps]
    # no board preset available: switch every PS peripheral off and take only pl_clk0 and the PL reset
    foreach p [list_property $ps CONFIG.PSU__*__PERIPHERAL__ENABLE] {
        catch { set_property $p 0 $ps }
    }
    set_property -dict [list \
        CONFIG.PSU__FPGA_PL0_ENABLE 1 \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $clk \
        CONFIG.PSU__USE__M_AXI_GP0 0 CONFIG.PSU__USE__M_AXI_GP1 0 CONFIG.PSU__USE__M_AXI_GP2 0 \
        CONFIG.PSU__USE__S_AXI_GP0 0 CONFIG.PSU__USE__S_AXI_GP2 0 \
        CONFIG.PSU__PSS_REF_CLK__FREQMHZ 33.333 \
    ] $ps
    if {[catch {set_property CONFIG.PSU__DDRC__ENABLE 0 $ps} e]} { puts "BUILD: DDRC enable property: $e" }

    set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0]
    set jtag [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0]
    set_property -dict [list CONFIG.PROTOCOL 2 CONFIG.M_AXI_ADDR_WIDTH 32 CONFIG.M_AXI_DATA_WIDTH 32] $jtag
    set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_0]
    set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc
    set core [create_bd_cell -type module -reference jrp_board_core core_0]
    if {$kk != 1} { set_property CONFIG.K $kk $core }

    connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins rst_0/slowest_sync_clk] \
        [get_bd_pins jtag_axi_0/aclk] [get_bd_pins sc_0/aclk] [get_bd_pins core_0/clk]
    connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] [get_bd_pins rst_0/ext_reset_in]
    connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn] \
        [get_bd_pins sc_0/aresetn] [get_bd_pins core_0/rst_n]
    connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins sc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins sc_0/M00_AXI] [get_bd_intf_pins core_0/s_axi]
    assign_bd_address -offset 0x00000000 -range 1M [get_bd_addr_segs core_0/s_axi/reg0]
    validate_bd_design
    save_bd_design
    puts "BUILD: block design validated"
    puts [report_property [get_bd_cells zynq_ps] CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ]
    exit 0
}

# ---- build: synthesis, implementation, bitstream, hardware platform ----
open_project $proj/jrp_board.xpr
make_wrapper -files [get_files $proj/jrp_board.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj/jrp_board.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "BUILD: implementation did not finish"; exit 1 }
open_run impl_1
report_utilization -file $root/reports/board_utilization.rpt
report_timing_summary -file $root/reports/board_timing.rpt -max_paths 10
write_hw_platform -fixed -include_bit -force $root/build/jrp_board.xsa
puts "BUILD: done, clock ${clk} MHz"
exit 0
