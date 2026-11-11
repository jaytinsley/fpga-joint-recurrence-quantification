# Block design and bitstream for the real-time front end on the ALINX AXU5EVB-P (XCZU5EV-2SFVC784I).
# Design: Zynq UltraScale+ PS (clock only, no DDR, peripherals off; S_AXI_LPD for the DMA to reach OCM; M_AXI_HPM0_LPD for bare-metal software)
#   pl_clk0 -> SmartConnect 0 <- JTAG-to-AXI master and PS M_AXI_HPM0_LPD (PS view: core 0x80000000, DMA 0x80100000)
#                              -> jrp_rt_core (jrp_top + jrp_rt_ingest + clock counter), 1 MB at 0x00000000 (JTAG view)
#                              -> AXI DMA control, 64 KB at 0x00100000 (JTAG view)
#   AXI DMA (MM2S only, 64 bit) M_AXI_MM2S -> SmartConnect 1 -> PS S_AXI_LPD (reaches OCM 0xFFFC0000, 256 KB)
#   AXI DMA M_AXIS_MM2S -> jrp_rt_core sample stream.   jrp_rt_core irq and the DMA irq go to pl_ps_irq0.
# Run from Phase3/build:
#   vivado -mode batch -source ../scripts/build_rt_board.tcl -tclargs bd <clk_mhz> <K> [<MAX_M>]
#   vivado -mode batch -source ../scripts/build_rt_board.tcl -tclargs build <clk_mhz> <K> [<MAX_M>]   (MAX_M other than 6: separate project, outputs get an _m<MAX_M> suffix)
# Programs nothing. Outputs: build/jrp_rt_board.xsa and reports/rt_board_{timing,utilization}.rpt.
set here  [file normalize [file dirname [info script]]]
set root  [file normalize $here/..]
set stage [lindex $::argv 0]; if {$stage eq ""} { set stage bd }
set clk   [lindex $::argv 1]; if {$clk eq ""}   { set clk 150 }
set kk    [lindex $::argv 2]; if {$kk eq ""}    { set kk 2 }
set mm    [lindex $::argv 3]; if {$mm eq ""}    { set mm 6 }   ;# MAX_M: largest embedding dimension (6 = delivered build)
set part  xczu5ev-sfvc784-2-i
set tag   [expr {$mm == 6 ? "" : "_m$mm"}]
set proj  $root/build/jrp_rt_board$tag

