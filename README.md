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
rtl/          common/, uart/, imu/, pi_link/, spi/, can/, gpio/, top/
sim/          matching interface test folders + shared Makefile
constraints/  Arty pin assignments (.xdc)
scripts/      build/program Tcl and regression/mutation runners
pi/           packet decoder and Raspberry Pi SPI reader
docs/         protocol, team integration, and hardware bring-up guides
```

## Pi link and team organization

- [Team ownership and folder workflow](docs/TEAM_WORKFLOW.md)
- [Recorded simulation and build checks](docs/PI_LINK_VERIFICATION.md)
- [Exact 640-byte FPGA-to-Pi protocol](docs/PI_LINK_PROTOCOL.md)
- [Build, program and test on Arty A7-100T](docs/ARTY_A7_BRINGUP.md)

The Pi-facing SPI slave is implemented for reading sensor snapshots. Your teammate
owns the separate encoder SPI master. The standalone Pi demo sends TEST_MODE
packets with sensor validity clear; real sensor payload integration and the
Pi-to-FPGA motor-command path remain unfinished. The new ten-actuator integer
protocol is not byte-compatible with the STM32 eight-actuator float protocol.

Run all tests: `python scripts/run_tests.py` after activating the simulation venv.
Run just this link: `make -C sim TOP=pi_link`.

## Modules

| Module | State | What it does |
|---|---|---|
| [`cycle_timer`](rtl/common/cycle_timer.v) | simulation-tested | microsecond timestamp and 1 kHz sample strobe |
| [`pi_link`](rtl/pi_link/pi_link.v) | simulation-tested | atomic snapshot/CRC and read-only Pi SPI slave |
| [`pi_link_demo_top`](rtl/top/pi_link_demo_top.v) | bench demo | dedicated Arty top with invalid sensor payload |
| [`tick_gen`](rtl/common/tick_gen.v) | done | one-cycle pulse every N clocks; baud and cycle timing |
| [`uart_tx`](rtl/uart/uart_tx.v) | done | 8N1 transmitter, LSB first, valid/ready handshake |
| [`top`](rtl/top/top.v) | done | board bring-up blinky: LD4 toggles once per second, BTN0 resets |
| [`uart_rx`](rtl/uart/uart_rx.v) | done | receiver: 2-flop synchronizer, mid-bit sampling, glitch rejection, framing errors |
| [`fifo_sync`](rtl/common/fifo_sync.v) | done | parameterized synchronous byte queue with overflow/underflow diagnostics |
| [`uart_rx_fifo`](rtl/uart/uart_rx_fifo.v) | done | connects UART RX bytes to FIFO; tested with independent 3 Mbaud input |
| [`shtp_uart_deframer`](rtl/imu/shtp_uart_deframer.v) | done | stages, unescapes and validates complete UART-SHTP packets |
| [`bno085_uart_rx`](rtl/imu/bno085_uart_rx.v) | done | complete serial RX → FIFO → validated SHTP packet integration and recovery |
| [`sh2_report_parser`](rtl/imu/sh2_report_parser.v) | done | atomically decodes accel Q8, gyro Q9 and Rotation Vector Q14 reports |
| [`bno085_imu_rx`](rtl/imu/bno085_imu_rx.v) | done | real 3 Mbaud RX through retained raw IMU registers, timestamps and freshness |
| [`bno085_uart_packet_tx`](rtl/imu/bno085_uart_packet_tx.v) | done | SHTP framing/escaping and a parameterized gap after every physical UART byte |
| [`bno085_startup_controller`](rtl/imu/bno085_startup_controller.v) | done | BSQ/BSN flow control, exact 400/400/100 commands, confirmation and reset recovery |
| [`bno085_imu`](rtl/imu/bno085_imu.v) | done | complete bidirectional sensor host from RX/TX pins to configured IMU registers |

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
make TOP=bno085_uart_packet_tx                  # paced SHTP transmitter
make test-bno-tx-gaps                           # measure both 100 us and 120 us settings
make TOP=bno085_startup_controller              # command and flow-control state machine
make TOP=bno085_imu                             # complete bidirectional host
make view-uart-example                          # checked-in passing UART waveform

verilator --lint-only -Wall rtl/uart/uart_tx.v       # from the project root
```

Simulation parameters are shrunk so tests run fast: `CLKS_PER_BIT=16` for `uart_tx`,
`DIV=10` for `tick_gen`. The synthesized design uses the real values.

## Building for the board

```bash
vivado -mode batch -source scripts/build.tcl    # → build/top/top.bit
grep -A3 WNS build/top/timing.rpt                   # worst slack must not be negative
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
