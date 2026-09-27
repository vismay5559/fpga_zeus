"""Timer spec: 100 clocks/us, sample every 1000 us; reset restarts phase."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, ClockCycles

@cocotb.test()
async def microseconds_and_sample_interval(d):
    d.rst.value=1
    cocotb.start_soon(Clock(d.clk,10,unit='ns').start())
    await ClockCycles(d.clk,3)
    await FallingEdge(d.clk); d.rst.value=0
    # Check both microsecond and millisecond boundaries using real defaults.
    for us in range(1,2002):
        await ClockCycles(d.clk,100); await ReadOnly()
        assert int(d.timestamp_us.value)==us
        assert int(d.sample.value)==(us%1000==0)
    await FallingEdge(d.clk); d.rst.value=1
    await RisingEdge(d.clk); await ReadOnly()
    assert int(d.timestamp_us.value)==0 and not d.sample.value
