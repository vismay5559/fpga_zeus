# Context handoff

Historical handoff notes, originally written 2026-09-20. For the current
implementation boundary use [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md);
for the current order of work use [ROADMAP.md](ROADMAP.md). Some dated notes
below describe plans as they stood when written.

Update 2026-09-22: [BNO085_PLAN.md](BNO085_PLAN.md) records verified SH-2
formats, pinned STM32 configuration, rate caveats and future recovery/freshness
tests. FIFO RTL is complete with its six TODO explanations retained; see
[sim/FIFO_EXERCISE.md](sim/FIFO_EXERCISE.md). `uart_rx_fifo` connects RX to the
queue. Its 5/5 tests drive real serial bits and cover order, stalls, overflow,
framing-error recovery and reset. Integration exposed and fixed a UART recovery
bug: RX must observe idle high before it can arm for another start, so a bad low
stop bit cannot become a phantom frame. New UART tests pass at 100 MHz/divider 33
against independent 3 Mbaud input.
`shtp_uart_deframer` stages a whole UART-SHTP message before publishing it,
decodes reserved-byte escapes, supports protocol 0 control and protocol 1 SHTP,
validates SHTP length, rejects continuation packets, and resynchronizes after
bad protocol, malformed escape, oversize input, timeout, or upstream byte loss.
Its 10/10 tests pass; escape and length-check mutations were confirmed to fail.
`bno085_uart_rx` now supplies that integration wrapper. A holding register safely
adapts the FIFO's registered read pulse to the deframer's valid/ready input. Its
end-to-end tests drive real independent 3 Mbaud serial bits and cover escaped and
consecutive packets, +100 ppm sender offset, mid-stream attachment, framing error,
timeout, output backpressure, FIFO overflow, stale-byte flushing and recovery.
The packet transport is complete through validated packet bytes. Deliberately
corrupting bridge data and disabling FIFO flushing both made the tests fail;
correct RTL was restored.
`sh2_report_parser` and `bno085_imu_rx` now complete that receive-side decoding.
They retain raw signed Q8/Q9/Q14 integers, quaternion accuracy Q12, SH-2 and SHTP
sequences, packed status/delay, Base Timestamp/Rebase metadata, opening-boundary
capture time, `has_sample`, and new-since-snapshot flags. Unknown or truncated
records discard the entire staged packet. Seven focused parser tests and two actual
3 Mbaud serial-to-register tests pass. A real passing UART FST waveform and GTKWave
layout live in `sim/waves/`; run `make view-uart-example` from `sim/`.
`bno085_uart_packet_tx`, `bno085_startup_controller`, and `bno085_imu` now
complete the simulated bidirectional host. The transmitter measures the quiet time
from one stop-bit end to the next start and defaults to 120 us. The controller sends
BSQ before every write, accepts one unexpired BSN token, requests/reads the advertised
timeout, sends Rotation Vector/accel/gyro Set Feature commands for 100/400/400 Hz,
confirms all three with Get Feature responses, retries bad/missing confirmations, and
reconfigures after a deduplicated channel-1 reset notice. A confirmed reset invalidates
all report `has_sample`/`new` flags and sequence history. Physical rates still need
measurement. FPGA is the sole sensor host. It stores signed integers
plus Q points (8/9/14), Pi scales; acceleration includes gravity. Rotation Vector
is comparison-only, never an InEKF input. Pinned STM32 code converts Q values to
floats, so account for this representation difference when comparing outputs.

## The project

A bipedal robot currently has an STM32 handling every bus, streaming sensor data to a
Raspberry Pi over USB OTG HS. The work here moves that hardware layer onto an FPGA, the
way industrial bipeds do it. The Pi stays as main compute.

Target split: the **FPGA owns everything with hard timing**, samples it all on one 1 kHz
strobe, and hands the Pi a timestamped snapshot per cycle. Sensor fusion (an InEKF)
is intended to move onboard eventually, but explicitly **not** in the current goal;
it stays on the STM32/Pi until the comms layer is solid.

Original integration target: **every sensor read by the FPGA on 2026-10-15.**
The current implementation status is tracked separately in docs/PROJECT_STATUS.md.

### Hardware being absorbed

| Interface | Devices | Details |
|---|---|---|
| CAN FD ×2 buses | 5 ODrive S1 each (10 axes) | 1 Mbit nominal / 5 Mbit data, ISO1042 transceivers |
| SPI master ×4 | AS5047P encoders | after-spring position, hip + knee SEAs, both legs |
| GPIO ×2 | foot switches | one center-sole switch per foot |
| UART | BNO085 IMU | SHTP framing at 3 Mbaud |
| SPI slave | Raspberry Pi | snapshot out / commands in, plus a data-ready GPIO |

An RS485 BMS link exists on the robot and was in an earlier plan, but is out of scope
for the Oct 15 goal.

### Decisions already made (do not relitigate)

