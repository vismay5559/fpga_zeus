# Agent handoff: fpga_zeus

**Last reviewed:** 2026-09-29. **Repository:** `vismay5559/fpga_zeus`, local checkout
`~/fpga/biped-fpga`, target branch `main`. This file is the entry point for a
new agent. It describes the repository as it stood after commit `0bf197b`;
check `git status`, the latest commit, and the linked source files before treating
any dated result as current. Read [PROJECT_STATUS.md](docs/PROJECT_STATUS.md) for
the implementation boundary, [ROADMAP.md](ROADMAP.md) for ordered work, and
[PI_LINK_PROTOCOL.md](docs/PI_LINK_PROTOCOL.md) before changing packet fields.
[CONTEXT.md](CONTEXT.md) has detailed history, including plans that became stale.

## Purpose and ownership

The user is building a biped robot and learning Verilog. The current robot uses
[STM32 firmware](https://github.com/vismay5559/stm32_zeuss) for the BNO085, spring
encoders, foot switches, CAN/ODrives, a 1 kHz control loop, sensor fusion, and a
USB link to a Raspberry Pi. This repository explores moving the hardware-interface
layer to a Digilent **Arty A7-100T** (`xc7a100tcsg324-1`, 100 MHz). The Pi remains
the high-level compute host. The FPGA is intended to acquire time-aligned sensor
state and eventually support ten ODrive axes across two CAN buses.

The user wants plain, beginner-friendly explanations alongside code. Explain the
physical signal, the Verilog state/register behavior, what Python drives and
asserts, and the practical limit of a passing simulation. They have repeatedly
asked for complete implementations when moving beyond an exercise; follow the
latest request instead of assuming every new file must be a skeleton. Keep
numbered TODO comments when implementing an existing TODO-based module.

The encoder SPI master is teammate-owned (`rtl/spi`, `sim/spi`). The Pi-facing SPI
slave is a different interface and lives in `rtl/pi_link`. Coordinate pin and
packet changes with teammates; see [TEAM_WORKFLOW.md](docs/TEAM_WORKFLOW.md).

## Fixed user decisions and open choices

- **BNO085:** UART-SHTP at 3 Mbaud, not UART-RVC. Request calibrated
  accelerometer report `0x01` at **400 Hz** (m/s², gravity included), calibrated
  gyro `0x02` at **400 Hz** (rad/s), and Rotation Vector `0x05` at **100 Hz**.
  The quaternion is a comparison reference, **not** an InEKF input. Match the
  pinned STM32 configuration before trying alternative rates. The user's minimum
  desired delivered acceleration and gyro rates are above 250 Hz; requested rate
  alone does not prove delivery. See [BNO085_PLAN.md](BNO085_PLAN.md).
- **IMU representation:** Keep signed SH-2 integers and Q points on the FPGA:
  acceleration Q8, gyro Q9, quaternion Q14, accuracy Q12. Scale on the Pi; do
  not silently add FPGA floating point or remove gravity. Preserve per-report
  validity, freshness, sequence, timestamp, status, and error diagnostics.
- **Foot contact:** one center-sole switch **per leg** in this FPGA design. The
  present telemetry filter confirms a press after three 1 kHz samples and a
  release after eight. These are changeable debounce settings, not a fast
  contact-to-motor path. Current STM32 source/documentation still contains
  four toe/heel channels in places; do not let that overwrite this explicit
  FPGA requirement without a new user decision.
- **Actuators:** keep **ten** ZFP1 slots, including waist roll/pitch, even
  though the pinned STM32 NEXUS packet currently carries eight leg joints.
  ZFP1 is deliberately not byte-compatible with STM32 NEXUS.
- **CAN:** two buses with five ODrive axes each are the target. The selected
  direction is the open-source CTU CAN FD core, with board transceivers; CAN RTL
  and motor TX are **not** implemented here. Do not infer motor readiness from
  the packet's reserved actuator fields.
- **Motor override:** the user has explicitly **deferred** the contact-triggered
  torque/backdriving command until its exact behavior is chosen. They ultimately
  want contact-to-command under 1 ms; that needs a separate fast sensing and CAN
  path, not the 1 kHz snapshot or the current 3/8-sample telemetry filter.
- **Fusion location:** no InEKF exists in this FPGA repository. The user is
  considering whether full onboard FPGA fusion would beat the STM32, but has
  not decided to port it. The STM32 is the reference implementation. Measure
  sensor-arrival, fusion-ready, and Pi-receipt latency before promising a gain.

## What actually works now

The **bench top** [`rtl/top/pi_link_demo_top.v`](rtl/top/pi_link_demo_top.v) joins
`cycle_timer`, the bidirectional `bno085_imu` UART host, two foot switches, and
the read-only Pi SPI link. It requests the 400/400/100 IMU profile, packs live
IMU/contact records into a 640-byte ZFP1 snapshot every nominal millisecond,
and leaves encoder/CAN/actuator data invalid. `TEST_MODE` remains set. This is
**not a complete robot top**. [`rtl/top/top.v`](rtl/top/top.v) is a separate LED
blinky design.

Data path:

```text
BNO085 UART TX -> FPGA RX/FIFO -> UART-SHTP deframer -> SH-2 report parser
  -> retained raw IMU registers --+
center-sole switches -> sync/debounce --+-> 1 kHz ZFP1 capture + CRC
                                    -> Pi SPI slave -> Pi decoder/reader
```

The FPGA also transmits BNO085 startup commands, observes UART buffer-status
flow control, uses a 120 µs gap between transmitted wire bytes, checks feature
confirmations, and reconfigures after validated sensor reset notices. The Arty
demo limits incoming UART-SHTP packets to **128 bytes** for 100 MHz timing;
`oversize_errors` counts longer frames. This limit has **not** been validated
against a sustained real-sensor capture. UART-SHTP has no checksum; structural
validation and resynchronization cannot detect every plausible corrupted value.
See [BNO085_PLAN.md](BNO085_PLAN.md) and [IMU_TO_PI.md](docs/IMU_TO_PI.md).

ZFP1 is a **640-byte, little-endian, version-1 read-only SPI** packet. The IMU
records begin at bytes 32/72/112, ten actuator slots at 152, four encoder slots
at 432, contacts at 464, diagnostics at 480, and CRC16 at 638. The packet
builder keeps one immutable frame in flight. A new 1 kHz attempt while it is
busy increments the drop counter; the Pi must check sequence gaps and drops.
At 10 MHz, 640 SPI bytes take at least **512 µs** on the wire; actual 1,000
packets/s reaching Linux has not been measured. The Pi decodes with
[`pi/fpga_protocol.py`](pi/fpga_protocol.py) and can bench-read with
[`pi/read_spi.py`](pi/read_spi.py). No Pi-to-FPGA command channel exists.

The current top-level pin assignment is Arty JA1-4 for Pi SCK/CS/MISO/ready,
JD1/JD2 for left/right switches, and JB1/JB2 for sensor TX-to-`imu_rx` and
`imu_tx`-to-sensor RX. Use the exact table, grounding, and voltage checks in
[ARTY_A7_BRINGUP.md](docs/ARTY_A7_BRINGUP.md); the pins are not a production
allocation. The FPGA is the sole BNO085 host in this design. A side-by-side
comparison with STM32 needs controlled host switching or replay of the same
captured stream, not two hosts driving the same sensor UART RX at once.

## Evidence and limits

As recorded on 2026-09-28, the full regression passed **79 cocotb cases plus
5 Python protocol tests**. The bit-level top test sends BNO085 serial reports,
reads a complete Pi SPI packet, and checks values, Q points, metadata, freshness
and reset invalidation. Verilator `-Wall` passed. Vivado 2026.1 routed the IMU/
contact bench top for the A7-100T at 100 MHz: setup WNS **+0.156 ns**, hold WHS
**+0.035 ns**, zero failing endpoints and zero DRC violations; a local bitstream
was generated. Setup margin is narrow. These are simulation and implementation
results, **not** a programmed-board or real-sensor result. Generated `build/`
files and bitstreams are ignored by Git. Full evidence is in
[PI_LINK_VERIFICATION.md](docs/PI_LINK_VERIFICATION.md).

The pinned STM32 baseline is commit
[`df599732`](https://github.com/vismay5559/stm32_zeuss/tree/df5997328c2a5b9c37e39b1dd1c82d6919ba5887).
Its IMU setup requests 400/400/100, but historical hardware notes report the
accelerometer substantially below 400 Hz under some configurations. Its documentation reports about 230 µs for a 1 kHz loop with fusion, but
the latest four-contact worst case is not yet board-measured. A full FPGA fusion
port has no demonstrated end-to-end latency benefit yet. Its packet uses floats,
includes estimator output, and has eight active joints. Compare
physical values and event timing after scaling/reordering, never raw packet
bytes. Refresh that repository before relying on claims about its current `main`.

## Next work and how to run it

Follow [ROADMAP.md](ROADMAP.md): integrate the teammate's four AS5047P encoder
readings; add and test two CAN FD buses and ten-axis retained state; assemble
real encoder/CAN fields in a production top; bring up the BNO085 and Pi link on
hardware; then build the Pi adapter. Real BNO085 report-rate measurement and a
common STM32/FPGA capture comparison are especially important before moving
fusion. Command reception, safety arbitration, and the fast contact-triggered
CAN action remain separate later decisions.

```bash
cd ~/fpga/biped-fpga
source ~/fpga/venv/bin/activate
python scripts/run_tests.py
make -C sim TOP=pi_link_demo_top
vivado -mode batch -source scripts/build.tcl -tclargs pi_link_demo_top constraints/arty_a7_100_pi_demo.xdc
```

The complete regression runs cocotb suites sequentially because they share
`sim/results.xml`. `sim/Makefile` shortens simulation timing parameters; the
Vivado build uses hardware defaults. For a real board, follow
[ARTY_A7_BRINGUP.md](docs/ARTY_A7_BRINGUP.md) before running
`scripts/program.tcl`; JTAG loading is volatile. Do not report a passing test
or a generated `.bit` as a successful hardware flash.

When changing RTL, write a meaningful cocotb behavior test first, include error
and recovery cases, run focused tests and then the full regression, lint the
changed hierarchy, and route the board top when timing/resource behavior can
change. The historical [CONTEXT.md](CONTEXT.md) describes the user's preferred
TODO-based teaching workflow. Update this handoff, status, protocol and
verification notes whenever the implementation boundary changes. Keep claimed
measurements separate from design targets and simulations.
