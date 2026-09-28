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
The STM32-compatible policy adapter, live sensor payload integration, command
receiver and hardware motor watchdog are still future integration work.

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
