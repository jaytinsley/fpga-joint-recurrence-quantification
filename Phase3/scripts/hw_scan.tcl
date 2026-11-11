# Read-only scan: what JTAG targets and devices can Vivado's hardware manager see?
# Run: vivado -mode batch -source hw_scan.tcl
# Does not program or change anything.
open_hw_manager
if {[catch {connect_hw_server -allow_non_jtag} err]} {
    puts "HWSCAN: could not start or reach hw_server: $err"
    exit 0
}
set targets [get_hw_targets -quiet]
puts "HWSCAN: targets found: [llength $targets]"
foreach t $targets {
    puts "HWSCAN: target $t"
    if {[catch {open_hw_target $t} err]} {
        puts "HWSCAN:   open_hw_target failed: $err"
        continue
    }
    set devs [get_hw_devices -quiet]
    puts "HWSCAN:   devices on chain: [llength $devs]"
    foreach d $devs {
        puts "HWSCAN:   device $d part=[get_property PART $d] idcode=[get_property IDCODE_HEX $d]"
    }
    close_hw_target
}
disconnect_hw_server
close_hw_manager
