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

ifeq ($(TOP),fifo_sync)
export FIFO_DEPTH ?= 16
export FIFO_WIDTH ?= 8
COMPILE_ARGS += -Pfifo_sync.DEPTH=$(FIFO_DEPTH) -Pfifo_sync.WIDTH=$(FIFO_WIDTH)
SIM_BUILD = sim_build/fifo_sync_d$(FIFO_DEPTH)_w$(FIFO_WIDTH)
endif

# Small parameters so simulations are fast (tests read the same values)
ifeq ($(TOP),tick_gen)
COMPILE_ARGS += -Ptick_gen.DIV=10
endif
ifeq ($(TOP),uart_tx)
COMPILE_ARGS += -Puart_tx.CLKS_PER_BIT=16
endif
ifeq ($(TOP),uart_rx)
export UART_RX_CLKS_PER_BIT ?= 16
COMPILE_ARGS += -Puart_rx.CLKS_PER_BIT=$(UART_RX_CLKS_PER_BIT)
SIM_BUILD = sim_build/uart_rx_c$(UART_RX_CLKS_PER_BIT)
endif
ifeq ($(TOP),uart_rx_fifo)
export UART_RX_FIFO_CLKS_PER_BIT ?= 33
export UART_FIFO_DEPTH ?= 8
COMPILE_ARGS += -Puart_rx_fifo.CLKS_PER_BIT=$(UART_RX_FIFO_CLKS_PER_BIT)
COMPILE_ARGS += -Puart_rx_fifo.FIFO_DEPTH=$(UART_FIFO_DEPTH)
SIM_BUILD = sim_build/uart_rx_fifo_c$(UART_RX_FIFO_CLKS_PER_BIT)_d$(UART_FIFO_DEPTH)
endif
ifeq ($(TOP),shtp_uart_deframer)
export SHTP_MAX_PACKET_BYTES ?= 32
export SHTP_TIMEOUT_CYCLES ?= 40
COMPILE_ARGS += -Pshtp_uart_deframer.MAX_PACKET_BYTES=$(SHTP_MAX_PACKET_BYTES)
COMPILE_ARGS += -Pshtp_uart_deframer.TIMEOUT_CYCLES=$(SHTP_TIMEOUT_CYCLES)
SIM_BUILD = sim_build/shtp_uart_deframer_m$(SHTP_MAX_PACKET_BYTES)_t$(SHTP_TIMEOUT_CYCLES)
endif
ifeq ($(TOP),bno085_uart_rx)
export BNO_RX_CLKS_PER_BIT ?= 33
export BNO_RX_FIFO_DEPTH ?= 4
export BNO_RX_MAX_PACKET_BYTES ?= 32
export BNO_RX_TIMEOUT_CYCLES ?= 450
COMPILE_ARGS += -Pbno085_uart_rx.CLKS_PER_BIT=$(BNO_RX_CLKS_PER_BIT)
COMPILE_ARGS += -Pbno085_uart_rx.FIFO_DEPTH=$(BNO_RX_FIFO_DEPTH)
COMPILE_ARGS += -Pbno085_uart_rx.MAX_PACKET_BYTES=$(BNO_RX_MAX_PACKET_BYTES)
COMPILE_ARGS += -Pbno085_uart_rx.TIMEOUT_CYCLES=$(BNO_RX_TIMEOUT_CYCLES)
SIM_BUILD = sim_build/bno085_uart_rx_c$(BNO_RX_CLKS_PER_BIT)_d$(BNO_RX_FIFO_DEPTH)_m$(BNO_RX_MAX_PACKET_BYTES)_t$(BNO_RX_TIMEOUT_CYCLES)
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

# Open the waveform in GTKWave: make TOP=uart_tx view
# env -i strips the snap-VS-Code library paths that crash GTKWave in its terminal.
.PHONY: view test-uart-bno085
test-uart-bno085:
	$(MAKE) TOP=uart_rx UART_RX_CLKS_PER_BIT=33 COCOTB_TEST_MODULES=test_uart_rx_bno085

view:
	env -i HOME="$(HOME)" PATH=/usr/bin:/bin DISPLAY="$(DISPLAY)" \
	    WAYLAND_DISPLAY="$(WAYLAND_DISPLAY)" XDG_RUNTIME_DIR="$(XDG_RUNTIME_DIR)" \
	    gtkwave $(SIM_BUILD)/$(TOP).fst $(wildcard $(TOP).gtkw) &
