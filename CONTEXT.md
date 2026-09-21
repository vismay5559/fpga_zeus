# Context handoff

Everything an agent needs to continue this project without the prior conversation.
Written 2026-09-20. Companion files: [README.md](README.md) (what/how), [ROADMAP.md](ROADMAP.md) (schedule).

Update 2026-09-22: [BNO085_PLAN.md](BNO085_PLAN.md) records verified SH-2
formats, pinned STM32 configuration, rate caveats and future recovery/freshness
tests. FIFO testbench and six-TODO skeleton are ready; the user implements RTL.
See [sim/FIFO_EXERCISE.md](sim/FIFO_EXERCISE.md) for instructions and verification.
New UART tests pass at 100 MHz/divider 33 against independent 3 Mbaud input.
FPGA startup requests accel/gyro 400 Hz and Rotation Vector 100 Hz, matching the
inspected STM32 source, with 120 us TX byte spacing; physical rates need measurement.
FPGA is the sole sensor host. It stores signed integers
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

Hard deadline: **every sensor read by the FPGA on 2026-10-15.**

### Hardware being absorbed

| Interface | Devices | Details |
|---|---|---|
| CAN FD ×2 buses | 5 ODrive S1 each (10 axes) | 1 Mbit nominal / 5 Mbit data, ISO1042 transceivers |
| SPI master ×4 | AS5047P encoders | after-spring position, hip + knee SEAs, both legs |
| GPIO ×4 | foot switches | heel + toe per foot |
| UART | BNO085 IMU | SHTP framing at 3 Mbaud |
| SPI slave | Raspberry Pi | snapshot out / commands in, plus a data-ready GPIO |

An RS485 BMS link exists on the robot and was in an earlier plan, but is out of scope
for the Oct 15 goal.

### Decisions already made (do not relitigate)

- **Board: Arty A7-100T** (`xc7a100tcsg324-1`), pure FPGA, no hard CPU. Chosen over a
  Zynq to learn RTL, with room for two CAN FD cores plus a soft core or HLS block later.
  **The board has not physically arrived yet** — everything so far is simulation only.
- **CAN FD: integrate the open-source CTU CAN FD core (VHDL)** rather than writing one.
  Needs GHDL for simulation; Vivado handles mixed-language synthesis. Do not suggest
  external CAN controller chips (e.g. MCP2518FD) — that was considered and rejected.
- **BNO085 runs UART-SHTP, not UART-RVC.**
- **Pi link is SPI with the FPGA as slave**, plus a data-ready line, keeping the frame
  layout compatible with what the STM32 sends today so Pi-side code barely changes.
- **No soft core for now.** The Pi configures peripherals at startup through the
  register map; the FPGA does per-cycle work in pure hardware.

## How work is done here

**Test-first, and the human writes the RTL.** The user is a robotics engineer who is new
to Verilog and is deliberately learning it. The established loop is:

1. Claude/agent writes the cocotb testbench in `sim/test_<module>.py`. **The testbench is
   the spec** — it opens with a docstring giving the exact port list and rules.
2. Agent writes `rtl/<module>.v` as a **skeleton**: ports, parameters and registers
   declared, with numbered `// TODO n:` comments describing each piece of behavior.
3. The user fills in the TODOs, runs the tests, and asks for review.
4. **Only fill in TODOs when the user explicitly asks for it** (they have, for
   `uart_tx` and `uart_rx`). When you do, **keep the TODO comments in place** — the user
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

Remote: `https://github.com/vismay5559/fpga_zeus` (branch `main`). Push after each
module passes. Commits are co-authored with Claude per the user's setup.

### Module status

| Module | Tests | Notes |
|---|---|---|
| `tick_gen` | 2/2 | one-cycle pulse every DIV clocks |
| `uart_tx` | 5/5 | 8N1, LSB first, valid/ready handshake, `CLKS_PER_BIT` timing |
| `uart_rx` | 6/6 | 2-flop sync, half-bit then full-bit sampling, false-start rejection, `frame_error` on a bad stop bit |
| `top` | — | blinky bring-up: LD4 at 1 Hz, BTN0 resets. `uart_*` are not wired into it yet |

Next: user implements `fifo_sync` TODOs; eight tests were verified with a temporary
reference at four parameter settings and 13 mutations. BNO085 requirements are
in BNO085_PLAN.md. Other planned blocks: `debounce` + foot switches, then `cycle_timer`
(the 1 kHz global sample strobe), then SPI master + AS5047P readers.

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
verilator --lint-only -Wall rtl/uart_rx.v         # from repo root
```

## Not in the repo, deliberately

The exported transcript of the original setup conversation (`Claude-*.md`, gitignored)
contains the laptop's MAC address, which is the Vivado license host ID, plus the
hostname. Keep it out of anything public.
