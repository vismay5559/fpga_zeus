# fpga_zeus

FPGA hardware-interface project for a bipedal robot. **Current board target: Digilent Zybo Z7-20** (Zynq-7020, `xc7z020clg400-1`). The previous Arty A7-100T target remains as a legacy build. The Raspberry Pi is intended to receive timestamped sensor snapshots and run scaling, fusion and higher-level policy.

**Current boundary:** UART/BNO085 modules, the 1 kHz timer, two foot-switch inputs and a read-only Pi SPI link have simulation coverage. The **Zybo bench demo** wraps the existing 100 MHz IMU/contact/Pi logic with a 125-to-100 MHz MMCM and new pin map; its encoder/CAN data remain invalid. The Zybo build has **not yet been routed or tested on hardware**. It is not a complete robot top. The Pi-to-FPGA motor-command path and contact-triggered torque override have not been implemented.

- [Agent handoff: read this first](AGENT_HANDOFF.md) — current design, decisions, limits, and next steps.
- [What works, what is missing, and the next steps](docs/PROJECT_STATUS.md) — current status source of truth.
- [Zybo Z7-20 power, wiring, build and first IMU test](docs/ZYBO_Z7_20_BRINGUP.md).
- [How the implemented system works, from basics](docs/SYSTEM_WALKTHROUGH.md) — modules, tests and data flow.
- [Prioritized work plan](ROADMAP.md) and [project handoff/history](CONTEXT.md).

## Target and ownership

| Interface | Target | Current state |
|---|---|---|
| BNO085 UART-SHTP | calibrated acceleration and gyro at 400 Hz, reference quaternion at 100 Hz | UART/IMU host wired into the Pi demo and serial-to-Pi simulation tested; real sensor rates not measured |
| Foot GPIO | one center-sole switch per foot | simulated and connected to Pi bench demo; sampled at 1 kHz with 3/8-sample debounce |
| AS5047P SPI master | four spring encoders | teammate-owned; implementation not yet in this repository |
| CAN FD ×2 | ten ODrive S1 axes | not implemented |
| Pi-facing SPI slave | 640-byte ZFP1 snapshot, attempted every 1 ms | packet/SPI path simulated; bench demo contains live IMU and contacts |
| Motor commands | future Pi commands and local contact-triggered override | deferred; exact torque behavior is not decided |

The 1 kHz snapshot is a **reporting schedule**, not a sub-millisecond motor-response path. The link has one in-flight packet and counts dropped snapshot attempts when the Pi reads too slowly. Ten actuator slots are reserved even though the current STM32 NEXUS packet carries eight leg joints. See [the packet specification](docs/PI_LINK_PROTOCOL.md).

## Repository map

```text
rtl/common/   timer, tick, FIFO       rtl/uart/     generic serial transport
rtl/imu/      BNO085 host             rtl/gpio/     two center-sole inputs
rtl/pi_link/  packet and Pi SPI slave rtl/top/      Zybo wrappers and legacy Arty tops
rtl/spi/      encoder SPI ownership   rtl/can/      CAN ownership (no RTL yet)
sim/          matching cocotb suites, waveforms and Makefile
pi/           ZFP1 decoder and bench SPI reader
docs/         status, walkthrough, protocol, verification and board guides
constraints/  Zybo Z7-20 and legacy Arty pin/timing constraints
scripts/      regression, mutation, Vivado build and programming scripts
```

## Verify and build

From the repository root:

```bash
source ~/fpga/venv/bin/activate
python scripts/run_tests.py
make -C sim TOP=foot_switches
make -C sim TOP=pi_link_demo_top
vivado -mode batch -source scripts/build.tcl  # Zybo Z7-20 LED blink
vivado -mode batch -source scripts/build.tcl -tclargs zybo_z7_20_imu_top
vivado -mode batch -source scripts/build.tcl -tclargs zybo_z7_20_demo_top
```

The builds write bitstreams under `build/<top>/` locally; generated artifacts are ignored by Git. Follow [ZYBO_Z7_20_BRINGUP.md](docs/ZYBO_Z7_20_BRINGUP.md) for wiring and programming. The most recent recorded **Arty** tests and routed timing are in [PI_LINK_VERIFICATION.md](docs/PI_LINK_VERIFICATION.md); they do not validate the new board. The old [Arty guide](docs/ARTY_A7_BRINGUP.md) remains for legacy use. Other focused explanations: [foot switches](docs/FOOT_SWITCHES.md), [IMU-to-Pi mapping](docs/IMU_TO_PI.md), [UART/BNO085](UART_BNO085_WALKTHROUGH.md), [BNO085 requirements](BNO085_PLAN.md), [FIFO](sim/FIFO_EXERCISE.md), [team ownership](docs/TEAM_WORKFLOW.md), and [checked-in UART waveform](sim/waves/README.md).