if {$stage eq "bd"} {
    file delete -force $proj
    create_project jrp_rt_board$tag $proj -part $part -force
    add_files [glob $root/released/rtl/distance_threshold_calculation.v $root/released/rtl/axi_perf_mon.v]
    add_files [glob $root/rtl/*.v]
    update_compile_order -fileset sources_1

    create_bd_design design_1
    set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ps]
    foreach p [list_property $ps CONFIG.PSU__*__PERIPHERAL__ENABLE] {
        catch { set_property $p 0 $ps }
    }
    set_property -dict [list \
        CONFIG.PSU__FPGA_PL0_ENABLE 1 \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $clk \
        CONFIG.PSU__USE__M_AXI_GP0 0 CONFIG.PSU__USE__M_AXI_GP1 0 CONFIG.PSU__USE__M_AXI_GP2 1 \
        CONFIG.PSU__USE__S_AXI_GP0 0 CONFIG.PSU__USE__S_AXI_GP2 0 CONFIG.PSU__USE__S_AXI_GP6 1 \
        CONFIG.PSU__MAXIGP2__DATA_WIDTH 32 CONFIG.PSU__SAXIGP6__DATA_WIDTH 64 \
        CONFIG.PSU__USE__IRQ0 1 \
        CONFIG.PSU__PSS_REF_CLK__FREQMHZ 33.333 \
    ] $ps
    if {[catch {set_property CONFIG.PSU__DDRC__ENABLE 0 $ps} e]} { puts "BUILD: DDRC enable property: $e" }

    set rst  [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0]
    set jtag [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0]
    set_property -dict [list CONFIG.PROTOCOL 2 CONFIG.M_AXI_ADDR_WIDTH 32 CONFIG.M_AXI_DATA_WIDTH 32] $jtag
    set sc0 [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_0]
    set_property -dict [list CONFIG.NUM_SI 2 CONFIG.NUM_MI 2] $sc0
    set sc1 [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_1]
    set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc1
    set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0]
    set_property -dict [list CONFIG.c_include_sg 0 CONFIG.c_include_s2mm 0 CONFIG.c_include_mm2s 1 \
        CONFIG.c_sg_length_width 26 CONFIG.c_m_axi_mm2s_data_width 64 CONFIG.c_m_axis_mm2s_tdata_width 64 \
        CONFIG.c_mm2s_burst_size 32 CONFIG.c_include_mm2s_dre 0] $dma
    set core [create_bd_cell -type module -reference jrp_rt_core core_0]
    if {$kk != 1} { set_property CONFIG.K $kk $core }
    if {$mm != 6} { set_property CONFIG.MAX_M $mm $core }
    set cat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_cat]
    set_property CONFIG.NUM_PORTS 2 $cat

    connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins rst_0/slowest_sync_clk] \
        [get_bd_pins jtag_axi_0/aclk] [get_bd_pins sc_0/aclk] [get_bd_pins sc_1/aclk] [get_bd_pins core_0/clk] \
        [get_bd_pins axi_dma_0/s_axi_lite_aclk] [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
        [get_bd_pins zynq_ps/saxi_lpd_aclk] [get_bd_pins zynq_ps/maxihpm0_lpd_aclk]
    connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] [get_bd_pins rst_0/ext_reset_in]
    connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn] \
        [get_bd_pins sc_0/aresetn] [get_bd_pins sc_1/aresetn] [get_bd_pins core_0/rst_n] [get_bd_pins axi_dma_0/axi_resetn]
    connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI]          [get_bd_intf_pins sc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_HPM0_LPD]    [get_bd_intf_pins sc_0/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins sc_0/M00_AXI]              [get_bd_intf_pins core_0/s_axi]
    connect_bd_intf_net [get_bd_intf_pins sc_0/M01_AXI]              [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S]      [get_bd_intf_pins sc_1/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins sc_1/M00_AXI]              [get_bd_intf_pins zynq_ps/S_AXI_LPD]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S]     [get_bd_intf_pins core_0/s_axis_samples]
    connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins irq_cat/In0]
    connect_bd_net [get_bd_pins core_0/irq]             [get_bd_pins irq_cat/In1]
    connect_bd_net [get_bd_pins irq_cat/dout]           [get_bd_pins zynq_ps/pl_ps_irq0]

    # JTAG view of the address map (hw scripts); the PS and the DMA take their ranges from the tool
    assign_bd_address -offset 0x00000000 -range 1M  -target_address_space [get_bd_addr_spaces jtag_axi_0/Data] [get_bd_addr_segs core_0/s_axi/reg0]
    assign_bd_address -offset 0x00100000 -range 64K -target_address_space [get_bd_addr_spaces jtag_axi_0/Data] [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]
    # PS view (bare-metal software): same blocks inside the HPM0_LPD aperture at 0x80000000
    assign_bd_address -offset 0x80000000 -range 1M  -target_address_space [get_bd_addr_spaces zynq_ps/Data] [get_bd_addr_segs core_0/s_axi/reg0]
    assign_bd_address -offset 0x80100000 -range 64K -target_address_space [get_bd_addr_spaces zynq_ps/Data] [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]
    assign_bd_address
    foreach sg [get_bd_addr_segs -excluded -of_objects [get_bd_addr_spaces axi_dma_0/Data_MM2S]] { include_bd_addr_seg $sg }
    validate_bd_design
    save_bd_design
    puts "BUILD: block design validated"
    puts [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $ps]
    foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces axi_dma_0/Data_MM2S]] { puts "BUILD: DMA sees $s" }
    exit 0
}

# ---- build: synthesis, implementation, bitstream, hardware platform ----
open_project $proj/jrp_rt_board$tag.xpr
make_wrapper -files [get_files $proj/jrp_rt_board$tag.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj/jrp_rt_board$tag.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
# a re-run of a finished project needs every run reset first (source files may have changed)
foreach r [get_runs -filter {IS_SYNTHESIS == 1}] { reset_run $r }
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "BUILD: implementation did not finish"; exit 1 }
open_run impl_1
report_utilization -file $root/reports/rt_board${tag}_utilization.rpt
report_timing_summary -file $root/reports/rt_board${tag}_timing.rpt -max_paths 10
write_hw_platform -fixed -include_bit -force $root/build/jrp_rt_board$tag.xsa
puts "BUILD: done, clock ${clk} MHz"
exit 0
