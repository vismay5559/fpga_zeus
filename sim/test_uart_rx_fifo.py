"""Integration specification for rtl/uart_rx_fifo.v.

This test does not place bytes directly into the FIFO. Python behaves like the
BNO085 and drives the single `rx` wire one serial bit at a time at exactly
3,000,000 baud. The Verilog uart_rx must reconstruct each byte and its `valid`
pulse must cause fifo_sync to store that byte.

The consumer side is deliberately simple: Python pulses `rd_en`, waits for a
rising clock edge, and checks `rd_valid` plus `rd_data`. A later SHTP decoder
will use this same interface.

Required behavior:
* good UART frames enter the FIFO once, in order;
* bytes wait while the consumer is stalled;
* when FIFO is full, later bytes are rejected and overflow pulses once per byte;
* a UART frame with a bad stop bit pulses frame_error and is not queued;
* after an error, a later good frame is received normally;
* reset empties both the UART receiver state and the FIFO.
"""
from fractions import Fraction
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer


CLK_PERIOD_NS = 10
BAUD = 3_000_000
FIFO_DEPTH = int(os.environ.get("UART_FIFO_DEPTH", "8"))
CLKS_PER_BIT = int(os.environ.get("UART_RX_FIFO_CLKS_PER_BIT", "33"))


async def setup(dut):
    """Start the 100 MHz FPGA clock and put both blocks into a known state."""
    dut.rx.value = 1          # UART idle level
    dut.rd_en.value = 0       # consumer is not asking for data
    dut.rst.value = 1
    Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start()
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 3)


async def send_uart_bytes(dut, payload, bad_stop_at=None):
    """Drive back-to-back 8N1 frames with an independent exact 3 Mbaud clock."""
    # Begin between FPGA sampling edges. The standalone UART timing test covers
    # several arbitrary phases; this integration test avoids a Python/HDL race
    # from changing rx at exactly the same simulated instant as a clock edge.
    await FallingEdge(dut.clk)
    bit_ps = Fraction(10**12, BAUD)  # 333333.333... ps per UART bit
    elapsed_ps = 0
    bit_number = 0

    for byte_index, byte in enumerate(payload):
        stop = 0 if byte_index == bad_stop_at else 1
        bits = [0] + [(byte >> i) & 1 for i in range(8)] + [stop]

        for bit in bits:
            dut.rx.value = bit
            bit_number += 1
            # Rounding the cumulative deadline prevents rounding error from
            # accumulating once per bit.
            next_elapsed_ps = int(bit_number * bit_ps)
            await Timer(next_elapsed_ps - elapsed_ps, unit="ps")
            elapsed_ps = next_elapsed_ps

        dut.rx.value = 1


async def read_one(dut):
    """Request one queued byte and return the registered FIFO output."""
    await FallingEdge(dut.clk)
    dut.rd_en.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.rd_valid.value == 1, "FIFO rejected a read although data was expected"
    value = int(dut.rd_data.value)
    await FallingEdge(dut.clk)
    dut.rd_en.value = 0
    return value


def pulse_monitor(dut):
    """Count diagnostic pulses even though each is only one clock wide."""
    counts = {"overflow": 0, "underflow": 0, "frame_error": 0}

    async def watch():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            for name in counts:
                counts[name] += int(getattr(dut, name).value)

    task = cocotb.start_soon(watch())
    return counts, task


@cocotb.test()
async def serial_bytes_reach_fifo_in_order(dut):
    await setup(dut)
    payload = [0x00, 0x55, 0xA5, 0x7D, 0x7E, 0xFF]
    await send_uart_bytes(dut, payload)
    await ClockCycles(dut.clk, 5)

    assert int(dut.level.value) == len(payload)
    got = [await read_one(dut) for _ in payload]
    assert got == payload, f"sent {payload}, FIFO returned {got}"
    assert dut.empty.value == 1


@cocotb.test()
async def fifo_buffers_while_consumer_stalls(dut):
    await setup(dut)
    payload = [(i * 29 + 3) & 0xFF for i in range(FIFO_DEPTH)]
    await send_uart_bytes(dut, payload)
    await ClockCycles(dut.clk, 5)

    assert dut.full.value == 1
    assert int(dut.level.value) == FIFO_DEPTH
    got = [await read_one(dut) for _ in payload]
    assert got == payload


@cocotb.test()
async def full_fifo_reports_each_dropped_uart_byte(dut):
    await setup(dut)
    counts, watcher = pulse_monitor(dut)
    accepted = list(range(FIFO_DEPTH))
    dropped = [0xD0, 0xD1, 0xD2]
    try:
        await send_uart_bytes(dut, accepted + dropped)
        await ClockCycles(dut.clk, 5)
        assert counts["overflow"] == len(dropped), counts
        assert int(dut.level.value) == FIFO_DEPTH
        got = [await read_one(dut) for _ in accepted]
        assert got == accepted, "overflow overwrote bytes already in the FIFO"
    finally:
        watcher.cancel()


@cocotb.test()
async def bad_uart_frame_is_not_queued_and_receiver_recovers(dut):
    await setup(dut)
    counts, watcher = pulse_monitor(dut)
    try:
        await send_uart_bytes(dut, [0x3C], bad_stop_at=0)
        # Leave an ordinary idle gap before the next frame. uart_rx must re-arm
        # only after observing this high level; the low stop itself is not a
        # second falling edge and must never create a phantom frame.
        await ClockCycles(dut.clk, 2 * CLKS_PER_BIT)
        assert counts["frame_error"] == 1
        assert int(dut.level.value) == 0

        await send_uart_bytes(dut, [0x96])
        await ClockCycles(dut.clk, 5)
        assert await read_one(dut) == 0x96
        assert counts["overflow"] == 0
    finally:
        watcher.cancel()


@cocotb.test()
async def reset_discards_buffered_uart_bytes(dut):
    await setup(dut)
    await send_uart_bytes(dut, [0x11, 0x22, 0x33])
    await ClockCycles(dut.clk, 5)
    assert int(dut.level.value) == 3

    await FallingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.empty.value == 1
    assert int(dut.level.value) == 0
    assert dut.rd_valid.value == 0

    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await send_uart_bytes(dut, [0x44])
    await ClockCycles(dut.clk, 5)
    assert await read_one(dut) == 0x44
