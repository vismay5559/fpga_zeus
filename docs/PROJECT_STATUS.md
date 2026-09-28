# Project status — 2026-09-28

This is the current source of truth for what `fpga_zeus` can do. The goal is an Arty A7-100T hardware-interface FPGA that gathers BNO085 IMU data, four AS5047P spring encoders, two center-sole switches, and ten ODrive axes on two CAN buses, then makes timestamped sensor snapshots available to a Raspberry Pi. The Pi handles scaling, fusion and high-level policy. The 1 kHz snapshot is a telemetry schedule, **not a contact-to-motor response deadline**.

**Today:** the UART/IMU host, 1 kHz timer, foot-switch input, packet builder, read-only Pi SPI slave and Pi decoder are implemented and simulated as modules. A routed **bench demo** joins the timer, BNO085 UART host, switches and Pi link. It publishes real IMU and switch records in simulation; encoder and CAN fields remain invalid placeholders. There is no complete robot top and no physical-board result in this repo.

| Area | What exists and has been checked | What is still missing |
|---|---|---|
| UART transport | TX/RX, synchronous FIFO, RX/FIFO bridge and SHTP-over-UART recovery; cocotb tests include an independent 3 Mbaud sender | Real sensor electrical and throughput checks |
| BNO085 | Bidirectional UART-SHTP host, SH-2 accel/gyro/Rotation Vector decoding, raw fixed-point registers, timestamps/freshness, BSQ/BSN flow control and simulated startup for 400/400/100 Hz | Replay a real capture, bench-test JB UART wiring, and measure actual sustained sensor rates |
| Foot contacts | Two synchronized, active-low center-sole inputs; 3 consecutive 1 kHz samples confirm make and 8 confirm break; masks, ages, change times and tests | Validate switch behavior on the actual sole and harness; a future fast contact-to-CAN path is **not implemented** |
| Timing and Pi packet | 100 MHz-derived microsecond counter and 1 kHz strobe; 640-byte ZFP1 packet, atomic capture, CRC, sequence/drop counts and read-only SPI slave; Python decoder/reader and integration tests | Assemble live encoder/CAN records and measure sustained Pi throughput on hardware |
| Encoder SPI master | Folder and interface ownership assigned to teammate | AS5047P reader, four measured angles, fault handling and production integration are not in this repo yet |
| CAN FD | Folder and proposed CTU CAN FD approach | Controller integration, two physical buses, ten-axis register table, live telemetry and any motor TX path |
| Board | Vivado-routed IMU/contact/Pi **demo** bitstream and Arty constraints | Flash and bench-test the board; production pin map/top, transceivers, sensors and ODrives |
| Motor commands and estimator | ZFP1 reserves fields for targets/diagnostics; Pi protocol defines ten actuator slots | No Pi-to-FPGA command receiver, arbitration policy, watchdog, active-backdriving override, or Pi InEKF adapter |

The current STM32 NEXUS packet contains eight active leg joints and floats; ZFP1 defines **ten** actuator slots and integer IMU values. They are not byte-compatible. The BNO085 Rotation Vector is for comparison with the project's own fusion, not an input to that fusion. See [PI_LINK_PROTOCOL.md](PI_LINK_PROTOCOL.md) and [BNO085_PLAN.md](../BNO085_PLAN.md) for exact formats and rates.

## What the 1 kHz claim means

[`cycle_timer`](../rtl/common/cycle_timer.v) produces one sample pulse every 1,000 µs. The bench top captures the current IMU and contact state and asks [`pi_link`](../rtl/pi_link/pi_link.v) to prepare a packet each pulse. The link holds **one immutable 640-byte packet** until the Pi finishes reading it. If it is still busy at the next pulse, that attempted snapshot is counted as dropped. At 10 MHz, 640 SPI bytes take at least 512 µs on the wire; at 1 MHz they take 5.12 ms, before Linux scheduling or chip-select overhead. Therefore the design **attempts 1,000 snapshots/s**, but this repo does not claim the Pi receives every one. Sequence gaps and the FPGA drop counter make misses visible.

The foot contacts in that packet use the current 1 kHz, 3/8-sample confirmation policy. This path is for reporting. A contact-triggered motor command within 1 ms will require an independent, faster detector and direct CAN priority path; no such command has been chosen or implemented. This work is deliberately deferred by the user.

## Verification boundary

The latest complete run passed **79 cocotb tests and 5 Python protocol tests**; Verilator `-Wall` passed for the IMU/contact top. Vivado 2026.1 routed the Arty demo at 100 MHz with setup WNS **+0.156 ns**, hold WHS **+0.035 ns**, zero failing endpoints and zero DRC violations; see [PI_LINK_VERIFICATION.md](PI_LINK_VERIFICATION.md). The 128-byte UART packet bound reduces the receive/parse logic enough to meet timing, but the setup margin is narrow. These are simulation and implementation checks, **not** measured sensor rates, Pi throughput, switch electrical behavior, CAN operation, or motor response on a robot. Generated `build/` bitstreams are local artifacts and are not committed to GitHub.

## Next work, in dependency order

1. Merge the teammate's encoder SPI master and validate four AS5047P readings with the actual wiring.
2. Integrate and test two CAN FD interfaces, CAN telemetry decoding, ten-axis retained state and error/age tracking.
3. Extend the current IMU/contact Arty demo into a **production** top by joining encoders and CAN to the existing timer and Pi packet. Set validity only for real data; keep the current read-only Pi link until command behavior is designed.
4. Bench-test real BNO085 400/400/100 Hz delivery, Pi packet rate and drops, switch electrical/gait behavior, encoder error paths and CAN bus load. Compare FPGA output with the STM32 while accounting for format differences.
5. Build Pi-side scaling/fusion integration and, later, the command receiver, motor safety policy and fast contact-triggered CAN response after the exact command is decided.

For the field mapping, see [IMU_TO_PI.md](IMU_TO_PI.md). For a beginner-level explanation of how the implemented blocks connect, read [SYSTEM_WALKTHROUGH.md](SYSTEM_WALKTHROUGH.md). For a board procedure, read [ARTY_A7_BRINGUP.md](ARTY_A7_BRINGUP.md).
