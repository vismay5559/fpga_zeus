"""
Spec for rtl/uart_tx.v  (8N1, LSB first, idle high)

module uart_tx #(parameter integer CLKS_PER_BIT = 33) (
    input  wire       clk,
    input  wire       rst,    // synchronous, active high
    input  wire [7:0] data,
    input  wire       valid,  // byte offered
    output wire       ready,  // high when idle; byte accepted when valid && ready
    output wire       tx      // serial line, 1 when idle
);

Every bit (start, 8 data, stop) must last exactly CLKS_PER_BIT clock cycles.
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.simtime import get_sim_time
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout

CLKS_PER_BIT = 16  # must match -Puart_tx.CLKS_PER_BIT in the Makefile
CLK_PERIOD_NS = 10
FRAME_TIMEOUT_NS = 20 * CLKS_PER_BIT * CLK_PERIOD_NS


async def setup(dut):
    Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start()
    dut.valid.value = 0
    dut.data.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


async def send_byte(dut, byte):
    """Offer a byte and hold valid until the DUT accepts it."""
    dut.data.value = byte
    dut.valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.ready.value == 1:  # value the DUT saw at this edge
            break
    dut.valid.value = 0


async def recv_byte(dut):
    """Decode one frame from tx by sampling each bit at its centre."""
    await FallingEdge(dut.tx)  # start bit begins
    await ClockCycles(dut.clk, CLKS_PER_BIT // 2)
    assert dut.tx.value == 0, "start bit not low at its centre"
    byte = 0
    for i in range(8):
        await ClockCycles(dut.clk, CLKS_PER_BIT)
        byte |= int(dut.tx.value) << i
    await ClockCycles(dut.clk, CLKS_PER_BIT)
    assert dut.tx.value == 1, "stop bit not high"
    return byte


async def roundtrip(dut, byte):
    rx = cocotb.start_soon(with_timeout(recv_byte(dut), FRAME_TIMEOUT_NS, "ns"))
    await send_byte(dut, byte)
    got = await rx
    assert got == byte, f"sent 0x{byte:02X}, line carried 0x{got:02X}"


@cocotb.test()
async def idle_line_is_high(dut):
    await setup(dut)
    for _ in range(4 * CLKS_PER_BIT):
        await RisingEdge(dut.clk)
        assert dut.tx.value == 1, "tx must idle high"
        assert dut.ready.value == 1, "ready must be high when idle"


@cocotb.test()
async def single_bytes(dut):
    await setup(dut)
    for b in (0x55, 0xA5, 0x00, 0xFF, 0x01, 0x80):
        await roundtrip(dut, b)


@cocotb.test()
async def bit_width_is_exact(dut):
    """0x55 toggles the line at every bit boundary: all gaps must be CLKS_PER_BIT."""
    await setup(dut)
    edges = []

    async def watch():
        while True:
            await (FallingEdge(dut.tx) if dut.tx.value == 1 else RisingEdge(dut.tx))
            edges.append(get_sim_time(unit="ns"))

    watcher = cocotb.start_soon(watch())
    await roundtrip(dut, 0x55)
    watcher.cancel()

    # start..bit7 gives 10 edges (start fall, then 9 toggles incl. into stop)
    assert len(edges) >= 10, f"only saw {len(edges)} edges"
    gaps = [round((b - a) / CLK_PERIOD_NS) for a, b in zip(edges, edges[1:10])]
    assert all(g == CLKS_PER_BIT for g in gaps), f"bit widths {gaps}, expected {CLKS_PER_BIT}"


@cocotb.test()
async def back_to_back_random(dut):
    """Stream bytes with no gap: catches handshake and stop-bit bugs."""
    await setup(dut)
    payload = [random.randrange(256) for _ in range(40)]
    for b in payload:
        await roundtrip(dut, b)


@cocotb.test()
async def ready_low_while_busy(dut):
    await setup(dut)
    rx = cocotb.start_soon(with_timeout(recv_byte(dut), FRAME_TIMEOUT_NS, "ns"))
    await send_byte(dut, 0x3C)
    await ClockCycles(dut.clk, 2 * CLKS_PER_BIT)  # mid-frame
    assert dut.ready.value == 0, "ready must be low while a frame is in flight"
    await rx
