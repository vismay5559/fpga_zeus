# Digilent Zybo Z7 Rev B, Z7-20. All external digital I/O here is 3.3 V.
# Source: https://github.com/Digilent/digilent-xdc/blob/master/Zybo-Z7-Master.xdc
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports clk125]
create_clock -name clk125_pin -period 8.000 [get_ports clk125]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports btn0]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
# Standard Pmod JE: UART sensor output SDA -> JE1, FPGA output JE2 -> sensor SCL.
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports imu_rx]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports imu_tx]
# Pi SPI on standard Pmod JE3/4/7/8. External Pi is SPI master.
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports pi_sck]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports pi_cs_n]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports pi_miso]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports pi_data_ready]
# Each center-sole normally-open switch shorts its input to ground when pressed.
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {foot_sw_n[0]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {foot_sw_n[1]}]
# Only the first stage of each input synchronizer is exempt from clock timing.
set_false_path -from [get_ports imu_rx] -to [get_pins -hier -filter {NAME =~ */sync_reg[0]/D}]
set_false_path -from [get_ports pi_sck] -to [get_pins -hier -filter {NAME =~ */sck_sync_reg[0]/D}]
set_false_path -from [get_ports pi_cs_n] -to [get_pins -hier -filter {NAME =~ */cs_sync_reg[0]/D}]
set_false_path -from [get_ports {foot_sw_n[*]}] -to [get_pins -hier -filter {NAME =~ */sync_first_reg[*]/D}]
set_false_path -from [get_ports btn0] -to [get_pins -hier -filter {NAME =~ */btn_sync_reg[*]/D}]
# Placeholder output budgets; bench-measure external SPI timing before robot use.
set_max_delay 10.0 -datapath_only -to [get_ports pi_miso]
set_max_delay 10.0 -datapath_only -to [get_ports pi_data_ready]
set_max_delay 10.0 -datapath_only -from [get_ports pi_cs_n] -to [get_ports pi_miso]