- **Board: Arty A7-100T** (`xc7a100tcsg324-1`), pure FPGA, no hard CPU. Chosen over a
  Zynq to learn RTL, with room for two CAN FD cores plus a soft core or HLS block later.
  No physical-board test result is recorded in this repository.
- **CAN FD: integrate the open-source CTU CAN FD core (VHDL)** rather than writing one.
  Needs GHDL for simulation; Vivado handles mixed-language synthesis. Do not suggest
  external CAN controller chips (e.g. MCP2518FD) — that was considered and rejected.
- **BNO085 runs UART-SHTP, not UART-RVC.**
- **Pi link is SPI with the FPGA as slave**, plus a data-ready line, using the new ZFP1 ten-actuator integer snapshot. The STM32 v8 layout is
  eight-actuator/float/estimator-output and is not wire compatible. Pi adaptation
  and estimator execution are required.
- **No soft core for now.** The simulated BNO085 host sends its own startup
  configuration. A general Pi-to-FPGA register/command path is not implemented.

## How work is done here

**Test-first; the user has also explicitly requested complete RTL implementations.** The user is a robotics engineer who is new
to Verilog and is deliberately learning it. The established loop is:

1. Claude/agent writes the cocotb testbench in `sim/<interface>/test_<module>.py`. **The testbench is
   the spec** — it opens with a docstring giving the exact port list and rules.
2. Agent writes `rtl/<interface>/<module>.v` as a **skeleton**: ports, parameters and registers
   declared, with numbered `// TODO n:` comments describing each piece of behavior.
3. The user fills in the TODOs, runs the tests, and asks for review.
4. **Only fill in TODOs when the user explicitly asks for it** (later requests authorized complete
   FIFO, UART/BNO085 and Pi-link implementations). When you do, **keep the TODO comments in place** — the user
   asked for this specifically, so the file reads as explanation plus implementation.
5. Nothing is flashed to hardware before it passes in simulation.

Verify a new testbench before handing it over: write a reference implementation in a
scratchpad (never in `rtl/`), confirm the tests pass against it, then mutate the
reference to confirm the tests actually catch bugs. Delete the reference afterwards.

**Explanation style the user has asked for repeatedly:** explain from first principles,
assume little electrical background, define Verilog syntax as it appears, and use plain
analogies. They ask "explain me also" on almost every task — treat teaching as part of
the deliverable, not an extra.

## Repo

```
rtl/          Verilog modules
sim/          cocotb testbenches + Makefile + GTKWave save files
constraints/  arty_a7_100.xdc (pin map)
scripts/      build.tcl (synth→bitstream), program.tcl (JTAG flash)
```

Remote: `https://github.com/vismay5559/fpga_zeus` (branch `main`).

### Module status

| Module | Tests | Notes |
|---|---|---|
| `tick_gen` | 2/2 | one-cycle pulse every DIV clocks |
| `uart_tx` | 5/5 | 8N1, LSB first, valid/ready handshake, `CLKS_PER_BIT` timing |
| `uart_rx` | 6/6 | 2-flop sync, half-bit then full-bit sampling, false-start rejection, `frame_error` on a bad stop bit |
| `fifo_sync` | 8/8 | synchronous parameterized queue; complete implementation with explanatory TODOs retained |
| `uart_rx_fifo` | 5/5 | complete 3 Mbaud serial-bit → received-byte → queued-byte integration |
| `shtp_uart_deframer` | 10/10 | complete staged flag/escape decoder with validation, recovery and counters |
| `bno085_uart_rx` | 6/6 | real serial input through UART/FIFO/bridge to validated packets; loss recovery |
| `sh2_report_parser` | 7/7 | atomic SH-2 accel/gyro/rotation decode with timing, sequences and freshness |
| `bno085_imu_rx` | 2/2 | exact 3 Mbaud serial packets update retained raw IMU report banks |
| `bno085_uart_packet_tx` | 4/4 | framing, escaping, per-channel sequences and measured inter-byte gaps |
| `bno085_startup_controller` | 4/4 | BSN gating, exact profile, confirmation retry and reset reconfiguration |
| `bno085_imu` | 1/1 | physical bidirectional wire integration, report fanout and reset invalidation |
| `top` | — | blinky bring-up: LD4 toggles once per second, BTN0 resets. Separate from the IMU/contact Pi demo |
| `pi_link_demo_top` | 2/2 | BNO085 UART and two switches to immutable 640-byte Pi SPI snapshots |

Next for the IMU path: replay a real BNO085/STM32 capture and measure
sustained 400/400/100 delivery on hardware. The bench top already connects
`bno085_imu` to Arty JB1/JB2 and the 1 kHz Pi snapshot path. BNO085 requirements are in BNO085_PLAN.md. Other planned blocks: teammate-owned encoder SPI master + AS5047P readers,
CAN FD, production snapshot integration and motor safety.

### Conventions in the RTL

