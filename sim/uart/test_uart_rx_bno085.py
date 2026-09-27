"""BNO085 wire-timing checks for the existing uart_rx (not a packet decoder).

Run with DUT clock 100 MHz, divider 33:
make TOP=uart_rx UART_RX_CLKS_PER_BIT=33 \
    COCOTB_TEST_MODULES=test_uart_rx_bno085

Sender timing is independent: exactly 3,000,000 baud on average, represented
with cumulative rational bit deadlines rounded to 1 ps simulation resolution.
Each deadline has <1 ps quantization error; it does NOT use the DUT divider.
Also stress +/-100 ppm sender error (a test budget, not a verified crystal spec).
All 256 byte values are streamed without extra inter-byte idle at four start
phases. Check exact order/count, no frame errors, and one-cycle valid pulses.
"""
from fractions import Fraction

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from test_uart_rx import CLKS_PER_BIT, setup


async def send_stream(dut, payload, baud):
    bit_ps = Fraction(10**12, 1) / baud
    deadline = 0
    bit_count = 0
    for byte in payload:
        bits = [0] + [(byte >> i) & 1 for i in range(8)] + [1]
        for bit in bits:
            dut.rx.value = bit
            bit_count += 1
            next_deadline = int(bit_count * bit_ps)
            await Timer(next_deadline - deadline, unit="ps")
            deadline = next_deadline
    dut.rx.value = 1


async def exercise(dut, ppm):
    assert CLKS_PER_BIT == 33, "Use UART_RX_CLKS_PER_BIT=33 for BNO085 timing"
    await setup(dut)
    received, errors, wide_pulses = [], [], []

    async def watch():
        previous = 0
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            valid = int(dut.valid.value)
            if valid:
                received.append(int(dut.data.value))
            if valid and previous:
                wide_pulses.append(1)
            if dut.frame_error.value:
                errors.append(1)
            previous = valid

    task = cocotb.start_soon(watch())
    payload = list(range(256))
    expected = []
    baud = Fraction(3_000_000) * Fraction(1_000_000 + ppm, 1_000_000)
    try:
        for phase_ps in (0, 2500, 5000, 7500):
            await FallingEdge(dut.clk)
            if phase_ps:
                await Timer(phase_ps, unit="ps")
            await send_stream(dut, payload, baud)
            expected.extend(payload)
            await Timer(2000, unit="ns")
            assert received == expected, f"byte mismatch at phase={phase_ps} ps, ppm={ppm}"
            assert not errors, f"framing error at phase={phase_ps} ps, ppm={ppm}"
            assert not wide_pulses, "valid lasted more than one clock"
    finally:
        task.cancel()


@cocotb.test()
async def exact_3_mbaud_all_bytes_all_phases(dut):
    await exercise(dut, 0)


@cocotb.test()
async def sender_crystal_fast_budget(dut):
    await exercise(dut, 100)


@cocotb.test()
async def sender_crystal_slow_budget(dut):
    await exercise(dut, -100)
