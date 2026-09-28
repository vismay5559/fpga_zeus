"""Executable specification for rtl/gpio/foot_switches.v.

Four active-low independent contacts in bit order left toe, left heel, right toe,
right heel. Inputs pass two clock-domain flip-flops, then are checked only at a
1 kHz `sample` pulse. Three consecutive closed samples make contact; eight
consecutive open samples break it. A raw sample matching the accepted state
clears its candidate count. Both timeouts include the transition sample.

Outputs: stable switches[3:0], feet[1:0] (left bit0/right bit1, OR of each
foot's toe and heel), saturating left/right age in sample ticks, a one-clock
switch_changed pulse[3:0], foot_changed pulse[1:0], 4x64-bit per-switch
transition timestamps, and latest_change_us. Only a confirmed switch change
updates timestamps. A foot age resets only when the OR-derived foot state
changes, not when toe/heel shift contact on one foot. Reset marks all contacts
open, zeroes ages/timestamps, and assumes raw high until synchronized.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, ReadOnly, ClockCycles


async def setup(d):
    d.clk.value=0; d.rst.value=1; d.sample.value=0
    d.raw_n.value=0b1111; d.now_us.value=0
    cocotb.start_soon(Clock(d.clk,10,unit='ns').start())
    await ClockCycles(d.clk,4)
    await FallingEdge(d.clk); d.rst.value=0
    await ClockCycles(d.clk,4)


async def set_raw(d, bits):
    await FallingEdge(d.clk); d.raw_n.value=bits
    # Move through the two flip-flops before making a sample.
    await ClockCycles(d.clk,4)


async def tick(d, stamp):
    await FallingEdge(d.clk); d.sample.value=1; d.now_us.value=stamp
    await RisingEdge(d.clk); await ReadOnly()
    output = (int(d.switches.value), int(d.feet.value),
              int(d.left_ticks.value), int(d.right_ticks.value),
              int(d.switch_changed.value), int(d.foot_changed.value),
              int(d.latest_change_us.value), int(d.switch_change_us.value))
    await FallingEdge(d.clk); d.sample.value=0
    return output


@cocotb.test()
async def reset_and_active_low_contact_order(d):
    await setup(d)
    assert (int(d.switches.value),int(d.feet.value),int(d.latest_change_us.value))==(0,0,0)
    for i in range(4):
        await set_raw(d, 0b1111 ^ (1<<i))
        for n in range(2):
            s=await tick(d,1000*(i*20+n+1))
            assert not (s[0] & (1<<i))
        stamp=1000*(i*20+3)
        s=await tick(d,stamp)
        assert s[0] & (1<<i)
        assert s[4]==(1<<i)
        assert (s[7]>>(64*i)) & ((1<<64)-1)==stamp
        assert s[6]==stamp
        assert s[1]==(1 if i<2 else 2)
        await set_raw(d,0b1111)
        for n in range(8):s=await tick(d,stamp+1000*(n+1))
        assert s[0]==0 and s[1]==0
    await FallingEdge(d.clk);d.rst.value=1
    await RisingEdge(d.clk);await ReadOnly()
    assert int(d.switches.value)==0 and int(d.switch_change_us.value)==0


@cocotb.test()
async def bounce_cancels_candidates_and_break_is_eight_samples(d):
    await setup(d)
    await set_raw(d,0b1110)
    assert (await tick(d,1000))[0]==0
    assert (await tick(d,2000))[0]==0
    await set_raw(d,0b1111)
    assert (await tick(d,3000))[0]==0
    await set_raw(d,0b1110)
    assert (await tick(d,4000))[0]==0
    assert (await tick(d,5000))[0]==0
    assert (await tick(d,6000))[:2]==(1,1)
    await set_raw(d,0b1111)
    for t in range(7000,14000,1000):
        s=await tick(d,t)
        assert s[:2]==(1,1) and s[4]==0
    await set_raw(d,0b1110)
    assert (await tick(d,14000))[:2]==(1,1)
    await set_raw(d,0b1111)
    for t in range(15000,22000,1000): assert (await tick(d,t))[0]==1
    s=await tick(d,22000)
    assert s[0]==0 and s[1]==0 and s[4]==1 and s[5]==1
    assert s[6]==22000


@cocotb.test()
async def both_points_transfer_without_false_foot_lift(d):
    await setup(d)
    await set_raw(d,0b1100)
    for t in (1000,2000,3000):s=await tick(d,t)
    assert s[:2]==(3,1) and s[4]==3 and s[5]==1
    for t in (4000,5000,6000):s=await tick(d,t)
    assert s[2]==3 and s[3]==6
    await set_raw(d,0b1101)  # heel still closed, toe now open
    for t in range(7000,15000,1000):s=await tick(d,t)
    assert s[:2]==(2,1) and s[5]==0 and s[2]==11
    assert ((s[7]>>64)&((1<<64)-1))==3000  # heel timestamp retained
    assert (s[7]&((1<<64)-1))==14000
    await set_raw(d,0b1111)
    for t in range(15000,23000,1000):s=await tick(d,t)
    assert s[:4]==(0,0,0,22)
    assert s[5]==1  # foot finally lifts


@cocotb.test()
async def short_glitches_silence_and_saturating_age(d):
    await setup(d)
    await set_raw(d,0b0111)  # right heel
    await set_raw(d,0b1111)  # gone before any 1k sample
    for t in (1000,2000,3000):s=await tick(d,t)
    assert s[0]==0 and s[6]==0
    await set_raw(d,0b0111)
    for t in (4000,5000,6000):s=await tick(d,t)
    assert s[:2]==(8,2)
    await FallingEdge(d.clk); d.right_ticks.value=65534
    s=await tick(d,7000)
    assert s[3]==65535
    s=await tick(d,8000)
    assert s[3]==65535
    await ClockCycles(d.clk,20)
    assert int(d.switch_changed.value)==0 and int(d.latest_change_us.value)==6000
