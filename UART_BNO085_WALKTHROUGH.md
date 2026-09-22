# UART and BNO085 receive path, from the beginning

This document explains the current UART work as if UART, Verilog and cocotb are
new. It covers every RTL block in the receive path and every Python test file in
`sim/`.

## 1. What the FPGA receives

The BNO085 and FPGA share a UART wire. When nothing is being sent, the wire is
high (`1`). One UART byte is transmitted as ten bits:

```text
idle   start     eight data bits, least-significant first       stop   idle
  1      0       d0 d1 d2 d3 d4 d5 d6 d7                         1       1
```

At 3,000,000 baud, one bit lasts about 333.333 ns and one ten-bit byte lasts
about 3.333 us. The FPGA clock is 100 MHz, so one FPGA clock lasts 10 ns. The
receiver uses 33 FPGA clocks per UART bit, or 330 ns. This is approximately 1%
faster than the sensor, so the tests deliberately generate the sender timing
independently instead of pretending both sides use the same clock.

UART only produces individual bytes. The BNO085 places those bytes into
UART-SHTP messages:

```text
0x7e | protocol | escaped SHTP content | 0x7e
```

`0x7e` marks a boundary. If packet data itself contains `0x7e` or `0x7d`, it is
escaped:

```text
data 0x7e -> wire 0x7d 0x5e
data 0x7d -> wire 0x7d 0x5d
```

Protocol `1` contains an SHTP packet. Its first four decoded bytes are:

```text
length low | continuation + length high | channel | sequence
```

The length includes those four header bytes. UART-SHTP has no checksum, so a
plausible bit flip cannot always be detected. The FPGA therefore rejects every
structural error it can detect and publishes nothing until a complete packet has
been received and checked.

## 2. The complete receive pipeline

```text
BNO085 TX pin
    |
    v
uart_rx               samples serial bits and reconstructs one byte
    |
    v
fifo_sync             queues bytes while later logic is temporarily busy
    |
    v
registered-read bridge holds a FIFO result until the deframer accepts it
    |
    v
shtp_uart_deframer    finds boundaries, removes escaping and validates length
    |
    v
validated packet stream
    |
    v
future SH-2 parser    will extract acceleration, gyro and quaternion reports
```

[`bno085_uart_rx`](rtl/bno085_uart_rx.v) instantiates and connects the existing
receiver, FIFO and deframer. This makes the path from the physical serial input
to validated packet bytes complete.

## 3. What each Verilog module does

### `tick_gen.v`

`tick_gen` counts FPGA clocks and produces a one-clock pulse every `DIV` clocks.
It is the basic pattern used for periodic timing.

### `uart_tx.v`

`uart_tx` accepts an eight-bit byte and sends start, data and stop bits. Data is
sent least-significant bit first. `ready` tells the producer when another byte
can be accepted.

This generic transmitter does not contain the BNO085's 120 us byte spacing. A
future BNO085 command sender will place that delay around `uart_tx`.

### `uart_rx.v`

`uart_rx` synchronizes the asynchronous RX pin, detects a falling start edge,
samples near the middle of every bit, shifts eight data bits into a register and
checks that the stop bit is high. A correct byte produces a one-clock `valid`
pulse. A low stop bit produces `frame_error` and no byte.

After an error it waits until the wire is high before accepting another start.
This prevents the bad low stop bit from being mistaken for a new start bit.

### `fifo_sync.v`

The FIFO is a line of storage locations with a write pointer, read pointer and
occupancy counter. UART can write a byte even when the packet decoder is busy.
The oldest stored byte is always read first.

`overflow` means a write was requested while no space existed. `underflow`
means a read was requested while no byte existed. Both are one-clock event
pulses.

### `uart_rx_fifo.v`

This module connects `uart_rx.valid` directly to the FIFO write request. Good
UART bytes enter the queue automatically. Bad UART frames do not enter it.

The FIFO read output is registered: the consumer asks with `rd_en`, and
`rd_data` plus `rd_valid` appear after the rising edge.

### `shtp_uart_deframer.v`

The deframer has six states:

1. `ST_HUNT`: ignore bytes until a `0x7e` boundary.
2. `ST_PROTOCOL`: require protocol `0` or `1`.
3. `ST_COLLECT`: unescape and stage decoded content.
4. `ST_DROP`: discard damaged input until another boundary.
5. `ST_EMIT_START`: announce one validated packet.
6. `ST_EMIT`: transfer the staged bytes to the next block.

