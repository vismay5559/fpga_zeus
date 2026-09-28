"""Real bit-level BNO085 UART and switch inputs through the Arty demo to
ZFP1 SPI packets and the Pi decoder. Simulation shortens timer/UART dividers but
keeps SPI mode 0 and 10 MHz wire timing.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, FallingEdge, ClockCycles
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
    d.pi_sck.value=0; d.pi_cs_n.value=1; d.imu_rx.value=1
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


async def send_imu_bytes(d, wire):
    # Fast simulation divider; the focused BNO tests separately check 3 Mbaud.
    await FallingEdge(d.CLK100MHZ)
    for byte in wire:
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            d.imu_rx.value = bit
            await ClockCycles(d.CLK100MHZ, 4)
    d.imu_rx.value = 1


@cocotb.test()
async def serial_imu_reaches_pi_then_freshness_clears(d):
    from test_bno085_imu_rx import le32, sensor, shtp_wire
    d.CLK100MHZ.value=0; d.btn.value=0; d.foot_sw_n.value=3
    d.pi_sck.value=0; d.pi_cs_n.value=1; d.imu_rx.value=1
    cocotb.start_soon(Clock(d.CLK100MHZ,10,unit='ns').start())
    await ClockCycles(d.CLK100MHZ,50)
    await wait_ready(d)  # first immutable packet is already in flight
    reports = ([0xFB] + le32(-7)
               + sensor(0x01, 10, [-256, 512, 126])
               + sensor(0x02, 20, [-1, -2, -3])
               + sensor(0x05, 30, [-8192, 4096, -1, 16384, 0x1234]))
    await send_imu_bytes(d, shtp_wire(reports, sequence=44))
    # The in-flight packet remains unchanged despite newly arrived reports.
    old=await spi_read(d)
    assert all(not report.valid for report in old.imu)
    await wait_ready(d)
    fresh=await spi_read(d)
    a,g,q=fresh.imu
    assert [r.valid for r in fresh.imu]==[True, True, True]
    assert [r.new for r in fresh.imu]==[True, True, True]
    assert a.raw==(-256,512,126,0) and a.q_point==8
    assert g.raw==(-1,-2,-3,0) and g.q_point==9
    assert q.raw==(-8192,4096,-1,16384) and q.q_point==14
    assert q.accuracy_raw==0x1234 and q.accuracy_q_point==12
    assert [r.report_sequence for r in fresh.imu]==[10,20,30]
    assert all(r.shtp_sequence==44 for r in fresh.imu)
    assert all(r.base_delta==-7 and r.capture_us>0 for r in fresh.imu)
    assert fresh.flags & 0x80000004 == 0x80000004
    await wait_ready(d)
    repeat=await spi_read(d)
    assert [r.valid for r in repeat.imu]==[True, True, True]
    assert [r.new for r in repeat.imu]==[False, False, False]
    assert [r.raw for r in repeat.imu]==[r.raw for r in fresh.imu]
    # A sensor reset invalidates retained values and increments the Pi diagnostic.
    from test_bno085_imu import packet, wire_packet
    await send_imu_bytes(d, wire_packet(1, packet(1, [1], 45)))
    for _ in range(3):
        await wait_ready(d)
        after_reset=await spi_read(d)
        if after_reset.diagnostics['sensor_resets']:
            break
    assert after_reset.diagnostics['sensor_resets']==1
    assert all(not report.valid and not report.new for report in after_reset.imu)
