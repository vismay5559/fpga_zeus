SIM ?= icarus
TOPLEVEL_LANG ?= verilog
# ROS (sourced in ~/.bashrc) exposes pytest plugins that break cocotb; skip them
export PYTEST_DISABLE_PLUGIN_AUTOLOAD := 1

VERILOG_SOURCES += $(PWD)/../rtl/tick_gen.v
COCOTB_TOPLEVEL = tick_gen
COCOTB_TEST_MODULES = test_tick_gen

# Small divider so the simulation is fast
COMPILE_ARGS += -Ptick_gen.DIV=10

include $(shell cocotb-config --makefiles)/Makefile.sim