Staging is important. Live IMU registers must never receive half of a packet and
half of a later packet. A protocol-1 packet is emitted only when its closing
boundary arrived and its decoded length matches the SHTP header.

The valid/ready rule is:

```verilog
transfer = valid && ready;
```

If `valid=1` and `ready=0`, the producer keeps the same byte and markers stable.
The transfer occurs on a rising clock edge where both are high.

### `bno085_uart_rx.v`

This is the new integration wrapper. Its one-byte bridge solves an interface
difference:

- The FIFO gives a one-clock `rd_valid` pulse after a read request.
- The deframer may lower `in_ready` for several clocks while emitting a packet.

The bridge stores the FIFO result and keeps `bridge_valid` high until the
deframer accepts it. `fifo_read_pending` prevents a second read from overwriting
an outstanding result.

On `frame_error` or FIFO `overflow`, the wrapper:

1. increments a saturating 32-bit diagnostic counter;
2. clears the holding bridge;
3. tells the deframer to discard any incomplete packet;
4. drains stale queued bytes;
5. resumes in boundary-hunt mode.

A packet already fully staged and validated before a later input error is
allowed to finish its output. The deframer then hunts for a fresh boundary.

## 4. Verilog syntax used here

`wire` describes a connection or continuously calculated value. `reg` stores a
value assigned in a clocked `always` block. In this Verilog code, `reg` does not
necessarily mean a physical standalone register; synthesis determines the
required hardware.

```verilog
always @(posedge clk)
```

means the block runs at each rising clock edge.

```verilog
bridge_valid <= 1'b1;
```

is a nonblocking assignment. All nonblocking right-hand sides use the old values
from just before the edge, and all left-hand sides update together. This models
synchronous hardware.

Parameters such as `FIFO_DEPTH` let simulation and synthesis use different sizes
without rewriting the module. Simulations use a small FIFO so overflow tests run
quickly. The real defaults are larger.

## 5. What cocotb does

cocotb is Python controlling a Verilog simulator. `dut` means design under test.
For example:

```python
dut.rx.value = 0
await Timer(333_333, unit="ps")
```

drives the RX wire low and lets simulated time advance by approximately one
3-Mbaud bit.

An `assert` is a requirement. If its condition is false, that test fails. The
tests construct expected behavior independently and compare it with the RTL.

## 6. Every Python test file

### `test_tick_gen.py`

- `tick_stays_low_in_reset`: reset must suppress pulses.
- `tick_period_is_div`: pulses must be one clock wide and exactly `DIV` clocks
  apart.

### `test_uart_tx.py`

- `idle_line_is_high`: an unused UART wire must be high.
- `single_bytes`: checks known byte patterns.
- `bit_width_is_exact`: every output bit lasts the configured number of clocks.
- `back_to_back_random`: sends many generated bytes and checks their order.
- `ready_low_while_busy`: the transmitter must reject a new request until the
  current frame finishes.

Python acts as a UART receiver here: it samples the Verilog TX output in the
middle of each bit and reconstructs the byte.

### `test_uart_rx.py`

- `idle_line_gives_nothing`: idle high must not invent bytes.
- `single_bytes`: known serial frames must decode correctly.
- `back_to_back_random`: many consecutive frames retain order.
- `baud_mismatch_is_tolerated`: sender and receiver clocks may differ slightly.
- `bad_stop_bit_flags_framing_error`: invalid stop produces an error and no byte.
- `short_glitch_is_ignored`: a pulse shorter than a real start bit is rejected.

Python acts as a UART transmitter here and toggles `dut.rx` bit by bit.

### `test_uart_rx_bno085.py`

This is the exhaustive BNO085 timing test. It uses exactly 3.000 Mbaud while the
RTL uses 33 clocks per bit. It sends all 256 byte values at four relative clock
phases, then repeats timing stress with a sender crystal offset of +100 ppm and
-100 ppm.

### `test_fifo_sync.py`

