# Volatile JTAG configuration. Does not overwrite QSPI flash.
# vivado -mode batch -source scripts/program.tcl -tclargs build/zybo_z7_20_top/zybo_z7_20_top.bit
set root [file normalize [file join [file dirname [info script]] ..]]
set bit [file join $root build zybo_z7_20_top zybo_z7_20_top.bit]
if {$argc >= 1} {set bit [file normalize [lindex $argv 0]]}
if {![file exists $bit]} {error "Missing bitstream: $bit; build first"}
set device_pattern xc7z020*
if {[file tail $bit] eq "top.bit" || [file tail $bit] eq "pi_link_demo_top.bit"} {
    set device_pattern xc7a100t*
}
if {$argc >= 2} {set device_pattern [lindex $argv 1]}
open_hw_manager
connect_hw_server
open_hw_target
set devices [get_hw_devices $device_pattern]
if {[llength $devices] != 1} {error "Expected one device matching $device_pattern; found $devices"}
set dev [lindex $devices 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
close_hw_manager
