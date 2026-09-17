# Usage:  make TOP=tick_gen      (default)
#         make TOP=uart_tx WAVES=1
TOP ?= tick_gen

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

# ROS (sourced in ~/.bashrc) exposes pytest plugins that break cocotb; skip them
export PYTEST_DISABLE_PLUGIN_AUTOLOAD := 1

VERILOG_SOURCES += $(wildcard $(PWD)/../rtl/*.v)
COCOTB_TOPLEVEL = $(TOP)
COCOTB_TEST_MODULES = test_$(TOP)
SIM_BUILD = sim_build/$(TOP)

# Small parameters so simulations are fast (tests read the same values)
ifeq ($(TOP),tick_gen)
COMPILE_ARGS += -Ptick_gen.DIV=10
endif
ifeq ($(TOP),uart_tx)
COMPILE_ARGS += -Puart_tx.CLKS_PER_BIT=16
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

# Open the waveform in GTKWave: make TOP=uart_tx view
# env -i strips the snap-VS-Code library paths that crash GTKWave in its terminal.
.PHONY: view
view:
	env -i HOME="$(HOME)" PATH=/usr/bin:/bin DISPLAY="$(DISPLAY)" \
	    WAYLAND_DISPLAY="$(WAYLAND_DISPLAY)" XDG_RUNTIME_DIR="$(XDG_RUNTIME_DIR)" \
	    gtkwave sim_build/$(TOP)/$(TOP).fst $(wildcard $(TOP).gtkw) &

