# FIFO exercise

A FIFO is a queue: the first word written is the first word read. Imagine numbered
storage slots with two bookmarks: `wr_ptr` marks the next write location; `rd_ptr`
marks the oldest unread word. `level` counts the words waiting. Each bookmark
wraps to zero after the last slot.

Read the contract in [test_fifo_sync.py](test_fifo_sync.py), then follow the six
numbered TODO explanations in [fifo_sync.v](../rtl/fifo_sync.v). The implementation
is now complete; each TODO remains immediately above the code that implements it.

Later, UART's byte-valid pulse will request a FIFO write; the packet decoder will
request reads. The queue lets bytes wait while the decoder is busy. It is finite:
a full queue rejects writes unless a simultaneous read frees a slot. `overflow`
signals each rejected write. The later IMU diagnostic block counts these events
and handles packet resynchronization; this FIFO only handles words.

## Interface and timing

| Signal | Meaning |
|---|---|
| `wr_en`, `wr_data` | Request to append this word at the next rising edge |
| `rd_en` | Request to remove the oldest word at that edge |
| `rd_data`, `rd_valid` | Registered result, available after an accepted read edge |
| `level`, `empty`, `full` | Occupancy and boundary flags |
| `overflow`, `underflow` | Rejected write/read at this edge; may be high on consecutive error cycles |
| `rst` | Synchronous active-high reset, taking priority over requests |

```text
write 0x11        queue: [0x11]        rd_valid=0
write 0x22        queue: [0x11, 0x22]  rd_valid=0
read             queue: [0x22]        rd_valid=1, rd_data=0x11
do nothing       queue: [0x22]        rd_valid=0, rd_data still 0x11
read             queue: []            rd_valid=1, rd_data=0x22
read while empty queue: []            rd_valid=0, underflow=1
```

For simultaneous requests, use occupancy from BEFORE the edge:

- Empty: accept write, reject read; the new word can be read on a later edge.
- Partly occupied: return old head, append new word, hold level.
- Full: return old head, write into the freed slot, remain full without overflow.

The full case reads/writes the same address. Nonblocking assignments (`<=`) let
the read see the old word. Use explicit pointer wrapping because DEPTH can be 3.
The counter must represent DEPTH itself: eight slots need a four-bit occupancy
counter (0..8), though their addresses need only three bits (0..7).

## Python test structure

`Bench.step()` drives inputs at a falling edge, calculates the expected result
using Python's `deque`, then checks outputs after the rising edge and `ReadOnly()`.
The latter waits for HDL updates to settle. The checker compares public outputs,
not internal RAM/pointers, so your implementation can differ from the reference.
It also checks output retention on idle/rejected reads and checks every event flag.

Eight tests cover empty reads, full writes/order, data patterns/output retention,
simultaneous requests at empty/full/partial occupancy, wraparound, reset during
traffic, and 1500 randomized cycles with a fixed reproducible seed. One named
test contains many clock steps and assertions.

```bash
source /home/vismay/fpga/venv/bin/activate
cd /home/vismay/fpga/biped-fpga/sim
make TOP=fifo_sync
make TOP=fifo_sync FIFO_DEPTH=3 FIFO_WIDTH=8
make TOP=fifo_sync FIFO_DEPTH=2 FIFO_WIDTH=1
make TOP=fifo_sync FIFO_DEPTH=8 FIFO_WIDTH=16
make TOP=fifo_sync COCOTB_TESTCASE=simultaneous_at_full
```

Lint from the repository root:
`verilator --lint-only -Wall rtl/fifo_sync.v`.

## Verification performed on 2026-09-22

Temporary reference outside `rtl/`: eight tests passed at each (DEPTH, WIDTH)
setting (2,1), (3,8), (8,16), (16,8): 32 passing test executions.
All 13 independently mutated versions were rejected at (3,8):

| Deliberate bug | Example test catching it |
|---|---|
| Full one slot early | fill_overflow_and_drain |
| Reject full simultaneous exchange | simultaneous_at_full |
| Accept overflow write | fill_overflow_and_drain |
| Accept empty read | reset_and_empty_reads |
| Read wrong pointer | data_patterns_and_output_hold |
| Missing explicit wrap at DEPTH | simultaneous_at_partial_and_wrap |
| Sticky rd_valid | data_patterns_and_output_hold |
| Missing overflow signal | fill_overflow_and_drain |
| Missing underflow signal | reset_and_empty_reads |
| Read data changes while idle | data_patterns_and_output_hold |
| Missing occupancy reset | reset_and_empty_reads |
| Wrong simultaneous occupancy change | simultaneous_at_partial_and_wrap |
| Full exchange returns new rather than old data | simultaneous_at_full |

Reference and mutant sources/build products were deleted after verification.
The completed repository implementation also passes all eight tests.

## UART timing checks

`make test-uart-bno085` runs three new tests: nominal 3 Mbaud and +/-100 ppm
sender offsets, against DUT clock 100 MHz/divider 33. Each streams all 256 bytes
at four starting phases (1024 bytes/test). All pass against existing RX and a
temporary copy. Output-bit-flip and shortened-bit-timer mutations both fail the
nominal test. Crystal offsets are a test budget, not verified board tolerances.

The original six RX tests pass at dividers 16 and 33; original TX passes 5/5.
Both UART modules pass `verilator --lint-only -Wall`; their RTL was not changed.
Use `make TOP=uart_rx UART_RX_CLKS_PER_BIT=33` for the original tests at divider 33.
