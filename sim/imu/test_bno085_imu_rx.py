"""Real 3 Mbaud serial bits through the complete BNO085 receive data path."""
from fractions import Fraction

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer


BAUD = 3_000_000
FLAG = 0x7E
ESC = 0x7D


def le16(value):
    value &= 0xFFFF
    return [value & 0xFF, value >> 8]


def le32(value):
    value &= 0xFFFFFFFF
    return [(value >> shift) & 0xFF for shift in (0, 8, 16, 24)]


def sensor(report_id, sequence, values, status=3, delay=0):
    header = [report_id, sequence, ((delay >> 8) << 2) | status, delay & 0xFF]
    return header + sum((le16(value) for value in values), [])


def shtp_wire(records, sequence=0):
    length = 4 + len(records)
    content = [length & 0xFF, length >> 8, 3, sequence] + records
    escaped = []
    for byte in content:
        if byte in (FLAG, ESC):
            escaped += [ESC, byte ^ 0x20]
        else:
            escaped.append(byte)
    return [FLAG, 1] + escaped + [FLAG]


def signed(signal, bits=16):
    value = int(signal.value)
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


async def setup(dut):
    dut.rx.value = 1
    dut.snapshot.value = 0
    dut.rst.value = 1
    Clock(dut.clk, 10, unit="ns").start()
    await ClockCycles(dut.clk, 6)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def send_uart(dut, data):
    await FallingEdge(dut.clk)
    bit_ps = Fraction(10**12, BAUD)
    elapsed = 0
    bit_number = 0
    for byte in data:
        for bit in [0] + [(byte >> index) & 1 for index in range(8)] + [1]:
            dut.rx.value = bit
            bit_number += 1
            deadline = int(bit_number * bit_ps)
            await Timer(deadline - elapsed, unit="ps")
            elapsed = deadline
    dut.rx.value = 1


async def wait_sample(dut, limit=5000):
    for _ in range(limit):
        if (dut.accel_has_sample.value == 1 and dut.gyro_has_sample.value == 1
                and dut.rotation_has_sample.value == 1):
            return
        await RisingEdge(dut.clk)
    assert False, "complete report set did not arrive"


@cocotb.test()
async def serial_packet_updates_raw_imu_registers(dut):
    await setup(dut)
    records = (
        [0xFB] + le32(-7)
        + sensor(0x01, 10, [-256, 512, 0x7E])
        + sensor(0x02, 20, [-1, -2, -3])
        + sensor(0x05, 30, [-8192, 4096, -1, 16384, 0x1234])
    )
    await send_uart(dut, shtp_wire(records, sequence=44))
    await wait_sample(dut)

    assert (signed(dut.accel_x), signed(dut.accel_y), signed(dut.accel_z)) == (
        -256, 512, 0x7E)
    assert (signed(dut.gyro_x), signed(dut.gyro_y), signed(dut.gyro_z)) == (-1, -2, -3)
    assert (signed(dut.rotation_i), signed(dut.rotation_j),
            signed(dut.rotation_k), signed(dut.rotation_real)) == (
                -8192, 4096, -1, 16384)
    assert int(dut.rotation_accuracy.value) == 0x1234
    assert (int(dut.accel_q_point.value), int(dut.gyro_q_point.value),
            int(dut.rotation_q_point.value)) == (8, 9, 14)
    assert int(dut.accel_shtp_sequence.value) == 44
    assert signed(dut.accel_base_delta, 32) == -7
    assert int(dut.accel_capture_us.value) > 0
    # The complete packet takes roughly 150 us on the wire. A value below 20 us
    # proves capture occurred at its opening flag, not after the closing flag.
    assert int(dut.accel_capture_us.value) < 20
    assert dut.accel_capture_us.value == dut.gyro_capture_us.value
    assert dut.gyro_capture_us.value == dut.rotation_capture_us.value
    assert int(dut.uart_frame_error_count.value) == 0
    assert int(dut.packet_format_error_count.value) == 0


@cocotb.test()
async def snapshot_and_later_packet_refresh_the_registers(dut):
    await setup(dut)
    first = sensor(0x01, 1, [1, 2, 3])
    # Supply the other two types so wait_sample can use one common condition.
    first += sensor(0x02, 1, [4, 5, 6])
    first += sensor(0x05, 1, [7, 8, 9, 10, 11])
    await send_uart(dut, shtp_wire(first, sequence=1))
    await wait_sample(dut)

    await FallingEdge(dut.clk)
    dut.snapshot.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.snapshot.value = 0
    assert dut.accel_new.value == 0
    assert signed(dut.accel_x) == 1

    second = sensor(0x01, 2, [100, 200, 300])
    await send_uart(dut, shtp_wire(second, sequence=2))
    for _ in range(5000):
        if dut.accel_new.value == 1:
            break
        await RisingEdge(dut.clk)
    assert dut.accel_new.value == 1
    assert (signed(dut.accel_x), signed(dut.accel_y), signed(dut.accel_z)) == (
        100, 200, 300)
