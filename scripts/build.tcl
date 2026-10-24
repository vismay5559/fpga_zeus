# Run from any directory. Optional args: top-module constraint-file part.
# Default is the user's Zybo Z7-20. Legacy Arty tops auto-select the Arty part.
set root [file normalize [file join [file dirname [info script]] ..]]
set part xc7z020clg400-1
set_param general.maxThreads 2
set_msg_config -id {Vivado 12-4739} -new_severity ERROR
set_msg_config -id {Constraints 18-540} -new_severity ERROR
set top zybo_z7_20_top
if {$argc >= 1} {set top [lindex $argv 0]}
switch -- $top {
    zybo_z7_20_top {set xdc [file join $root constraints zybo_z7_20_blinky.xdc]}
    zybo_z7_20_imu_top {set xdc [file join $root constraints zybo_z7_20_imu.xdc]}
    zybo_z7_20_demo_top {set xdc [file join $root constraints zybo_z7_20_demo.xdc]}
    top {set part xc7a100tcsg324-1; set xdc [file join $root constraints arty_a7_100.xdc]}
    pi_link_demo_top {set part xc7a100tcsg324-1; set xdc [file join $root constraints arty_a7_100_pi_demo.xdc]}
    default {error "Unknown top $top: pass its XDC and part explicitly"}
}
if {$argc >= 2} {set xdc [file normalize [lindex $argv 1]]}
if {$argc >= 3} {set part [lindex $argv 2]}
set outdir [file join $root build $top]
file mkdir $outdir
read_verilog [lsort [glob [file join $root rtl * *.v]]]
read_xdc $xdc
synth_design -top $top -part $part
opt_design
place_design
route_design
report_utilization -file $outdir/utilization.rpt
report_timing_summary -report_unconstrained -file $outdir/timing.rpt
report_cdc -file $outdir/cdc.rpt
report_drc -file $outdir/drc.rpt
report_io -file $outdir/io.rpt
write_checkpoint -force $outdir/routed.dcp
foreach kind {max min} {
    set paths [get_timing_paths -delay_type $kind -max_paths 1]
    if {[llength $paths] == 0} {error "No $kind timing paths found; inspect constraints"}
    if {[get_property SLACK [lindex $paths 0]] < 0} {
        error "Negative $kind timing slack; inspect $outdir/timing.rpt"
    }
}
write_bitstream -force $outdir/$top.bit
puts "BITSTREAM: $outdir/$top.bit"
