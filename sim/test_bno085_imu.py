"""Physical-wire integration test for the complete bidirectional BNO085 host."""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout

CLK_NS = 10
CPB = int(os.getenv("BNO_FULL_CLKS_PER_BIT", "4"))
FLAG = 0x7E
ESC = 0x7D


def le16(value):
    value &= 0xFFFF
    return [value & 0xFF, value >> 8]


def le32(value):
    return [(value >> shift) & 0xFF for shift in (0, 8, 16, 24)]


def packet(channel, payload, sequence=0):
    length = 4 + len(payload)
    return [length & 0xFF, length >> 8, channel, sequence] + payload


def wire_packet(protocol, content):
    escaped = []
    for byte in content:
        escaped.extend([ESC, byte ^ 0x20] if byte in (FLAG, ESC) else [byte])
    return [FLAG, protocol] + escaped + [FLAG]


def unescape(data):
    out, esc = [], False
    for byte in data:
        if esc:
            out.append(byte ^ 0x20)
            esc = False
        elif byte == ESC:
            esc = True
        else:
            out.append(byte)
    assert not esc
    return out


async def setup(dut):
    Clock(dut.clk, CLK_NS, unit="ns").start()
    dut.rx.value = 1
    dut.snapshot.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 6)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def send_uart_wire(dut, data):
    await FallingEdge(dut.clk)
    for byte in data:
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            dut.rx.value = bit
            await ClockCycles(dut.clk, CPB)
    dut.rx.value = 1


async def receive_uart_byte(dut):
    await FallingEdge(dut.tx)
    await ClockCycles(dut.clk, CPB // 2)
    value = 0
    for bit in range(8):
        await ClockCycles(dut.clk, CPB)
        value |= int(dut.tx.value) << bit
    await ClockCycles(dut.clk, CPB)
    assert dut.tx.value == 1
    return value


async def monitor_tx(dut, messages):
    current = []
    while True:
        byte = await receive_uart_byte(dut)
        if not current:
            if byte == FLAG:
                current = [byte]
        else:
            current.append(byte)
            if len(current) >= 3 and byte == FLAG:
                await messages.put(current)
                current = []


async def configure_peer(dut, messages):
    sequence = 0
    commands = []
    for _ in range(30):
        wire = await with_timeout(messages.get(), 2, "ms")
        if wire == [FLAG, 0, FLAG]:
            await send_uart_wire(dut, wire_packet(0, [64, 0]))
            continue
        content = unescape(wire[2:-1])
        channel, payload = content[2], content[4:]
        commands.append((channel, payload))
        if channel == 0:
            advert = packet(0, [0, 0x81, 4] + le32(25), sequence)
            sequence += 1
            await send_uart_wire(dut, wire_packet(1, advert))
        elif payload[0] == 0xFE:
            report_id = payload[1]
            interval = 10000 if report_id == 0x05 else 2500
            response = packet(2, [0xFC, report_id, 0, 0, 0]
                              + le32(interval) + [0] * 8, sequence)
            sequence += 1
            await send_uart_wire(dut, wire_packet(1, response))
        await ClockCycles(dut.clk, 100)
        if dut.configured.value:
            return commands
    raise AssertionError(
        f"full host never configured; commands={commands} "
        f"queries={int(dut.bsn_query_count.value)} "
        f"timeouts={int(dut.bsn_timeout_count.value)} "
        f"frame_errors={int(dut.uart_frame_error_count.value)} "
        f"length_errors={int(dut.length_error_count.value)}")


def report(report_id, sequence, values):
    return [report_id, sequence, 3, 0] + sum((le16(v) for v in values), [])


@cocotb.test()
async def physical_rx_and_tx_share_packets_then_reset_invalidates_samples(dut):
    await setup(dut)
    messages = Queue()
    monitor = cocotb.start_soon(monitor_tx(dut, messages))
    commands = await configure_peer(dut, messages)
    assert dut.configured.value == 1
    assert [payload[:2] for channel, payload in commands if channel == 2] == [
        [0xFD, 0x05], [0xFD, 0x01], [0xFD, 0x02],
        [0xFE, 0x05], [0xFE, 0x01], [0xFE, 0x02],
    ]

    records = ([0xFB] + le32(0)
               + report(0x01, 1, [256, -256, 128])
               + report(0x02, 1, [512, -512, 0])
               + report(0x05, 1, [1, 2, 3, 16384, 4]))
    await send_uart_wire(dut, wire_packet(1, packet(3, records, 1)))
    for _ in range(2000):
        if dut.accel_has_sample.value and dut.gyro_has_sample.value \
                and dut.rotation_has_sample.value:
            break
        await RisingEdge(dut.clk)
    assert dut.accel_has_sample.value == 1
    assert int(dut.accel_x.value) == 256

    await send_uart_wire(dut, wire_packet(1, packet(1, [1], 2)))
    for _ in range(1000):
        if int(dut.sensor_reset_count.value) == 1:
            break
        await RisingEdge(dut.clk)
    assert int(dut.sensor_reset_count.value) == 1
    await ClockCycles(dut.clk, 3)
    assert dut.configured.value == 0
    assert dut.accel_has_sample.value == 0
    assert dut.gyro_has_sample.value == 0
    assert dut.rotation_has_sample.value == 0
    monitor.cancel()
