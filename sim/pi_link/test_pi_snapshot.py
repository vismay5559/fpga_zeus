"""Snapshot executable spec: 640-byte ZFP1, atomic capture, CRC, backpressure.
Ports: clk/rst, sample, timestamp_us[63:0], flags[31:0], payload[4847:0],
rewind; sample_ready/sample_accepted, dropped/sequence_next[31:0], busy;
out_data[7:0], out_valid/out_ready/out_last. Payload byte 0 is bits 7:0.
Every sample advances sequence even when busy; busy drops saturate. Accepted
sample owns an immutable frame until final ready/valid transfer. Rewind while
streaming restarts byte zero; partial SPI reads can retry the SAME frame.
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, ReadOnly
from pi.fpga_protocol import encode, PAYLOAD_SIZE

async def step(d, **values):
    await FallingEdge(d.clk)
    for key, val in values.items(): getattr(d, key).value = val
    await RisingEdge(d.clk)
    await ReadOnly()

async def setup(d):
    d.clk.value = 0; d.rst.value = 1; d.sample.value = 0
    d.out_ready.value = 0; d.rewind.value = 0
    d.payload.value = 0; d.timestamp_us.value = 0; d.flags.value = 0
    cocotb.start_soon(Clock(d.clk, 10, unit='ns').start())
    await step(d); await step(d, rst=0)

async def capture(d, data, stamp=123, flags=7):
    assert d.sample_ready.value
    await step(d, sample=1, payload=int.from_bytes(data, 'little'), timestamp_us=stamp, flags=flags)
    await step(d, sample=0, payload=0, timestamp_us=0, flags=0)
    for _ in range(650):
        if d.out_valid.value: return
        await step(d)
    assert False, 'CRC/frame preparation never completed'

async def drain(d, stalls=False):
    out = bytearray(); rng = random.Random(991)
    while d.out_valid.value:
        data, last = int(d.out_data.value), int(d.out_last.value)
        if stalls:
            for _ in range(rng.randrange(3)):
                await step(d, out_ready=0)
                assert int(d.out_data.value) == data and int(d.out_last.value) == last
        out.append(data)
        assert last == (len(out) == 640)
        await step(d, out_ready=1)
    await step(d, out_ready=0)
    return bytes(out)

@cocotb.test()
async def atomic_crc_and_stalled_output(d):
    await setup(d)
    rng = random.Random(7)
    data = bytes(rng.randrange(256) for _ in range(PAYLOAD_SIZE))
    await capture(d, data, 2**48+7, 0x1234)
    assert await drain(d, True) == encode(data, 0, 2**48+7, 0, 0x1234)

@cocotb.test()
async def busy_drops_are_counted_without_tearing(d):
    await setup(d)
    data = bytes([0xA6])*PAYLOAD_SIZE
    await capture(d, data)
    await step(d, sample=1); await step(d, sample=1); await step(d, sample=0)
    assert int(d.dropped.value) == 2
    assert await drain(d) == encode(data, 0, 123, 0, 7)
    await capture(d, bytes(PAYLOAD_SIZE))
    assert await drain(d) == encode(bytes(PAYLOAD_SIZE), 3, 123, 2, 7)

@cocotb.test()
async def partial_read_rewinds_and_reset_discards(d):
    await setup(d)
    data = bytes(i % 256 for i in range(PAYLOAD_SIZE))
    await capture(d, data)
    for _ in range(77): await step(d, out_ready=1)
    await step(d, out_ready=0, rewind=1)
    await step(d, rewind=0)
    assert await drain(d) == encode(data, 0, 123, 0, 7)
    await capture(d, data)
    await step(d, rst=1)
    assert not d.out_valid.value and not d.busy.value
    await step(d, rst=0)
    await capture(d, bytes(PAYLOAD_SIZE))
    assert await drain(d) == encode(bytes(PAYLOAD_SIZE), 0, 123, 0, 7)
