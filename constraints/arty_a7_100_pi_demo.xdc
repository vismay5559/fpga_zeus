# Arty A7-100T Rev D/E; dedicated read-only Pi demo on JA.
# Source: Digilent/digilent-xdc Arty-A7-100-Master.xdc.
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -name sys_clk_pin -period 10.000 [get_ports CLK100MHZ]
set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN H5 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
# JD1/JD2: left/right center-sole switches.
# Each normally-open switch connects its signal to ground when closed.
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {foot_sw_n[0]}]
set_property -dict {PACKAGE_PIN D3 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {foot_sw_n[1]}]
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports pi_sck]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports pi_cs_n]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports pi_miso]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports pi_data_ready]
# Cut only asynchronous paths into first-stage synchronizer D pins.
set_false_path -from [get_ports pi_sck] -to [get_pins -hier -filter {NAME =~ */sck_sync_reg[0]/D}]
set_false_path -from [get_ports pi_cs_n] -to [get_pins -hier -filter {NAME =~ */cs_sync_reg[0]/D}]
set_false_path -from [get_ports {btn[0]}] -to [get_pins -hier -filter {NAME == btn_sync_reg[0]/D}]
# Internal output budgets; external SPI timing still requires bench validation.
set_max_delay 10.0 -datapath_only -from [get_clocks sys_clk_pin] -to [get_ports pi_miso]
set_max_delay 10.0 -datapath_only -from [get_clocks sys_clk_pin] -to [get_ports pi_data_ready]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_max_delay 10.0 -datapath_only -from [get_ports pi_cs_n] -to [get_ports pi_miso]

# The first stage alone receives asynchronous switch inputs.
set_false_path -from [get_ports {foot_sw_n[*]}] -to [get_pins -hier -filter {NAME =~ */sync_first_reg[*]/D}]
