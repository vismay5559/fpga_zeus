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
