"""Executable specification for rtl/fifo_sync.v.

Parameters: WIDTH >= 1 (default 8), DEPTH >= 2 (default 16); arbitrary DEPTH.
Ports:
  input clk, rst                 synchronous active-high reset
  input wr_en, [WIDTH-1:0] wr_data
  input rd_en
  output reg [WIDTH-1:0] rd_data  registered read result; holds until next read
  output reg rd_valid            one cycle per accepted read
  output full, empty             reflect current occupancy
  output reg [$clog2(DEPTH+1)-1:0] level
  output reg overflow, underflow one cycle per rejected write/read

All operations occur on rising clk. Decisions use occupancy BEFORE that edge:
* Read accepted iff rd_en and not empty; return the OLDEST stored word.
* Write accepted iff wr_en and (not full OR a read is accepted at this edge).
* Full + read + write: return old head, append new word, remain full, no error.
* Empty + read + write: store new word, reject read (underflow), no bypass.
* Rejected operations do not change stored data or pointers.
* level changes by accepted writes minus accepted reads. Capacity is DEPTH,
  not DEPTH-1. Pointers must wrap at DEPTH, including non-power-of-two depths.
* rd_valid/overflow/underflow describe ONLY this edge; consecutive events can
  keep a flag high for consecutive cycles. rd_data holds on idle/rejected read.
* Reset wins over all requests: level=0, empty=1, full=0, rd_data=0 and all
  event flags=0. Old storage is inaccessible; clearing the RAM is unnecessary.

Python uses an independent deque as the expected queue. Inputs change on falling
edges; outputs are checked after rising-edge HDL updates settle (ReadOnly).
Run: make TOP=fifo_sync FIFO_DEPTH=3 FIFO_WIDTH=16
"""
from collections import deque
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


class Bench:
    def __init__(self, dut):
        self.dut = dut
        self.depth = int(os.environ.get("FIFO_DEPTH", "16"))
        self.mask = (1 << len(dut.wr_data)) - 1
        self.queue = deque()
        self.last_data = 0
        self.cycles = 0

    async def step(self, wr=0, data=0, rd=0, rst=0):
        d = self.dut
        await FallingEdge(d.clk)
        d.rst.value = rst
        d.wr_en.value = wr
        d.wr_data.value = data & self.mask
        d.rd_en.value = rd

        # Decide using the queue as it was BEFORE the edge.
        pop = bool(rd and self.queue)
        push = bool(wr and (len(self.queue) < self.depth or pop))
        overflow, underflow = bool(wr and not push), bool(rd and not pop)
        if rst:
            self.queue.clear()
            self.last_data = 0
            pop = overflow = underflow = False
        else:
            if pop:
                self.last_data = self.queue.popleft()
            if push:
                self.queue.append(data & self.mask)

        await RisingEdge(d.clk)
        await ReadOnly()
        self.cycles += 1
        expected = dict(level=len(self.queue), empty=int(not self.queue),
                        full=int(len(self.queue) == self.depth),
                        rd_data=self.last_data, rd_valid=int(pop),
                        overflow=int(overflow), underflow=int(underflow))
        for name, value in expected.items():
            actual = int(getattr(d, name).value)
            assert actual == value, (
                f"cycle {self.cycles}: {name}={actual}, expected {value}; "
                f"wr={wr} rd={rd} rst={rst}, queue={list(self.queue)}"
            )


async def setup(dut):
    dut.rst.value = 1
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wr_data.value = 0
    Clock(dut.clk, 10, unit="ns").start()
    bench = Bench(dut)
    await bench.step(rst=1)
    await bench.step()
    return bench


@cocotb.test()
async def reset_and_empty_reads(dut):
    b = await setup(dut)
    for _ in range(3):
        await b.step(rd=1)
    await b.step()  # underflow must clear, rd_data must hold


@cocotb.test()
async def fill_overflow_and_drain(dut):
    b = await setup(dut)
    for i in range(b.depth):
        await b.step(wr=1, data=i * 37 + 5)
    for _ in range(3):
        await b.step(wr=1, data=b.mask)  # must not overwrite old data
    await b.step()
    for _ in range(b.depth):
        await b.step(rd=1)
    await b.step(rd=1)
    await b.step()


@cocotb.test()
async def data_patterns_and_output_hold(dut):
    b = await setup(dut)
    patterns = [0, b.mask, 1, (b.mask + 1) >> 1, 0x55, 0xAA]
    for value in patterns:
        await b.step(wr=1, data=value)
        await b.step()  # no read: output must not expose the new head
        await b.step(rd=1)
        for _ in range(3):
            await b.step()


@cocotb.test()
async def simultaneous_at_empty(dut):
    b = await setup(dut)
    await b.step(wr=1, data=0xA5, rd=1)
    await b.step(rd=1)  # written byte first becomes readable here
    await b.step()


@cocotb.test()
async def simultaneous_at_full(dut):
    b = await setup(dut)
    for i in range(b.depth):
        await b.step(wr=1, data=i)
    # Read and write pointers address the SAME slot when full. Return OLD data.
    for i in range(3 * b.depth):
        await b.step(wr=1, data=0x80 + i, rd=1)
    for _ in range(b.depth):
        await b.step(rd=1)
    await b.step()


@cocotb.test()
async def simultaneous_at_partial_and_wrap(dut):
    b = await setup(dut)
    await b.step(wr=1, data=0x31)
    for i in range(5 * b.depth):
        await b.step(wr=1, data=i * 19, rd=1)
    await b.step(rd=1)
    await b.step()


@cocotb.test()
async def reset_discards_queued_words(dut):
    b = await setup(dut)
    for i in range(b.depth):
        await b.step(wr=1, data=i + 10)
    await b.step(rd=1)
    await b.step(wr=1, data=0xBB, rd=1, rst=1)
    await b.step(rd=1)  # old words cannot reappear
    await b.step(wr=1, data=0x42)
    await b.step(rd=1)
    await b.step(rst=1, rd=1, wr=1)
    await b.step(rst=1, rd=1, wr=1)
    await b.step()


@cocotb.test()
async def randomized_scoreboard(dut):
    b = await setup(dut)
    rng = random.Random(0xB085)
    for i in range(1500):
        await b.step(wr=rng.randrange(2), rd=rng.randrange(2),
                     data=rng.randrange(b.mask + 1), rst=int(i % 173 == 172))
    while b.queue:
        await b.step(rd=1)
    await b.step()
