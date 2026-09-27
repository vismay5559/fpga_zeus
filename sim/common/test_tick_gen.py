import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

DIV = 10  # must match -Ptick_gen.DIV in the Makefile


async def reset(dut):
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0


@cocotb.test()
async def tick_stays_low_in_reset(dut):
    Clock(dut.clk, 10, unit="ns").start()
    dut.rst.value = 1
    for _ in range(3 * DIV):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert dut.tick.value == 0, "tick pulsed during reset"


@cocotb.test()
async def tick_period_is_div(dut):
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)

    ticks = []
    for cycle in range(6 * DIV):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.tick.value == 1:
            ticks.append(cycle)

    assert len(ticks) >= 5, f"expected >=5 ticks, got {ticks}"
    gaps = [b - a for a, b in zip(ticks, ticks[1:])]
    assert all(g == DIV for g in gaps), f"tick spacing {gaps}, expected {DIV}"
    dut._log.info("ticks at cycles %s, spacing %d", ticks, DIV)
