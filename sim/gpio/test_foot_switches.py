"""Specification: two active-low center-sole switches, left bit0/right bit1.

At each 1 kHz sample, three consecutive closed readings make contact and eight
consecutive open readings release it. The foot and switch masks are identical.
Each foot has a saturating age, one-clock change pulse and confirmation timestamp.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, ReadOnly, ClockCycles


async def setup(d):
    d.clk.value = 0; d.rst.value = 1; d.sample.value = 0
    d.raw_n.value = 0b11; d.now_us.value = 0
    cocotb.start_soon(Clock(d.clk, 10, unit='ns').start())
    await ClockCycles(d.clk, 4)
    await FallingEdge(d.clk); d.rst.value = 0
    await ClockCycles(d.clk, 4)


async def set_raw(d, bits):
    await FallingEdge(d.clk); d.raw_n.value = bits
    await ClockCycles(d.clk, 4)  # allow two synchronizer stages to settle


async def tick(d, stamp):
    await FallingEdge(d.clk); d.sample.value = 1; d.now_us.value = stamp
    await RisingEdge(d.clk); await ReadOnly()
    result = (int(d.switches.value), int(d.feet.value),
              int(d.left_ticks.value), int(d.right_ticks.value),
              int(d.switch_changed.value), int(d.foot_changed.value),
              int(d.latest_change_us.value), int(d.switch_change_us.value))
    await FallingEdge(d.clk); d.sample.value = 0
    return result


@cocotb.test()
async def reset_and_left_right_bit_order(d):
    await setup(d)
    assert (int(d.switches.value), int(d.feet.value)) == (0, 0)
    for bit in range(2):
        await set_raw(d, 0b11 ^ (1 << bit))
        for n in range(2):
            assert (await tick(d, 1000 * (20 * bit + n + 1)))[:2] == (0, 0)
        stamp = 1000 * (20 * bit + 3)
        s = await tick(d, stamp)
        assert s[:2] == (1 << bit, 1 << bit)
        assert s[4:7] == (1 << bit, 1 << bit, stamp)
        assert ((s[7] >> (64 * bit)) & ((1 << 64) - 1)) == stamp
        await set_raw(d, 0b11)
        for n in range(8): s = await tick(d, stamp + 1000 * (n + 1))
        assert s[:2] == (0, 0)
    await FallingEdge(d.clk); d.rst.value = 1
    await RisingEdge(d.clk); await ReadOnly()
    assert int(d.switches.value) == 0 and int(d.switch_change_us.value) == 0


@cocotb.test()
async def bounce_resets_candidate_and_release_needs_eight(d):
    await setup(d)
    await set_raw(d, 0b10)  # left center switch closed
    assert (await tick(d, 1000))[0] == 0
    assert (await tick(d, 2000))[0] == 0
    await set_raw(d, 0b11)
    assert (await tick(d, 3000))[0] == 0
    await set_raw(d, 0b10)
    assert (await tick(d, 4000))[0] == 0
    assert (await tick(d, 5000))[0] == 0
    assert (await tick(d, 6000))[:2] == (1, 1)
    await set_raw(d, 0b11)
    for t in range(7000, 14000, 1000):
        s = await tick(d, t)
        assert s[:2] == (1, 1) and s[4] == 0
    await set_raw(d, 0b10)
    assert (await tick(d, 14000))[:2] == (1, 1)
    await set_raw(d, 0b11)
    for t in range(15000, 22000, 1000): assert (await tick(d, t))[0] == 1
    s = await tick(d, 22000)
    assert s[:2] == (0, 0) and s[4:7] == (1, 1, 22000)


@cocotb.test()
async def both_feet_are_independent_and_ages_reset_on_change(d):
    await setup(d)
    await set_raw(d, 0b00)
    for t in (1000, 2000, 3000): s = await tick(d, t)
    assert s[:2] == (3, 3) and s[4:6] == (3, 3)
    for t in (4000, 5000, 6000): s = await tick(d, t)
    assert s[2:4] == (3, 3)
    await set_raw(d, 0b01)  # right remains closed, left now opens
    for t in range(7000, 15000, 1000): s = await tick(d, t)
    assert s[:4] == (2, 2, 0, 11)
    assert s[4:6] == (1, 1)
    assert s[6] == 14000 and (s[7] >> 64) == 3000
    await set_raw(d, 0b11)
    for t in range(15000, 23000, 1000): s = await tick(d, t)
    assert s[:4] == (0, 0, 8, 0)
    assert s[4:6] == (2, 2)


@cocotb.test()
async def short_glitch_silence_and_saturating_age(d):
    await setup(d)
    await set_raw(d, 0b01)
    await set_raw(d, 0b11)  # right pulse disappears before a sample
    for t in (1000, 2000, 3000): s = await tick(d, t)
    assert s[0] == 0 and s[6] == 0
    await set_raw(d, 0b01)
    for t in (4000, 5000, 6000): s = await tick(d, t)
    assert s[:2] == (2, 2)
    await FallingEdge(d.clk); d.right_ticks.value = 65534
    assert (await tick(d, 7000))[3] == 65535
    assert (await tick(d, 8000))[3] == 65535
    await ClockCycles(d.clk, 20)
    assert int(d.switch_changed.value) == 0 and int(d.latest_change_us.value) == 6000
