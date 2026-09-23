"""Executable specification for rtl/shtp_uart_deframer.v.

Python supplies already-decoded UART bytes through a valid/ready interface.
This isolates SHTP framing from the physical UART receiver; the next integration
test will connect this input to uart_rx_fifo.

The reference helpers build messages independently:
  wire = 0x7E, protocol, escaped_content, 0x7E
For protocol 1, content starts with the four-byte SHTP header and its declared
length includes that header. The scoreboard records only packets announced by
packet_start and transferred through the output valid/ready handshake.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer


FLAG = 0x7E
ESC = 0x7D
MAX_PACKET_BYTES = int(os.environ.get("SHTP_MAX_PACKET_BYTES", "32"))
TIMEOUT_CYCLES = int(os.environ.get("SHTP_TIMEOUT_CYCLES", "40"))


def escape(content):
    wire = []
    for byte in content:
        if byte in (FLAG, ESC):
            wire.extend((ESC, byte ^ 0x20))
        else:
            wire.append(byte)
    return wire


def shtp_content(payload, channel=3, sequence=0, continuation=False,
                 declared_length=None):
    length = 4 + len(payload) if declared_length is None else declared_length
    high = ((length >> 8) & 0x7F) | (0x80 if continuation else 0)
    return [length & 0xFF, high, channel, sequence] + list(payload)


def uart_message(protocol, content):
    return [FLAG, protocol] + escape(content) + [FLAG]


async def setup(dut):
    dut.in_data.value = 0
    dut.in_valid.value = 0
    dut.time_us.value = 0
    dut.stream_abort.value = 0
    dut.out_ready.value = 1
    dut.rst.value = 1
    Clock(dut.clk, 10, unit="ns").start()
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


async def send_bytes(dut, wire_bytes):
    """Send bytes only when the deframer says it has room."""
    for byte in wire_bytes:
        while True:
            await FallingEdge(dut.clk)
            if dut.in_ready.value == 1:
                break
        dut.in_data.value = byte
        dut.in_valid.value = 1
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.in_valid.value = 0


async def pulse_abort(dut):
    await FallingEdge(dut.clk)
    dut.stream_abort.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.stream_abort.value = 0


def packet_monitor(dut):
    """Record output handshakes; output backpressure is respected."""
    packets = []
    current = {"active": False}

    async def watch():
        while True:
            await FallingEdge(dut.clk)
            # Let test drivers that also woke on this edge update ready before
            # deciding whether the byte was accepted at the following edge.
            await Timer(1, unit="ps")
            if dut.packet_start.value == 1:
                assert not current["active"], "new packet announced before old packet ended"
                current.clear()
                current.update(
                    active=True,
                    protocol=int(dut.packet_protocol.value),
                    length=int(dut.packet_len.value),
                    content=[],
                )
                if current["length"] == 0:
                    packets.append(dict(current))
                    current["active"] = False

            if dut.out_valid.value == 1 and dut.out_ready.value == 1:
                assert current["active"], "output byte appeared without packet_start"
                if not current["content"]:
                    assert dut.out_first.value == 1
                current["content"].append(int(dut.out_data.value))
                if dut.out_last.value == 1:
                    assert len(current["content"]) == current["length"]
                    packets.append(dict(current))
                    current["active"] = False

    return packets, cocotb.start_soon(watch())


async def wait_for_packets(dut, packets, count, limit=2000):
    for _ in range(limit):
        if len(packets) >= count:
            return
        await RisingEdge(dut.clk)
    assert False, f"timed out waiting for {count} packets; got {packets}"


@cocotb.test()
async def valid_shtp_packet_unescapes_reserved_bytes(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    content = shtp_content([0x11, FLAG, 0x22, ESC, 0x33], sequence=7)
    try:
        # Noise before the first flag and repeated flags must be harmless.
        await send_bytes(dut, [0x12, 0x34, FLAG, FLAG] + uart_message(1, content))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["protocol"] == 1
        assert packets[0]["content"] == content
    finally:
        watcher.cancel()


@cocotb.test()
async def uart_control_protocol_zero_is_preserved(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    control_payload = [0x34, 0x12]  # example Buffer Status Notification content
    try:
        await send_bytes(dut, uart_message(0, control_payload))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["protocol"] == 0
        assert packets[0]["content"] == control_payload
    finally:
        watcher.cancel()


@cocotb.test()
async def bad_lengths_are_discarded_then_next_packet_recovers(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    short_header = [3, 0, 3]  # fewer than the mandatory four header bytes
    mismatch = shtp_content([0xAA, 0xBB], declared_length=9)
    good = shtp_content([0x55], sequence=9)
    try:
        await send_bytes(dut, uart_message(1, short_header))
        await send_bytes(dut, uart_message(1, mismatch))
        await send_bytes(dut, uart_message(1, good))
        await wait_for_packets(dut, packets, 1)
        assert [p["content"] for p in packets] == [good]
        assert int(dut.length_error_count.value) == 2
    finally:
        watcher.cancel()


@cocotb.test()
async def malformed_escape_and_oversize_recover(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    # ESC may only be followed by 0x5E or 0x5D.
    bad_escape = [FLAG, 1, 4, 0, 3, 0, ESC, 0x00, FLAG]
    oversized = shtp_content(
        [i & 0x7C for i in range(MAX_PACKET_BYTES - 3)],
        declared_length=MAX_PACKET_BYTES + 1,
    )
    good = shtp_content([0x42], sequence=4)
    try:
        await send_bytes(dut, bad_escape)
        await send_bytes(dut, uart_message(1, oversized))
        await send_bytes(dut, uart_message(1, good))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == good
        assert int(dut.escape_error_count.value) == 1
        assert int(dut.oversize_error_count.value) == 1
    finally:
        watcher.cancel()


@cocotb.test()
async def timeout_discards_partial_packet(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    good = shtp_content([0x61, 0x62])
    try:
        await send_bytes(dut, [FLAG, 1, 6, 0])
        await ClockCycles(dut.clk, TIMEOUT_CYCLES + 3)
        await send_bytes(dut, uart_message(1, good))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == good
        assert int(dut.timeout_error_count.value) == 1
    finally:
        watcher.cancel()


@cocotb.test()
async def unsupported_continuation_is_explicitly_rejected(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    continued = shtp_content([0x10], continuation=True)
    good = shtp_content([0x20])
    try:
        await send_bytes(dut, uart_message(1, continued))
        await send_bytes(dut, uart_message(1, good))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == good
        assert int(dut.continuation_error_count.value) == 1
    finally:
        watcher.cancel()


@cocotb.test()
async def output_backpressure_keeps_complete_packet_stable(dut):
    await setup(dut)
    dut.out_ready.value = 0
    packets, watcher = packet_monitor(dut)
    content = shtp_content(list(range(12)), sequence=0xA5)
    try:
        await send_bytes(dut, uart_message(1, content))
        await ClockCycles(dut.clk, 20)
        assert not packets
        assert dut.out_valid.value == 1
        assert int(dut.out_data.value) == content[0]

        await FallingEdge(dut.clk)
        dut.out_ready.value = 1
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == content
    finally:
        watcher.cancel()


@cocotb.test()
async def abort_never_splices_bytes_across_a_loss(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    good = shtp_content([0x91, 0x92, 0x93])
    try:
        await send_bytes(dut, [FLAG, 1, 8, 0, 3])
        await pulse_abort(dut)
        await send_bytes(dut, [0, 0xAA, 0xBB])  # ignored without a new flag
        await send_bytes(dut, uart_message(1, good))
        await wait_for_packets(dut, packets, 1)
        assert len(packets) == 1
        assert packets[0]["content"] == good
    finally:
        watcher.cancel()


@cocotb.test()
async def abort_during_output_finishes_validated_packet_then_hunts(dut):
    await setup(dut)
    dut.out_ready.value = 0
    packets, watcher = packet_monitor(dut)
    first = shtp_content([0x31, 0x32, 0x33], sequence=1)
    second = shtp_content([0x41, 0x42], sequence=2)
    try:
        await send_bytes(dut, uart_message(1, first))
        await ClockCycles(dut.clk, 3)
        assert dut.out_valid.value == 1

        # This fault belongs to later upstream traffic. The already validated
        # first packet must still emerge whole once the consumer resumes.
        await pulse_abort(dut)
        dut.out_ready.value = 1
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == first

        # hunt_after_emit means bytes without a new flag cannot be attached to
        # the old closing boundary.
        await send_bytes(dut, [1, 5, 0, 3, 9, 0xAA])
        await send_bytes(dut, uart_message(1, second))
        await wait_for_packets(dut, packets, 2)
        assert packets[1]["content"] == second
    finally:
        watcher.cancel()


@cocotb.test()
async def invalid_protocol_drops_until_new_boundary(dut):
    await setup(dut)
    packets, watcher = packet_monitor(dut)
    good = shtp_content([0x77])
    try:
        await send_bytes(dut, [FLAG, 0x99, 1, 2, 3, FLAG])
        await send_bytes(dut, uart_message(1, good))
        await wait_for_packets(dut, packets, 1)
        assert packets[0]["content"] == good
        assert int(dut.invalid_protocol_count.value) == 1
    finally:
        watcher.cancel()