- `reset_and_empty_reads`: reset empties the FIFO and empty reads underflow.
- `fill_overflow_and_drain`: filling, rejected writes and FIFO ordering.
- `data_patterns_and_output_hold`: different bit patterns and stable read data.
- `simultaneous_at_empty`: simultaneous read/write behavior when empty.
- `simultaneous_at_full`: a read creates room for a same-edge write when full.
- `simultaneous_at_partial_and_wrap`: both pointers wrap correctly.
- `reset_discards_queued_words`: reset invalidates old stored bytes.
- `randomized_scoreboard`: thousands of generated operations are compared with
  a Python list used as the reference queue.

### `test_uart_rx_fifo.py`

This file sends actual serial bits into `uart_rx_fifo`; it does not write the FIFO
directly.

- `serial_bytes_reach_fifo_in_order`: complete wire-to-queue path.
- `fifo_buffers_while_consumer_stalls`: queued bytes wait for the consumer.
- `full_fifo_reports_each_dropped_uart_byte`: every rejected byte pulses overflow.
- `bad_uart_frame_is_not_queued_and_receiver_recovers`: framing-error recovery.
- `reset_discards_buffered_uart_bytes`: reset clears the integrated path.

### `test_shtp_uart_deframer.py`

This is a focused packet-layer test, so Python supplies bytes through the
deframer's valid/ready input instead of generating serial bits.

- valid packet with escaped reserved bytes and leading noise;
- protocol-0 control message;
- short and mismatched SHTP lengths;
- malformed escape and oversized packet;
- unfinished-packet timeout;
- unsupported continuation flag;
- output backpressure;
- abort during collection without splicing old and new bytes;
- abort while emitting a previously validated packet;
- invalid protocol and recovery.

Focused unit tests make packet-state bugs quicker to locate than a full serial
simulation.

### `test_bno085_uart_rx.py`

This is the end-to-end receive test. Python generates real independent 3-Mbaud
serial bits, and the scoreboard observes only validated packet output.

- `serial_wire_to_validated_shtp_packets`: two consecutive packets, including
  escaped `0x7e` and `0x7d`, cross the complete pipeline.
- `exact_sensor_baud_with_fast_crystal_offset`: divider 33 receives a +100 ppm
  3-Mbaud sender correctly.
- `attaching_mid_stream_hunts_for_next_complete_packet`: startup garbage cannot
  become a packet; the following complete packet succeeds.
- `bad_stop_bit_flushes_partial_packet_and_recovers`: a corrupted UART frame
  increments its counter, invalidates partial data and does not block recovery.
- `truncated_packet_times_out_then_next_packet_recovers`: silence in the middle
  of a frame increments the timeout counter.
- `fifo_overflow_flushes_stale_bytes_and_recovers`: downstream blocking fills a
  deliberately tiny FIFO; stale bytes are drained and a later packet succeeds.

The smaller simulation parameters do not weaken the rules. They make timeout and
overflow conditions practical to reach in a short simulation.

## 7. Running the tests

```bash
source ~/fpga/venv/bin/activate
cd ~/fpga/biped-fpga/sim

make TOP=bno085_uart_rx
make TOP=shtp_uart_deframer
make TOP=uart_rx_fifo
make test-uart-bno085
```

To record and view the integration waveform:

```bash
rm -rf sim_build/bno085_uart_rx_c33_d4_m32_t450
make TOP=bno085_uart_rx WAVES=1
make TOP=bno085_uart_rx view
```

From the repository root, lint the integrated receive hierarchy with:

```bash
verilator --lint-only -Wall \
  rtl/fifo_sync.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
  rtl/shtp_uart_deframer.v rtl/bno085_uart_rx.v \
  --top-module bno085_uart_rx
```

## 8. What remains after this receive transport

The FPGA can now turn the BNO085 RX wire into validated SHTP packet bytes in
simulation. It does not yet interpret SH-2 sensor reports or configure the IMU.
The remaining BNO085 work is:

1. route SHTP channels and track per-channel sequence numbers;
2. decode calibrated acceleration Q8, calibrated gyro Q9 and Rotation Vector Q14;
3. attach timestamps, status, freshness and report-sequence metadata;
4. construct startup Set Feature commands for 400/400/100 Hz;
5. implement protocol-0 buffer-status flow control and the 120 us TX byte gap;
6. detect confirmed sensor resets and reconfigure automatically;
7. replay real captured BNO085 traffic;
8. connect registers to the 1 kHz snapshot and Pi interface;
9. synthesize, constrain pins and verify rates on physical hardware.

