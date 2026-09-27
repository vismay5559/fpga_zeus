"""Physical mode-0 SPI against the real snapshot layer: decode with Pi parser.
100 MHz clk, SPI at 10 MHz, arbitrary initial phase. Test aborted transactions,
empty reads, reader stalls, repeated frames, and all 640 bytes including CRC.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, FallingEdge, RisingEdge, ReadOnly
from pi.fpga_protocol import PAYLOAD_SIZE, encode, decode

async def setup(d):
    d.rst.value=1; d.sample.value=0; d.payload.value=0
    d.timestamp_us.value=0; d.flags.value=0
    d.spi_cs_n.value=1; d.spi_sck.value=0
    cocotb.start_soon(Clock(d.clk,10,unit='ns').start())
    await Timer(100,unit='ns'); await FallingEdge(d.clk); d.rst.value=0
    await Timer(100,unit='ns')

async def sample(d, payload, stamp=1000):
    await FallingEdge(d.clk)
    d.payload.value=int.from_bytes(payload,'little'); d.timestamp_us.value=stamp
    d.sample.value=1
    await FallingEdge(d.clk); d.sample.value=0; d.payload.value=0
    for _ in range(700):
        if d.data_ready.value: return
        await RisingEdge(d.clk)
    assert False,'snapshot not ready'

async def spi(d, bits=5120, half_ns=50):
    await Timer(17,unit='ns')
    d.spi_cs_n.value=0
    await Timer(150,unit='ns')
    value=0; result=bytearray()
    for i in range(bits):
        d.spi_sck.value=1
        value=(value<<1)|int(d.spi_miso.value)
        await Timer(half_ns,unit='ns')
        d.spi_sck.value=0
        await Timer(half_ns,unit='ns')
        if i%8==7: result.append(value); value=0
    await Timer(150,unit='ns'); d.spi_cs_n.value=1
    await Timer(300,unit='ns')
    return bytes(result)

@cocotb.test()
async def physical_spi_frame_and_idle(d):
    await setup(d)
    assert await spi(d,16)==b'\0\0'
    payload=bytes(PAYLOAD_SIZE)
    await sample(d,payload,2**40+1000)
    wire=await spi(d)
    assert wire==encode(payload,0,2**40+1000)
    assert decode(wire).timestamp_us==2**40+1000
    assert not d.data_ready.value
    await sample(d,payload,2000)
    assert await spi(d,half_ns=100)==encode(payload,1,2000)

@cocotb.test()
async def aborted_reads_replay_unchanged_snapshot(d):
    await setup(d)
    payload=bytes(i%256 for i in range(PAYLOAD_SIZE))
    await sample(d,payload)
    for bits in (1,7,8,9,77,5119):
        await spi(d,bits)
        assert d.data_ready.value
    # Busy sample must not replace the held frame.
    await sample(d,bytes(PAYLOAD_SIZE),2000)
    assert int(d.dropped.value)==1
    assert await spi(d)==encode(payload,0,1000)
    await sample(d,bytes(PAYLOAD_SIZE),3000)
    assert await spi(d)==encode(bytes(PAYLOAD_SIZE),2,3000,1)
