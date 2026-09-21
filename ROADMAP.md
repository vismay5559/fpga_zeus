# Roadmap: every sensor read on the FPGA by Oct 15, 2026

Scope: 2× CAN FD (10 ODrive S1), 4× AS5047P spring encoders (SPI), 4 foot switches,
BNO085 (UART-SHTP, 3 Mbaud), all latched into one snapshot that the Pi reads.
Out of scope for now: sensor fusion (InEKF), RS485 BMS, motor commands beyond a test joint.

Rule: every block passes cocotb tests before it goes near hardware.
Workflow: the test file is the spec, you write the RTL, then review.

## Week 1: Sep 17–23 · UART, FIFO, foot switches
- [ ] `uart_tx`: 5/5 tests passing
- [ ] `uart_rx`: 2-flop sync, mid-bit sampling, framing error; loopback tests with ±2% baud error
- [ ] `fifo_sync` RTL: user exercise; tests verified against reference and 13 mutations (see `sim/FIFO_EXERCISE.md`)
- [x] UART RX timing: 100 MHz/divider 33 versus independent 3 Mbaud and +/-100 ppm sender, all bytes/four phases
- [ ] `debounce` + `foot_switches`: 4 inputs → synced, debounced, change timestamp
- [ ] `cycle_timer`: 1 kHz `sample` strobe + free-running µs timestamp counter
- Done when: TX→FIFO→RX loopback is clean at 32 clks/bit; switch tests cover bounce and glitches.

## Week 2: Sep 24–30 · CDC + AS5047P encoders
- [ ] CDC: level sync, pulse sync, async FIFO (Gray pointers)
- [ ] `spi_master`: CPOL/CPHA, 16-bit frames, clock divider, MISO sample delay
- [ ] `as5047p_reader` ×4, all started by the same `sample` strobe
  - Mode 1 (CPOL=0, CPHA=1), MSB first, SCK ≤ 10 MHz, CSn high ≥ 350 ns between frames
  - Send `0xFFFF` (read ANGLECOM 0x3FFF, parity bit set). The reply lags one frame, so
    repeating the same read returns an angle every frame after the first.
  - Reply: bit15 = even parity, bit14 = error flag, bits13:0 = angle
  - Outputs: angle, valid, timestamp, parity/EF error counters, "N bad reads in a row" fault
- [ ] cocotb AS5047P model: known angles, injected parity/EF errors, cable delay
- Done when: all 4 encoders update in the same cycle in sim; bad frames never show up as valid.

## Week 3: Oct 1–7 · BNO085 (UART-SHTP)
Detailed contract and named acceptance tests: [BNO085_PLAN.md](BNO085_PLAN.md).
FPGA startup requests acceleration/gyro at 400 Hz, Rotation Vector at 100 Hz, with a
120 us TX byte gap. Actual acceleration and gyro must each exceed 250 Hz on hardware.

- [ ] SHTP-over-UART deframer (flag/escape bytes from the BNO08x datasheet)
- [ ] SHTP header parser (length, channel, sequence number)
- [ ] Report parsers: accelerometer, gyro, rotation vector → Q-format registers + timestamp
- [ ] Startup FSM + command ROM: reset, wait for advertisement, Set Feature per report
- [ ] FPGA startup: wait for advertisement, configure the 400/400/100 profile and confirm intervals
- [ ] Parameterized TX byte gap, buffer-status control, timestamps/freshness and error counters/tests per BNO085_PLAN
- [ ] Replay real frames captured from the STM32 setup in cocotb
- Done when: replayed captures decode to the same values the STM32 reports.

## Week 4: Oct 8–14 · CAN FD (CTU CAN FD core)
- [ ] GHDL install; CTU CAN FD core simulated standalone in cocotb
- [ ] Register-bus bridge to the core; bit timing for 1 M / 5 M at the system clock; TDC for ISO1042
- [ ] RX filter → per-axis state table (position, velocity, errors, heartbeat age) ×10
- [ ] Two instances; heartbeat timeout flags
- [ ] (If the board has arrived) FPGA ↔ STM32 on a bench bus, then one ODrive in idle
- Done when: simulated ODrive frames on both buses fill all 10 axis entries.
- Biggest risk: if it slips, it eats the Oct 15 buffer day.

## Oct 15 · Integration
- [ ] `snapshot`: latch switches, encoders, IMU and 10 axes on the `sample` strobe
- [ ] Pi link: SPI slave (mode 0) + data-ready GPIO, fixed frame with header + CRC,
      same layout as the current STM32 frame (UART dump to PC as a fallback)
- [ ] `top.v` synthesizes for the xc7a100t with positive WNS
- Goal: one simulation/bitstream where every sensor shows up in the frame the Pi reads.

## Buy / check before hardware bring-up
- Logic analyzer ≥ 100 Msps (DSLogic class)
- ISO1042 breakouts, 120 Ω terminations, twisted pair, Pmod/breadboard adapter
- AS5047P cable lengths → RS422 drivers if they run long next to motor leads
- Arty I/O is 3.3 V only; check every part's voltage levels
