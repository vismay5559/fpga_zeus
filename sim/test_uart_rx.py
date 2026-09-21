"""
Spec for rtl/uart_rx.v  (8N1, LSB first, idle high)

module uart_rx #(parameter integer CLKS_PER_BIT = 33) (
    input  wire       clk,
    input  wire       rst,          // synchronous, active high
    input  wire       rx,           // serial line, asynchronous to clk
    output reg  [7:0] data,         // the received byte, held until the next one
    output reg        valid,        // ONE clock cycle high when data is good
    output reg        frame_error   // ONE clock cycle high when the stop bit was 0
);

Rules:
  * rx comes from another chip, so it must go through a 2-flop synchronizer first.
  * The line rests high. A falling edge means a frame is starting.
  * Sample each bit in its MIDDLE, not at its edges: wait half a bit after the start
    edge, then one full bit for each of the 8 data bits, then one more for the stop bit.
  * At the middle of the start bit the line must still be low. If it is high it was a
    glitch, so give up and wait for the next falling edge.
  * Good stop bit (1) -> pulse `valid` for one cycle with the byte on `data`.
    Bad stop bit (0)  -> pulse `frame_error` for one cycle and do NOT pulse `valid`.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

CLKS_PER_BIT = int(os.environ.get("UART_RX_CLKS_PER_BIT", "16"))
CLK_PERIOD_NS = 10
BIT_NS = CLKS_PER_BIT * CLK_PERIOD_NS


async def setup(dut):
    Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start()
    dut.rx.value = 1  # line idles high
    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


def monitor(dut):
    """Record every valid/frame_error pulse the DUT produces."""
    bytes_seen, errors_seen = [], []

    async def watch():
        while True:
            await RisingEdge(dut.clk)
            if dut.valid.value == 1:
                bytes_seen.append(int(dut.data.value))
            if dut.frame_error.value == 1:
                errors_seen.append(1)

    cocotb.start_soon(watch())
    return bytes_seen, errors_seen


async def send_frame(dut, byte, bit_ns=BIT_NS, stop=1):
    """Drive one 8N1 frame onto rx, one bit at a time, like a real sender would."""
    dut.rx.value = 0  # start bit
    await Timer(bit_ns, unit="ns")
    for i in range(8):  # data bits, LSB first
        dut.rx.value = (byte >> i) & 1
        await Timer(bit_ns, unit="ns")
    dut.rx.value = stop  # stop bit
    await Timer(bit_ns, unit="ns")
    dut.rx.value = 1  # back to idle


@cocotb.test()
async def idle_line_gives_nothing(dut):
    """With the line resting high, the receiver must stay quiet."""
    await setup(dut)
    got, errs = monitor(dut)
    await ClockCycles(dut.clk, 20 * CLKS_PER_BIT)
    assert not got, f"valid pulsed on an idle line: {got}"
    assert not errs, "frame_error pulsed on an idle line"


@cocotb.test()
async def single_bytes(dut):
    await setup(dut)
    got, errs = monitor(dut)
    payload = [0x55, 0xA5, 0x00, 0xFF, 0x01, 0x80]
    for b in payload:
        await send_frame(dut, b)
        await Timer(2 * BIT_NS, unit="ns")  # idle gap between frames
    assert got == payload, f"sent {[hex(b) for b in payload]}, got {[hex(b) for b in got]}"
    assert not errs, "frame_error pulsed on clean frames"


@cocotb.test()
async def back_to_back_random(dut):
    """No idle gap between frames: the next start bit follows the stop bit."""
    await setup(dut)
    got, errs = monitor(dut)
    payload = [random.randrange(256) for _ in range(40)]
    for b in payload:
        await send_frame(dut, b)
    await Timer(2 * BIT_NS, unit="ns")
    assert got == payload, f"got {len(got)} of {len(payload)} bytes; first mismatch at " + str(
        next((i for i, (a, b) in enumerate(zip(payload, got)) if a != b), len(got))
    )
    assert not errs, "frame_error pulsed on clean frames"


@cocotb.test()
async def baud_mismatch_is_tolerated(dut):
    """The sender's clock is never exactly ours: +-2% per bit must still decode."""
    await setup(dut)
    got, errs = monitor(dut)
    payload = [0x55, 0xC3, 0x7E]
    for factor in (1.02, 0.98):
        for b in payload:
            await send_frame(dut, b, bit_ns=BIT_NS * factor)
            await Timer(2 * BIT_NS, unit="ns")
    expected = payload * 2
    assert got == expected, f"expected {[hex(b) for b in expected]}, got {[hex(b) for b in got]}"
    assert not errs, "frame_error pulsed within +-2% baud error"


@cocotb.test()
async def bad_stop_bit_flags_framing_error(dut):
    """A stop bit of 0 means the frame was mistimed: report it, do not deliver data."""
    await setup(dut)
    got, errs = monitor(dut)
    await send_frame(dut, 0x3C, stop=0)
    await Timer(4 * BIT_NS, unit="ns")  # line back to idle
    assert errs, "frame_error never pulsed on a bad stop bit"
    assert not got, f"valid pulsed on a broken frame (data {[hex(b) for b in got]})"

    # and the receiver must recover: the next clean byte still arrives
    await send_frame(dut, 0x96)
    await Timer(2 * BIT_NS, unit="ns")
    assert got == [0x96], f"after a framing error, expected [0x96], got {[hex(b) for b in got]}"


@cocotb.test()
async def short_glitch_is_ignored(dut):
    """A brief dip on the line is noise, not a start bit."""
    await setup(dut)
    got, errs = monitor(dut)
    dut.rx.value = 0
    await ClockCycles(dut.clk, CLKS_PER_BIT // 4)  # much shorter than half a bit
    dut.rx.value = 1
    await Timer(12 * BIT_NS, unit="ns")
    assert not got, f"a glitch produced a byte: {[hex(b) for b in got]}"
    assert not errs, "a glitch produced a framing error"

    # a real frame right after the glitch must still be received
    await send_frame(dut, 0x5A)
    await Timer(2 * BIT_NS, unit="ns")
    assert got == [0x5A], f"expected [0x5a] after the glitch, got {[hex(b) for b in got]}"
