"""Specification for the paced BNO085 UART-SHTP packet transmitter.

The test observes the physical TX pin. It checks flags, protocol ID, SHTP
headers, escaping, per-channel sequence numbers and the quiet time from the end
of one stop bit to the beginning of the next start bit.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.simtime import get_sim_time
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

CLK_NS = 10
CLKS_PER_BIT = int(os.getenv("BNO_TX_CLKS_PER_BIT", "4"))
CLK_HZ = int(os.getenv("BNO_TX_CLK_HZ", "1000000"))
GAP_US = int(os.getenv("BNO_TX_GAP_US", "12"))
GAP_CYCLES = (CLK_HZ // 1_000_000) * GAP_US
FLAG = 0x7E
ESC = 0x7D


def escape(data):
    out = []
    for byte in data:
        out.extend([ESC, byte ^ 0x20] if byte in (FLAG, ESC) else [byte])
    return out


async def setup(dut):
    Clock(dut.clk, CLK_NS, unit="ns").start()
    dut.request_valid.value = 0
    dut.request_bsq.value = 0
    dut.request_channel.value = 0
    dut.request_payload_len.value = 0
    dut.payload_byte.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


async def payload_driver(dut, payload, stop):
    while not stop[0]:
        await FallingEdge(dut.clk)
        index = int(dut.payload_index.value)
        dut.payload_byte.value = payload[index] if index < len(payload) else 0


async def request(dut, channel=0, payload=None, bsq=False):
    payload = payload or []
    stop = [False]
    driver = cocotb.start_soon(payload_driver(dut, payload, stop))
    await FallingEdge(dut.clk)
    dut.request_bsq.value = int(bsq)
    dut.request_channel.value = channel
    dut.request_payload_len.value = len(payload)
    dut.request_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.request_ready.value:
            break
    await FallingEdge(dut.clk)
    dut.request_valid.value = 0
    while not dut.done.value:
        await RisingEdge(dut.clk)
    stop[0] = True
    await FallingEdge(dut.clk)
    driver.cancel()


async def receive_byte(dut):
    await FallingEdge(dut.tx)
    start_ns = float(get_sim_time(unit="ns"))
    await ClockCycles(dut.clk, CLKS_PER_BIT // 2)
    assert dut.tx.value == 0
    value = 0
    for bit in range(8):
        await ClockCycles(dut.clk, CLKS_PER_BIT)
        value |= int(dut.tx.value) << bit
    await ClockCycles(dut.clk, CLKS_PER_BIT)
    assert dut.tx.value == 1
    return value, start_ns


async def capture(dut, count):
    values, starts = [], []
    for _ in range(count):
        value, start = await receive_byte(dut)
        values.append(value)
        starts.append(start)
    return values, starts


def assert_gaps(starts):
    frame_cycles = 10 * CLKS_PER_BIT
    measured = [round((b - a) / CLK_NS) - frame_cycles
                for a, b in zip(starts, starts[1:])]
    assert measured, "test needs at least two wire bytes"
    assert all(g >= GAP_CYCLES for g in measured), measured
    assert all(g <= GAP_CYCLES + 2 for g in measured), measured


@cocotb.test()
async def bsq_wire_format_and_every_byte_gap(dut):
    await setup(dut)
    reader = cocotb.start_soon(capture(dut, 3))
    await request(dut, bsq=True)
    values, starts = await reader
    assert values == [FLAG, 0x00, FLAG]
    assert_gaps(starts)


@cocotb.test()
async def set_feature_frame_escapes_and_uses_little_endian_header(dut):
    await setup(dut)
    payload = [0xFD, 0x05, 0, 0, 0, 0, 0x10, 0x27, 0,
               0, 0, 0, 0, 0, 0, FLAG, ESC]
    content = [21, 0, 2, 0] + payload
    expected = [FLAG, 1] + escape(content) + [FLAG]
    reader = cocotb.start_soon(capture(dut, len(expected)))
    await request(dut, channel=2, payload=payload)
    values, starts = await reader
    assert values == expected
    assert_gaps(starts)


@cocotb.test()
async def sequence_numbers_are_independent_per_channel(dut):
    await setup(dut)
    observed = []
    starts = []
    for channel in (2, 1, 2):
        reader = cocotb.start_soon(capture(dut, 8))
        await request(dut, channel=channel, payload=[0x55])
        values, times = await reader
        observed.append(values)
        assert_gaps(times)
        starts.extend(times)
    assert observed[0][2:6] == [5, 0, 2, 0]
    assert observed[1][2:6] == [5, 0, 1, 0]
    assert observed[2][2:6] == [5, 0, 2, 1]
    assert int(dut.packet_count.value) == 3
    assert int(dut.wire_byte_count.value) == 24
    boundary_gaps = [round((starts[i] - starts[i - 1]) / CLK_NS)
                     - 10 * CLKS_PER_BIT for i in (8, 16)]
    assert all(g >= GAP_CYCLES for g in boundary_gaps), boundary_gaps


@cocotb.test()
async def reset_returns_to_idle_and_restarts_sequences(dut):
    await setup(dut)
    reader = cocotb.start_soon(capture(dut, 8))
    await request(dut, channel=2, payload=[1])
    await reader
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)
    assert dut.tx.value == 1
    assert dut.request_ready.value == 1
    reader = cocotb.start_soon(capture(dut, 8))
    await request(dut, channel=2, payload=[2])
    values, _ = await reader
    assert values[5] == 0
