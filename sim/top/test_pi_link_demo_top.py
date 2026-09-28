"""Real bit-level SPI against board demo: switch pin -> synchronized/debounced
contact -> ZFP1 bytes at 464..479 -> Pi decoder. Simulation shortens the clock
microsecond divider to one cycle but keeps the SPI mode/10 MHz wire timing.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, ClockCycles
from pi.fpga_protocol import decode

async def wait_ready(d, limit=2500):
    for _ in range(limit):
        if int(d.pi_data_ready.value): return
        await RisingEdge(d.CLK100MHZ)
    assert False, 'demo did not publish a snapshot'

async def spi_read(d):
    d.pi_cs_n.value=0
    await Timer(150,unit='ns')
    frame=bytearray()
    for _ in range(640):
        value=0
        for _ in range(8):
            d.pi_sck.value=1
            value=(value<<1)|int(d.pi_miso.value)
            await Timer(50,unit='ns')
            d.pi_sck.value=0
            await Timer(50,unit='ns')
        frame.append(value)
    await Timer(150,unit='ns')
    d.pi_cs_n.value=1
    await Timer(300,unit='ns')
    return decode(frame)

@cocotb.test()
async def real_contact_bits_and_change_time_reach_pi(d):
    d.CLK100MHZ.value=0; d.btn.value=0; d.foot_sw_n.value=3
    d.pi_sck.value=0; d.pi_cs_n.value=1
    cocotb.start_soon(Clock(d.CLK100MHZ,10,unit='ns').start())
    await ClockCycles(d.CLK100MHZ,50)
    await wait_ready(d)
    # First packet already captured. Closing the left sole switch while it is held
    # must not alter its bytes. The switch will settle during this read.
    d.foot_sw_n.value=2
    first=await spi_read(d)
    assert first.flags==0x80000004 and first.contacts[0:2]==(0,0)
    assert first.contacts[5]==0
    assert int(d.led.value)&2
    await wait_ready(d)
    second=await spi_read(d)
    assert second.contacts[0:2]==(1,1)
    assert second.contacts[3]>0
    assert second.contacts[5]>first.timestamp_us
    assert second.sequence>first.sequence
    # Eight subsequent 1k ticks of open contact finally release it.
    d.foot_sw_n.value=3
    await ClockCycles(d.CLK100MHZ,8500)
    assert (int(d.led.value)&2)==0
