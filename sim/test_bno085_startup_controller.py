"""BNO085 startup-controller specification using a simulated sensor peer.

The peer decodes the DUT's physical UART TX, grants writes with protocol-0 BSNs,
and injects validated receive packets for advertisements, reset notices and Get
Feature Responses. This verifies flow control and actual command bytes together.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout

CLK_NS = 10
CPB = int(os.getenv("BNO_START_CLKS_PER_BIT", "4"))
FLAG = 0x7E
ESC = 0x7D


def le32(value):
    return [(value >> shift) & 0xFF for shift in (0, 8, 16, 24)]


def packet(channel, payload, sequence=0):
    length = 4 + len(payload)
    return [length & 0xFF, length >> 8, channel, sequence] + payload


def unescape(data):
    out, escaped = [], False
    for byte in data:
        if escaped:
            out.append(byte ^ 0x20)
            escaped = False
        elif byte == ESC:
            escaped = True
        else:
            out.append(byte)
    assert not escaped
    return out


async def setup(dut):
    Clock(dut.clk, CLK_NS, unit="ns").start()
    dut.packet_start.value = 0
    dut.packet_protocol.value = 0
    dut.packet_len.value = 0
    dut.in_data.value = 0
    dut.in_valid.value = 0
    dut.in_first.value = 0
    dut.in_last.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 6)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def send_validated(dut, protocol, data):
    await FallingEdge(dut.clk)
    dut.packet_protocol.value = protocol
    dut.packet_len.value = len(data)
    dut.packet_start.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.packet_start.value = 0
    for index, byte in enumerate(data):
        while not dut.in_ready.value:
            await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.in_data.value = byte
        dut.in_valid.value = 1
        dut.in_first.value = index == 0
        dut.in_last.value = index == len(data) - 1
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.in_valid.value = 0
        dut.in_first.value = 0
        dut.in_last.value = 0


async def send_bsn(dut, available=64):
    await send_validated(dut, 0, [available & 0xFF, available >> 8])


async def send_advertisement(dut, timeout_ms=25, sequence=0):
    payload = [0x00, 0x81, 4] + le32(timeout_ms)
    await send_validated(dut, 1, packet(0, payload, sequence))


async def send_feature_response(dut, report_id, interval, sequence=0):
    payload = [0xFC, report_id, 0, 0, 0] + le32(interval) + [0] * 8
    assert len(payload) == 17
    await send_validated(dut, 1, packet(2, payload, sequence))


async def send_reset_notice(dut, sequence=0):
    await send_validated(dut, 1, packet(1, [0x01], sequence))


async def receive_uart_byte(dut):
    await FallingEdge(dut.tx)
    await ClockCycles(dut.clk, CPB // 2)
    assert dut.tx.value == 0
    value = 0
    for bit in range(8):
        await ClockCycles(dut.clk, CPB)
        value |= int(dut.tx.value) << bit
    await ClockCycles(dut.clk, CPB)
    assert dut.tx.value == 1
    return value


async def wire_monitor(dut, messages):
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


def start_monitor(dut):
    messages = Queue()
    task = cocotb.start_soon(wire_monitor(dut, messages))
    return messages, task


def decode_shtp(wire):
    assert wire[0] == FLAG and wire[1] == 1 and wire[-1] == FLAG
    return unescape(wire[2:-1])


def command_summary(content):
    length = content[0] | (content[1] << 8)
    assert length == len(content)
    return content[2], content[4:]


async def emulate_until_configured(dut, messages, wrong_accel_once=False,
                                    first_bsn_small=False, expect_advert_request=True):
    commands = []
    small_sent = False
    wrong_sent = False
    sequence = 0
    for _ in range(80):
        try:
            wire = await with_timeout(messages.get(), 1, "ms")
        except TimeoutError:
            raise AssertionError(
                f"no TX message: main_state={int(dut.main_state.value)} "
                f"rx_state={int(dut.rx_state.value)} configured={dut.configured.value} "
                f"queries={int(dut.bsn_query_count.value)}")
        if wire == [FLAG, 0, FLAG]:
            if first_bsn_small and not small_sent:
                small_sent = True
                await send_bsn(dut, 4)
            else:
                await send_bsn(dut, 64)
            continue

        content = decode_shtp(wire)
        channel, payload = command_summary(content)
        commands.append((channel, payload))
        if channel == 0 and payload == [0, 1]:
            await send_advertisement(dut, timeout_ms=25, sequence=sequence)
            sequence += 1
        elif channel == 2 and payload[:1] == [0xFE]:
            report_id = payload[1]
            interval = 10000 if report_id == 0x05 else 2500
            if wrong_accel_once and report_id == 0x01 and not wrong_sent:
                interval = 3000
                wrong_sent = True
            await send_feature_response(dut, report_id, interval, sequence)
            sequence += 1

        await ClockCycles(dut.clk, 4)
        if dut.configured.value:
            break
    else:
        assert False, "controller never reached configured"

    if expect_advert_request:
        assert commands[0] == (0, [0, 1])
    return commands


def expected_profile(include_advert=True):
    set_rv = [0xFD, 0x05, 0, 0, 0] + le32(10000) + [0] * 8
    set_accel = [0xFD, 0x01, 0, 0, 0] + le32(2500) + [0] * 8
    set_gyro = [0xFD, 0x02, 0, 0, 0] + le32(2500) + [0] * 8
    result = [(2, set_rv), (2, set_accel), (2, set_gyro),
              (2, [0xFE, 0x05]), (2, [0xFE, 0x01]), (2, [0xFE, 0x02])]
    return ([(0, [0, 1])] + result) if include_advert else result


@cocotb.test()
async def configures_exact_400_400_100_profile_with_one_bsn_per_write(dut):
    await setup(dut)
    messages, monitor = start_monitor(dut)
    commands = await emulate_until_configured(dut, messages)
    monitor.cancel()
    assert commands == expected_profile()
    assert dut.rotation_confirmed.value == 1
    assert dut.accel_confirmed.value == 1
    assert dut.gyro_confirmed.value == 1
    assert int(dut.bsn_query_count.value) == len(commands)
    assert int(dut.advertised_uart_timeout_ms.value) == 25
    assert int(dut.confirmation_error_count.value) == 0


@cocotb.test()
async def insufficient_bsn_blocks_command_then_queries_again(dut):
    await setup(dut)
    messages, monitor = start_monitor(dut)
    commands = await emulate_until_configured(dut, messages, first_bsn_small=True)
    monitor.cancel()
    assert commands == expected_profile()
    assert int(dut.bsn_query_count.value) == len(commands) + 1
    assert int(dut.bsn_timeout_count.value) >= 1


@cocotb.test()
async def wrong_feature_confirmation_forces_complete_retry(dut):
    await setup(dut)
    messages, monitor = start_monitor(dut)
    commands = await emulate_until_configured(dut, messages, wrong_accel_once=True)
    monitor.cancel()
    expected = expected_profile()
    assert commands[:len(expected)] == expected
    assert commands[len(expected):] == expected_profile(include_advert=False)
    assert int(dut.confirmation_error_count.value) == 1
    assert int(dut.config_retry_count.value) == 1


@cocotb.test()
async def reset_notice_invalidates_and_reconfigures_once_per_episode(dut):
    await setup(dut)
    messages, monitor = start_monitor(dut)
    await emulate_until_configured(dut, messages)
    assert dut.configured.value == 1

    pulse_seen = [False]
    async def watch_pulse():
        while not pulse_seen[0]:
            await RisingEdge(dut.clk)
            if dut.sensor_reset_pulse.value:
                pulse_seen[0] = True
    watcher = cocotb.start_soon(watch_pulse())
    await send_reset_notice(dut, sequence=1)
    await send_reset_notice(dut, sequence=2)
    await ClockCycles(dut.clk, 3)
    assert pulse_seen[0]
    watcher.cancel()
    assert dut.configured.value == 0
    assert int(dut.sensor_reset_count.value) == 1

    commands = await emulate_until_configured(
        dut, messages, expect_advert_request=False)
    monitor.cancel()
    assert commands == expected_profile(include_advert=False)
    assert dut.configured.value == 1
