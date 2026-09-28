# Pi link verification, 2026-09-27

This records local verification, not a physical-board result.

- Full reorganized regression: 77 cocotb test executions passed, including the
  UART exact-baud sweep and both BNO085 TX gap settings; 4 Python protocol tests passed.
- Final Pi SPI integration rerun after decoder validation updates: 2/2 passed.
- Packet tests compare exact bytes and CRC, immutable data under stalls, counted
  dropped snapshots, sequence gaps, rewind, and reset. SPI tests exercise 5/10 MHz
  clocks, empty reads, and aborts after 1, 7, 8, 9, 77 and 5119 bits.
- Scratch reference outside rtl passed packet tests. Changing the CRC polynomial,
  ignoring output stalls, or ignoring rewind each made the tests fail. Temporary
  reference implementations were deleted; real RTL was never mutated.
- Verilator -Wall passed for the Pi demo hierarchy and relocated BNO085 hierarchy.
- Vivado 2026.1 routed pi_link_demo_top for xc7a100tcsg324-1 at 100 MHz. Setup WNS
  +3.163 ns; hold WHS +0.051 ns; zero failing endpoints and zero DRC violations.
  The LED is intentionally not externally timed. SPI max-delay constraints cover
  internal output budgets; board/controller/wire timing remains a bench check.
- Demo utilization: 188 LUTs, 359 flip-flops. Its zero sensor payload is optimized
  away, so these are NOT resource figures for the generic packet or full robot.

Reproduce after activating ~/fpga/venv:

```bash
python scripts/run_tests.py
python scripts/check_pi_mutations.py
vivado -mode batch -source scripts/build.tcl -tclargs pi_link_demo_top constraints/arty_a7_100_pi_demo.xdc
```

Generated logs/reports/bitstreams live under build/ and are ignored by Git.
The source, tests, constraints and build instructions are versioned. No board was
programmed in this task, and sustained Pi throughput is not hardware-verified.
The STM32-compatible Pi policy adapter, live encoder/CAN payload assembly,
command receiver and hardware motor watchdog remain future integration work.

## 2026-09-28 foot-contact extension

The demo now includes live foot switches; its 2026-09-27 utilization figures above
apply only to the earlier all-invalid snapshot. The complete regression passed:
78 cocotb tests and 4 Pi protocol unit tests. This includes four focused GPIO
tests and one board-top switch-to-SPI-to-Pi decoder test. A scratch reference
passed; changing the make threshold, break threshold, or left/right foot
bit order separately made the GPIO tests fail. Scratch RTL was deleted after each run.

Vivado 2026.1 routed the updated `pi_link_demo_top` for xc7a100tcsg324-1 at
100 MHz: setup WNS +3.097 ns, hold WHS +0.053 ns, zero failing endpoints, zero
DRC violations. The routed demo uses 292 LUTs and 586 flip-flops. Its switch
inputs D4/D3 have `PULLUP` in the IO report. The bitstream is at
`build/pi_link_demo_top/pi_link_demo_top.bit`. These are demo resources with
IMU/encoder/CAN data still constant; no switch hardware was exercised here.

Reproduce the new fault check with `python scripts/check_foot_mutations.py`.

## 2026-09-28 center-sole correction

The newer STM32 `main` at commit `df59973` uses one center-sole switch per
foot. The GPIO block, Pi demo, Arty XDC, and protocol docs were corrected from
the preceding four-switch revision. The ZFP1 record still occupies 16 bytes;
its switch and foot masks now contain identical left/right bits 0/1, with high
bits zero. The Pi decoder rejects a contacts-present packet with old high bits
or disagreeing masks.

The complete regression passed again: 78 cocotb tests and 5 Pi protocol tests.
All four GPIO tests and the bit-level board-top/Pi-decoder test passed. Scratch
mutations of the make threshold, break threshold, and left/right bit order were
each detected. Verilator `-Wall` passed for the changed top hierarchy.

Vivado 2026.1 routed the corrected A7-100T demo at 100 MHz with setup WNS
+2.255 ns, hold WHS +0.046 ns, zero failing endpoints, and zero DRC violations.
Utilization is 252 LUTs and 568 flip-flops. The routed IO report assigns D4
(left) and D3 (right) as LVCMOS33 inputs with pull-ups; no third or fourth switch
input is assigned. Bitstream generation completed at
`build/pi_link_demo_top/pi_link_demo_top.bit`. This was not flashed to a board;
electrical switch behavior and gait-dependent contact reliability remain bench
tests.

## 2026-09-28 BNO085-to-Pi integration

The Arty bench top now connects `bno085_imu` UART RX/TX on JB1/JB2 to three
40-byte ZFP1 IMU records, IMU diagnostics, and the existing contact snapshot.
It requests the STM32-matching 400 Hz acceleration, 400 Hz gyro and 100 Hz
Rotation Vector profile. The Pi reader prints scaled values and key IMU health
fields. Encoder and CAN fields are still invalid placeholders.

The new bit-level top test sends signed acceleration, gyro and Rotation Vector
reports through the physical UART model, clocks a full SPI packet, and decodes
it with the actual Pi parser. It checks raw integers and Q points, sequences,
timestamps, retained values with `new=false` after silence, and reset
invalidation. The test was added first and failed against the old contacts-only
top. The final full regression passed **79 cocotb cases and 5 Python protocol
tests**; the top suite passed 2/2 with the final 128-byte packet parameter.
Verilator `--lint-only -Wall` passed for the complete top hierarchy.

A first 512-byte receive-buffer build was stopped after routing remained
congested and showed negative intermediate setup timing. The Arty top now
limits UART-SHTP packets to 128 bytes; larger frames increment `oversize_errors`
and are discarded until the next delimiter. The first 128-byte route missed
setup by 0.045 ns on the startup controller's advertisement timeout read.
Separating tag validation and timeout-byte reads by one clock removed that
critical path; the startup, top and complete regression suites passed again.

Vivado 2026.1 routed `pi_link_demo_top` for `xc7a100tcsg324-1` at 100 MHz:
setup WNS **+0.156 ns**, hold WHS **+0.035 ns**, zero failing endpoints, and
zero DRC violations. The design uses **8,029 LUTs and 7,803 flip-flops**. The IO
report confirms `imu_rx` at E15 with pull-up and `imu_tx` at E16, both LVCMOS33.
`build/pi_link_demo_top/pi_link_demo_top.bit` was generated locally and is
ignored by Git. Setup margin is narrow; the 128-byte limit and actual 400/400/100
delivery must be checked with a real BNO085 before calling this hardware ready.
No board was programmed in this verification.
