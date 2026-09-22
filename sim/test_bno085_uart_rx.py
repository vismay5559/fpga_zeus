"""End-to-end receive specification for rtl/bno085_uart_rx.v.

Python behaves like the BNO085 electrical UART transmitter. It drives one RX
wire with start, eight LSB-first data and stop bits at an independent exact
3.000 Mbaud rate. No test inserts bytes directly into the FIFO or deframer.

The expected path is:
  serial wire -> uart_rx -> fifo_sync -> holding bridge -> SHTP deframer

Only a complete, validated SHTP packet may reach the output monitor. Tests cover
normal packets, reserved-byte escaping, baud mismatch, attachment mid-stream,
UART framing failure, packet timeout, downstream backpressure and FIFO overflow.
"""
from fractions import Fraction
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer


CLK_PERIOD_NS = 10
BAUD = 3_000_000
FLAG = 0x7E
ESC = 0x7D
FIFO_DEPTH = int(os.environ.get("BNO_RX_FIFO_DEPTH", "4"))
TIMEOUT_CYCLES = int(os.environ.get("BNO_RX_TIMEOUT_CYCLES", "450"))


def escape(content):
    wire = []
    for byte in content:
        if byte in (FLAG, ESC):
            wire.extend((ESC, byte ^ 0x20))
        else:
            wire.append(byte)
    return wire


def shtp_content(payload, channel=3, sequence=0):
    length = 4 + len(payload)
    return [length & 0xFF, (length >> 8) & 0x7F, channel, sequence] + list(payload)


def uart_shtp_message(content, protocol=1):
    return [FLAG, protocol] + escape(content) + [FLAG]


async def setup(dut):
    dut.rx.value = 1
    dut.out_ready.value = 1
    dut.rst.value = 1
    Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start()
    await ClockCycles(dut.clk, 6)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


async def send_uart_bytes(dut, wire_bytes, baud=BAUD, bad_stop_at=None):
    """Drive independent 8N1 frames; cumulative rounding avoids clock drift."""
    await FallingEdge(dut.clk)
    bit_ps = Fraction(10**12, baud)
    elapsed_ps = 0
    bit_number = 0

    for byte_index, byte in enumerate(wire_bytes):
        stop = 0 if byte_index == bad_stop_at else 1
        bits = [0] + [(byte >> bit) & 1 for bit in range(8)] + [stop]
        for value in bits:
            dut.rx.value = value
            bit_number += 1
            next_elapsed_ps = int(bit_number * bit_ps)
            await Timer(next_elapsed_ps - elapsed_ps, unit="ps")
            elapsed_ps = next_elapsed_ps

    dut.rx.value = 1


def packet_monitor(dut):
    packets = []
    current = {"active": False}

    async def watch():
        while True:
            await FallingEdge(dut.clk)
            await Timer(1, unit="ps")

            if dut.packet_start.value == 1:
                assert not current["active"]
                current.clear()
                current.update(
                    active=True,
                    protocol=int(dut.packet_protocol.value),
                    length=int(dut.packet_len.value),
                    content=[],
                )

            if dut.out_valid.value == 1 and dut.out_ready.value == 1:
                assert current["active"], "output data arrived without packet_start"
                if not current["content"]:
                    assert dut.out_first.value == 1
                current["content"].append(int(dut.out_data.value))
                if dut.out_last.value == 1:
                    assert len(current["content"]) == current["length"]
                    packets.append(dict(current))
                    current["active"] = False

    return packets, cocotb.start_soon(watch())


async def wait_for_packets(dut, packets, count, cycles=3000):
    for _ in range(cycles):
        if len(packets) >= count:
            return
        await RisingEdge(dut.clk)
    assert False, f"expected {count} packets, received {packets}"


