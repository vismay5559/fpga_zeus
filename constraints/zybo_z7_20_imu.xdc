# Sensor-only Z7-20 top; pins from Digilent Zybo-Z7-Master.xdc.
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports clk125]
create_clock -name clk125_pin -period 8.000 [get_ports clk125]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports btn0]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
# Adafruit BNO085 SDA/UART-out -> JE1; JE2 -> breakout SCL/UART-in.
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports imu_rx]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports imu_tx]
set_false_path -from [get_ports imu_rx] -to [get_pins -hier -filter {NAME =~ */sync_reg[0]/D}]
set_false_path -from [get_ports btn0] -to [get_pins -hier -filter {NAME =~ */btn_sync_reg[*]/D}]
