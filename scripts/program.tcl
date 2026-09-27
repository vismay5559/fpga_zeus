# Volatile JTAG configuration. Does not overwrite QSPI flash.
# vivado -mode batch -source scripts/program.tcl -tclargs build/top/top.bit
set root [file normalize [file join [file dirname [info script]] ..]]
set bit [file join $root build top top.bit]
if {$argc >= 1} {set bit [file normalize [lindex $argv 0]]}
if {![file exists $bit]} {error "Missing bitstream: $bit; build first"}
open_hw_manager
connect_hw_server
open_hw_target
set devices [get_hw_devices xc7a100t*]
if {[llength $devices] != 1} {error "Expected one Arty A7-100T; found $devices"}
set dev [lindex $devices 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
close_hw_manager