- `` `default_nettype none `` at the top, `wire` at the bottom.
- Synchronous active-high reset, everything in `always @(posedge clk)` with `<=`.
- One-cycle strobes (`valid`, `frame_error`) are assigned low at the top of the block
  and overridden later; last-assignment-wins gives the pulse.
- Any asynchronous input passes through a 2-flop synchronizer before use.
- Width discipline: compute in `localparam integer`, then narrow
  (`localparam [CW-1:0] LAST_CNT = LAST_I[CW-1:0];`). **`CLKS_PER_BIT[CW-1:0]` silently
  truncates** — this bug was already hit once (16 became 0 in 4 bits, breaking the
  half-bit wait). Run `verilator --lint-only -Wall` on every module; it is currently clean.
- Simulation shrinks parameters for speed (`CLKS_PER_BIT=16`, `DIV=10`), set per module
  via `COMPILE_ARGS` in `sim/Makefile`. Synthesis uses the real values.

## Environment (Ubuntu 24.04, dual boot, ~86 GB free at setup)

- **Vivado 2026.1**, Artix-7 only, at `/tools/Xilinx`, sourced from `~/.bashrc`.
  **Basic tier license** (free, node-locked to the laptop's NIC, renews annually):
  Vivado's own simulator and the ILA logic analyzer are restricted, which is why cocotb
  is the primary debugging tool.
- **Icarus Verilog 12, Verilator 5.020, GTKWave, cocotb 2.1** in a venv at `~/fpga/venv`
  (`source ~/fpga/venv/bin/activate` before any `make`).
- Build/flash without the GUI: `vivado -mode batch -source scripts/build.tcl`, then
  `program.tcl`. `write_cfgmem` to QSPI is the later step for surviving power-off.

### Three environment quirks that will bite

1. **ROS Jazzy is sourced in `~/.bashrc`** and puts its pytest plugins on the Python
   path; they crash cocotb. `sim/Makefile` sets `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`.
   Keep that in any new Makefile.
2. **VS Code is installed as a snap.** Its terminal exports snap library paths that make
   GTKWave fail with a `libpthread` symbol error, and its webviews have no WebGL, so the
   Surfer extension cannot start at all. `make TOP=<mod> view` works around it with
   `env -i`. The real fix, if the user ever wants Surfer: replace the snap with the .deb.
3. **Waveforms need `WAVES=1` at compile time.** If `sim_build/<mod>/` already exists,
   make will not recompile and no `.fst` appears. `rm -rf sim_build/<mod>` first.

## Commands

```bash
source ~/fpga/venv/bin/activate
cd sim
make TOP=uart_rx WAVES=1                          # compile + run tests + record waves
make TOP=uart_rx view                             # GTKWave (env -i workaround)
make TOP=uart_rx COCOTB_TESTCASE=single_bytes     # one test
verilator --lint-only -Wall rtl/uart/uart_rx.v         # from repo root
```

## Not in the repo, deliberately

The exported transcript of the original setup conversation (`Claude-*.md`, gitignored)
contains the laptop's MAC address, which is the Vivado license host ID, plus the
hostname. Keep it out of anything public.

## 2026-09-27 Pi-link and team update

User confirmed ten actuators and that teammate owns encoder SPI master only.
RTL/tests now live in common/uart/imu/pi_link/spi/can/gpio/top groups. Shared
Makefile and Vivado scripts discover one-level interface directories. Root docs
remain for continuity. See docs/TEAM_WORKFLOW.md for ownership and handshakes.

Pi link implements 640-byte ZFP1 v1 snapshot framing/CRC, a read-only SPI mode0
slave, partial-read rewind, single in-flight frame and counted dropped snapshots.
cycle_timer provides 1 kHz sample + 64-bit microseconds. Pi decoder/reader live in
pi/. Packet fields/offsets are in docs/PI_LINK_PROTOCOL.md. pi_link_demo_top sends
live IMU and foot contacts with TEST_MODE set; encoder/CAN payload mapping,
Pi InEKF adapter and motor-command/gains/watchdog integration remain.

Build default blinky: scripts/build.tcl -> build/top/top.bit. Demo: pass
-tclargs pi_link_demo_top constraints/arty_a7_100_pi_demo.xdc. Programming script
accepts the explicit bitstream path. See docs/ARTY_A7_BRINGUP.md for wiring and
commands. No physical programming has been performed by this task.

## 2026-09-28 foot-switch update

`rtl/gpio/foot_switches.v` implements two active-low center-sole contacts with 2-flop input
synchronizers and 1 kHz-sampled independent 3-tick make / 8-tick break debounce.
Those thresholds and bit order match current `stm32_zeuss` contact.c at commit df59973.
Outputs: debounced switch/foot bits, per-foot confirmation timestamps, latest
change timestamp, event pulses, and per-foot saturating stable age. Four focused
cocotb tests pass. The Arty Pi demo now uses JD1-2 for switch-to-ground inputs
with requested pull-ups, LED1/LED2 for left/right feet, and packs live contacts
into bytes464..479 of the ZFP1 snapshot. Bit-level top/Pi decoder integration
passes; see docs/FOOT_SWITCHES.md. IMU-to-Pi integration now lives in the bench top; encoder/CAN integration remains.
