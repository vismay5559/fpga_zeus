# Digilent Zybo Z7 Rev B, Z7-20; source: Digilent Zybo-Z7-Master.xdc.
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports clk125]
create_clock -name clk125_pin -period 8.000 [get_ports clk125]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports btn0]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports led0]
