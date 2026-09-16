# Non-project build. Run from the project root:
#   vivado -mode batch -source scripts/build.tcl
set part   xc7a100tcsg324-1
set top    top
set outdir build
file mkdir $outdir

read_verilog [glob rtl/*.v]
read_xdc     constraints/arty_a7_100.xdc

synth_design -top $top -part $part
opt_design
place_design
route_design

report_utilization    -file $outdir/utilization.rpt
report_timing_summary -file $outdir/timing.rpt
write_bitstream -force $outdir/$top.bit
