# fpga_zeus

FPGA hardware-interface layer for a bipedal robot, replacing the STM32 that currently
handles every sensor and motor bus.

**Board:** Digilent Arty A7-100T (Xilinx Artix-7, `xc7a100tcsg324-1`, 100 MHz)

## What it will do

The Pi is the main compute. The FPGA owns everything with hard timing, samples all of
it on the same 1 kHz strobe, and hands the Pi one timestamped snapshot per cycle.

| Interface | Devices | Notes |
|---|---|---|
| CAN FD ×2 | 10× ODrive S1 | 1 Mbit nominal / 5 Mbit data, ISO1042 transceivers, CTU CAN FD core |
| SPI master ×4 | AS5047P encoders | after-spring position on both hip and knee SEAs |
| GPIO ×4 | foot switches | heel + toe per foot, debounced in logic |
| UART | BNO085 IMU | SHTP framing at 3 Mbaud |
| SPI slave | Raspberry Pi | state snapshot out, motor commands in, plus a data-ready line |

Sensor fusion (InEKF) stays off the FPGA for now. See [ROADMAP.md](ROADMAP.md) for the
schedule and current status, and [CONTEXT.md](CONTEXT.md) for the full background:
decisions already made, working conventions, and environment quirks.

## Layout

```
rtl/          Verilog modules
sim/          cocotb testbenches (the spec for each module) + Makefile
constraints/  Arty pin assignments (.xdc)
scripts/      Vivado build and programming scripts (Tcl, no GUI needed)
```

## Modules

| Module | State | What it does |
|---|---|---|
| [`tick_gen`](rtl/tick_gen.v) | done | one-cycle pulse every N clocks; baud and cycle timing |
| [`uart_tx`](rtl/uart_tx.v) | done | 8N1 transmitter, LSB first, valid/ready handshake |
| [`top`](rtl/top.v) | done | board bring-up blinky: LD4 at 1 Hz, BTN0 resets |
| [`uart_rx`](rtl/uart_rx.v) | done | receiver: 2-flop synchronizer, mid-bit sampling, glitch rejection, framing errors |
| [`fifo_sync`](rtl/fifo_sync.v) | done | parameterized synchronous byte queue with overflow/underflow diagnostics |
| [`uart_rx_fifo`](rtl/uart_rx_fifo.v) | done | connects UART RX bytes to FIFO; tested with independent 3 Mbaud input |
| [`shtp_uart_deframer`](rtl/shtp_uart_deframer.v) | done | stages, unescapes and validates complete UART-SHTP packets |
| [`bno085_uart_rx`](rtl/bno085_uart_rx.v) | done | complete serial RX → FIFO → validated SHTP packet integration and recovery |
| [`sh2_report_parser`](rtl/sh2_report_parser.v) | done | atomically decodes accel Q8, gyro Q9 and Rotation Vector Q14 reports |
| [`bno085_imu_rx`](rtl/bno085_imu_rx.v) | done | real 3 Mbaud RX through retained raw IMU registers, timestamps and freshness |

The [FIFO walkthrough](sim/FIFO_EXERCISE.md) explains its tests and RTL from basics.
IMU requirements and STM32 comparison: [BNO085 plan](BNO085_PLAN.md).
The [UART/BNO085 walkthrough](UART_BNO085_WALKTHROUGH.md) explains UART, every
receive module and every cocotb file from the beginning.

## Working on it

Every module is written test-first: the cocotb testbench in `sim/` is the
specification, and the RTL is written until it passes. Nothing is flashed to the board
before it passes in simulation.

```bash
source ~/fpga/venv/bin/activate

cd sim
make TOP=uart_tx WAVES=1     # compile with Icarus, run the cocotb tests, record waves
make TOP=uart_tx view        # open the waveform in GTKWave
make TOP=uart_tx COCOTB_TESTCASE=single_bytes   # run one test
make TOP=bno085_uart_rx                         # full BNO085 receive transport
make TOP=sh2_report_parser                      # focused SH-2 report tests
make TOP=bno085_imu_rx                          # serial wire through final IMU registers
make view-uart-example                          # checked-in passing UART waveform

verilator --lint-only -Wall rtl/uart_tx.v       # from the project root
```

Simulation parameters are shrunk so tests run fast: `CLKS_PER_BIT=16` for `uart_tx`,
`DIV=10` for `tick_gen`. The synthesized design uses the real values.

## Building for the board

```bash
vivado -mode batch -source scripts/build.tcl    # → build/top.bit
grep -A3 WNS build/timing.rpt                   # worst slack must not be negative
vivado -mode batch -source scripts/program.tcl  # flash over USB (lost on power-off)
```

## Toolchain

Vivado 2026.1 (Basic tier license, Artix-7 only) · Icarus Verilog 12 · Verilator 5 ·
cocotb 2.1 in a venv at `~/fpga/venv` · GTKWave.

Two environment quirks on this setup:

- ROS is sourced in `~/.bashrc` and its pytest plugins break cocotb, so the sim Makefile
  sets `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`.
- VS Code installed as a snap exports library paths that crash GTKWave and block
  Surfer's WebGL, so `make view` clears the environment before launching.
