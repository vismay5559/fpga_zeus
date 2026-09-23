"""Executable specification for rtl/sh2_report_parser.v.

The test supplies complete packets exactly as shtp_uart_deframer emits them:
the four-byte SHTP header followed by SH-2 records. The parser must stage and
validate the entire packet before atomically updating report banks.

Official SH-2 v1.9 layouts used here:
* 0x01 calibrated acceleration: 10 bytes, signed XYZ Q8
* 0x02 calibrated gyro:         10 bytes, signed XYZ Q9
* 0x05 Rotation Vector:         14 bytes, signed i/j/k/real Q14,
                                unsigned accuracy Q12
* 0xFB Base Timestamp and 0xFA Timestamp Rebase: 5 bytes each
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


MAX_PACKET_BYTES = int(os.environ.get("SH2_MAX_PACKET_BYTES", "64"))


def le16(value):
    value &= 0xFFFF
    return [value & 0xFF, value >> 8]


def le32(value):
    value &= 0xFFFFFFFF
    return [(value >> shift) & 0xFF for shift in (0, 8, 16, 24)]


def status_delay(status, delay):
    return [((delay >> 8) << 2) | (status & 0x03), delay & 0xFF]


def accel(sequence, status, delay, x, y, z):
    return [0x01, sequence] + status_delay(status, delay) + le16(x) + le16(y) + le16(z)


def gyro(sequence, status, delay, x, y, z):
    return [0x02, sequence] + status_delay(status, delay) + le16(x) + le16(y) + le16(z)


def rotation(sequence, status, delay, i, j, k, real, accuracy):
    return ([0x05, sequence] + status_delay(status, delay)
            + le16(i) + le16(j) + le16(k) + le16(real) + le16(accuracy))


def base(delta):
    return [0xFB] + le32(delta)


def rebase(delta):
    return [0xFA] + le32(delta)


def packet(records, channel=3, shtp_sequence=0):
    length = 4 + len(records)
    assert length <= MAX_PACKET_BYTES
    return [length & 0xFF, (length >> 8) & 0x7F, channel, shtp_sequence] + records


def signed(signal, bits):
    value = int(signal.value)
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


async def setup(dut):
    dut.snapshot.value = 0
    dut.sensor_reset.value = 0
    dut.packet_start.value = 0
    dut.packet_protocol.value = 0
    dut.packet_len.value = 0
    dut.packet_capture_us.value = 0
    dut.in_data.value = 0
    dut.in_valid.value = 0
    dut.in_first.value = 0
    dut.in_last.value = 0
    dut.rst.value = 1
    Clock(dut.clk, 10, unit="ns").start()
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


async def send_packet(dut, content, capture_us=0, protocol=1,
                      wrong_first=False, wrong_last=False):
    await FallingEdge(dut.clk)
    dut.packet_protocol.value = protocol
    dut.packet_len.value = len(content)
    dut.packet_capture_us.value = capture_us
    dut.packet_start.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.packet_start.value = 0

    for index, byte in enumerate(content):
        while dut.in_ready.value != 1:
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
        dut.in_data.value = byte
        dut.in_valid.value = 1
        dut.in_first.value = (index == 0) and not wrong_first
        dut.in_last.value = (index == len(content) - 1) and not wrong_last
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.in_valid.value = 0
        dut.in_first.value = 0
        dut.in_last.value = 0


async def wait_idle(dut, limit=500):
    for _ in range(limit):
        if int(dut.state.value) == 0:
            return
        await RisingEdge(dut.clk)
    assert False, "parser did not return to idle"


async def pulse_snapshot(dut):
    await FallingEdge(dut.clk)
    dut.snapshot.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.snapshot.value = 0
    dut.sensor_reset.value = 0


@cocotb.test()
async def decodes_all_three_fixed_point_reports_and_metadata(dut):
    await setup(dut)
    records = (
        base(-10)
        + accel(7, 3, 0x123, -256, 512, -32768)
        + rebase(25)
        + gyro(9, 2, 0x234, -1, 1024, -2048)
        + rotation(11, 1, 0x345, -8192, 4096, -1, 16384, 0x1234)
    )
    await send_packet(dut, packet(records, shtp_sequence=22), capture_us=123456)
    await wait_idle(dut)

    assert (signed(dut.accel_x, 16), signed(dut.accel_y, 16),
            signed(dut.accel_z, 16)) == (-256, 512, -32768)
    assert int(dut.accel_q_point.value) == 8
    assert int(dut.accel_report_sequence.value) == 7
    assert int(dut.accel_status.value) == 3
    assert int(dut.accel_delay.value) == 0x123
    assert int(dut.accel_shtp_sequence.value) == 22
    assert int(dut.accel_capture_us.value) == 123456
    assert signed(dut.accel_base_delta, 32) == -10
    assert signed(dut.accel_rebase_delta, 32) == 0

    assert (signed(dut.gyro_x, 16), signed(dut.gyro_y, 16),
            signed(dut.gyro_z, 16)) == (-1, 1024, -2048)
    assert int(dut.gyro_q_point.value) == 9
    assert signed(dut.gyro_base_delta, 32) == -10
    assert signed(dut.gyro_rebase_delta, 32) == 25

    assert (signed(dut.rotation_i, 16), signed(dut.rotation_j, 16),
            signed(dut.rotation_k, 16), signed(dut.rotation_real, 16)) == (
                -8192, 4096, -1, 16384)
    assert int(dut.rotation_accuracy.value) == 0x1234
    assert int(dut.rotation_q_point.value) == 14
    assert int(dut.rotation_accuracy_q_point.value) == 12
    assert signed(dut.rotation_base_delta, 32) == -10
    assert signed(dut.rotation_rebase_delta, 32) == 25
    assert dut.accel_new.value == dut.gyro_new.value == dut.rotation_new.value == 1


@cocotb.test()
async def snapshot_clears_freshness_but_silence_retains_values(dut):
    await setup(dut)
    content = packet(accel(1, 3, 0, 100, 200, 300), shtp_sequence=1)
    await send_packet(dut, content, capture_us=50)
    await wait_idle(dut)
    assert dut.accel_has_sample.value == 1
    assert dut.accel_new.value == 1

    await pulse_snapshot(dut)
    assert dut.accel_new.value == 0
    await ClockCycles(dut.clk, 100)
    assert (signed(dut.accel_x, 16), signed(dut.accel_y, 16),
            signed(dut.accel_z, 16)) == (100, 200, 300)
    assert int(dut.accel_capture_us.value) == 50
    assert dut.accel_has_sample.value == 1
    assert dut.accel_new.value == 0
    assert dut.gyro_has_sample.value == 0


@cocotb.test()
async def snapshot_on_commit_edge_leaves_new_sample_pending(dut):
    await setup(dut)
    await send_packet(dut, packet(gyro(1, 3, 0, 1, 2, 3)))
    for _ in range(100):
        await FallingEdge(dut.clk)
        if int(dut.state.value) == 4:  # ST_COMMIT
            break
    assert int(dut.state.value) == 4
    dut.snapshot.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.snapshot.value = 0
    dut.sensor_reset.value = 0
    assert dut.gyro_new.value == 1
    assert (signed(dut.gyro_x, 16), signed(dut.gyro_y, 16),
            signed(dut.gyro_z, 16)) == (1, 2, 3)


@cocotb.test()
async def sequence_rollover_and_real_gaps_are_counted(dut):
    await setup(dut)
    await send_packet(dut, packet(accel(255, 3, 0, 1, 1, 1), shtp_sequence=255))
    await wait_idle(dut)
    await pulse_snapshot(dut)

    # 255 -> 0 is normal rollover. The second report jumps 0 -> 2, one gap.
    records = accel(0, 3, 0, 2, 2, 2) + accel(2, 3, 0, 3, 3, 3)
    await send_packet(dut, packet(records, shtp_sequence=0))
    await wait_idle(dut)
    assert int(dut.accel_report_sequence.value) == 2
    assert signed(dut.accel_x, 16) == 3
    assert int(dut.accel_sequence_gap_count.value) == 1
    assert int(dut.shtp_sequence_gap_count.value) == 0

    await send_packet(dut, packet(gyro(0, 3, 0, 4, 5, 6), shtp_sequence=2))
    await wait_idle(dut)
    assert int(dut.shtp_sequence_gap_count.value) == 1


@cocotb.test()
async def bad_report_discards_entire_packet_without_partial_update(dut):
    await setup(dut)
    good = packet(accel(1, 3, 0, 10, 20, 30), shtp_sequence=1)
    await send_packet(dut, good, capture_us=10)
    await wait_idle(dut)
    await pulse_snapshot(dut)

    # A valid-looking acceleration followed by an unknown report makes the
    # entire packet unusable; the earlier record must not leak into registers.
    bad = packet(accel(2, 3, 0, 99, 99, 99) + [0x99, 1, 2, 3], shtp_sequence=2)
    await send_packet(dut, bad, capture_us=20)
    await wait_idle(dut)
    assert signed(dut.accel_x, 16) == 10
    assert int(dut.accel_report_sequence.value) == 1
    assert dut.accel_new.value == 0
    assert int(dut.unsupported_report_count.value) == 1

    truncated_rotation = packet([0x05, 3, 0, 0, 1, 2, 3], shtp_sequence=3)
    await send_packet(dut, truncated_rotation)
    await wait_idle(dut)
    assert int(dut.packet_format_error_count.value) == 1
    assert signed(dut.accel_x, 16) == 10


@cocotb.test()
async def non_sensor_packets_and_bad_stream_markers_are_safe(dut):
    await setup(dut)
    await send_packet(dut, [0x34, 0x12], protocol=0)
    await wait_idle(dut)
    assert int(dut.ignored_packet_count.value) == 1
    assert int(dut.packet_format_error_count.value) == 0

    other_channel = packet(accel(1, 3, 0, 1, 2, 3), channel=2)
    await send_packet(dut, other_channel)
    await wait_idle(dut)
    assert int(dut.ignored_packet_count.value) == 2
    assert dut.accel_has_sample.value == 0

    bad_markers = packet(accel(1, 3, 0, 1, 2, 3), channel=3)
    await send_packet(dut, bad_markers, wrong_first=True)
    await wait_idle(dut)
    assert int(dut.packet_format_error_count.value) == 1
    assert dut.accel_has_sample.value == 0

    wrong_header = packet(accel(1, 3, 0, 1, 2, 3), channel=3)
    wrong_header[0] += 1
    await send_packet(dut, wrong_header)
    await wait_idle(dut)
    assert int(dut.packet_format_error_count.value) == 2


@cocotb.test()
async def confirmed_sensor_reset_invalidates_samples_and_sequence_history(dut):
    await setup(dut)
    await send_packet(dut, packet(
        accel(100, 3, 0, 10, 20, 30)
        + gyro(100, 3, 0, 40, 50, 60)
        + rotation(100, 3, 0, 1, 2, 3, 4, 5), shtp_sequence=100))
    await wait_idle(dut)
    assert dut.accel_has_sample.value == 1

    dut.sensor_reset.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.sensor_reset.value = 0
    assert dut.accel_has_sample.value == 0
    assert dut.gyro_has_sample.value == 0
    assert dut.rotation_has_sample.value == 0
    assert dut.accel_new.value == 0
    assert signed(dut.accel_x, 16) == 10  # retained bits are marked invalid

    # A reboot may restart every sequence at any value. The first new packet is
    # a new baseline, not a false loss event.
    await send_packet(dut, packet(accel(7, 3, 0, 70, 80, 90), shtp_sequence=7))
    await wait_idle(dut)
    assert dut.accel_has_sample.value == 1
    assert signed(dut.accel_x, 16) == 70
    assert int(dut.accel_sequence_gap_count.value) == 0
    assert int(dut.shtp_sequence_gap_count.value) == 0