@cocotb.test()
async def serial_wire_to_validated_shtp_packets(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    first = shtp_content([0x11, FLAG, 0x22, ESC, 0x33], sequence=7)
    second = shtp_content([0x44, 0x55], channel=4, sequence=8)
    try:
        await send_uart_bytes(
            dut, uart_shtp_message(first) + uart_shtp_message(second)
        )
        await wait_for_packets(dut, packets, 2)
        assert [packet["content"] for packet in packets] == [first, second]
        assert [packet["protocol"] for packet in packets] == [1, 1]
        assert int(dut.uart_frame_error_count.value) == 0
        assert int(dut.fifo_overflow_count.value) == 0
    finally:
        watcher.cancel()


@cocotb.test()
async def exact_sensor_baud_with_fast_crystal_offset(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    content = shtp_content([0x00, 0x7F, 0x80, 0xFF], sequence=0xFE)
    fast_baud = BAUD + (BAUD // 10_000)  # +100 ppm
    try:
        await send_uart_bytes(dut, uart_shtp_message(content), baud=fast_baud)
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == content
        assert int(dut.uart_frame_error_count.value) == 0
    finally:
        watcher.cancel()


@cocotb.test()
async def attaching_mid_stream_hunts_for_next_complete_packet(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    good = shtp_content([0x61, 0x62, 0x63], sequence=4)
    try:
        # These are the middle/end bytes of a packet that began before the FPGA.
        await send_uart_bytes(dut, [0x03, 0x99, ESC, 0x5E, 0x12, 0x34])
        await send_uart_bytes(dut, uart_shtp_message(good))
        await wait_for_packets(dut, packets, 1)
        assert len(packets) == 1
        assert packets[0]["content"] == good
    finally:
        watcher.cancel()


@cocotb.test()
async def bad_stop_bit_flushes_partial_packet_and_recovers(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    partial = [FLAG, 1, 8, 0, 3, 1, 0xAA]
    good = shtp_content([0x71, 0x72], sequence=2)
    try:
        await send_uart_bytes(dut, partial, bad_stop_at=len(partial) - 1)
        await Timer(int(2 * Fraction(10**12, BAUD)), unit="ps")
        await send_uart_bytes(dut, uart_shtp_message(good))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == good
        assert int(dut.uart_frame_error_count.value) == 1
    finally:
        watcher.cancel()


@cocotb.test()
async def truncated_packet_times_out_then_next_packet_recovers(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    good = shtp_content([0x81, 0x82], sequence=3)
    try:
        await send_uart_bytes(dut, [FLAG, 1, 8, 0, 3])
        await ClockCycles(dut.clk, TIMEOUT_CYCLES + 20)
        assert int(dut.timeout_error_count.value) == 1

        await send_uart_bytes(dut, uart_shtp_message(good))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == good
    finally:
        watcher.cancel()


@cocotb.test()
async def fifo_overflow_flushes_stale_bytes_and_recovers(dut):
    await setup(dut)
    dut.out_ready.value = 0
    packets, watcher = packet_monitor(dut)
    recovery_seen = {"value": False}

    async def watch_recovery():
        await RisingEdge(dut.recovery_active)
        recovery_seen["value"] = True

    recovery_watcher = cocotb.start_soon(watch_recovery())
    first = shtp_content([0x91, 0x92, 0x93], sequence=5)
    good = shtp_content([0xA1, 0xA2], sequence=6)
    try:
        await send_uart_bytes(dut, uart_shtp_message(first))
        for _ in range(1000):
            if dut.out_valid.value == 1:
                break
            await RisingEdge(dut.clk)
        assert dut.out_valid.value == 1

        # The completed packet is blocked at the output, so incoming bytes fill
        # the small simulation FIFO. They contain no FLAG and cannot form a
        # packet after recovery.
        await send_uart_bytes(dut, [0x55] * (FIFO_DEPTH * 4))
        assert int(dut.fifo_overflow_count.value) > 0
        assert recovery_seen["value"], "overflow did not enter FIFO flush recovery"

        # Change ready on a falling edge so both the RTL and monitor observe it
        # before the next rising-edge transfer.
        await FallingEdge(dut.clk)
        dut.out_ready.value = 1
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == first

        await send_uart_bytes(dut, uart_shtp_message(good))
        await wait_for_packets(dut, packets, 2)
        assert packets[1]["content"] == good
    finally:
        watcher.cancel()
        recovery_watcher.cancel()
