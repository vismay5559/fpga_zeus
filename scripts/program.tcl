# Flash the bitstream over USB (volatile, lost on power-off):
#   vivado -mode batch -source scripts/program.tcl
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE build/top.bit $dev
program_hw_devices $dev
close_hw_manager
