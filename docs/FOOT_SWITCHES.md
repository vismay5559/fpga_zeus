# Foot switches from the beginning

The robot has four normally-open switches: left toe, left heel, right toe,
right heel. Each switch connects an FPGA input to ground when pressed. An input
pull-up holds the otherwise open pin high. Thus the wire is **active-low**:

| Switch | Pin level | Meaning |
|---|---|---|
| Open | 1 | no physical contact |
| Closed | 0 | physical contact candidate |

The current STM32 uses this same polarity and order. Its `contact.c` at commit
[8abfe78](https://github.com/vismay5559/stm32_zeuss/blob/8abfe78e04b1b5afa7f1539c65b607446f6d7993/Appli/App/contact.c)
confirms closed for 3 consecutive 1 kHz polls and open for 8. Defaults can be
changed through the RTL parameters MAKE_TICKS and BREAK_TICKS; a longer break
avoids false lift-off from a foot rolling on a planted contact.

## What the Verilog does

[`foot_switches.v`](../rtl/gpio/foot_switches.v) has four stages:

1. `sync_first` and `sync_second` take each asynchronous pin through two FPGA
   flip-flops. This reduces metastability reaching the logic. Reset assumes the
   pull-up state (all ones); no contact is initially trusted.
2. At each one-clock `sample` pulse (every 1 ms in hardware), `closed` inverts the
   synchronized electrical level, turning pressed=0 into logical contact=1.
3. `candidate_ticks[i]` independently counts consecutive sampled values that
   differ from the accepted `switches[i]`. A matching sample clears the count.
   The third closed sample commits contact; the eighth open sample commits lift.
4. `feet[0]` is left toe OR left heel; `feet[1]` is right toe OR right heel.
   `left_ticks` and `right_ticks` count 1 kHz polls since each FOOT changed,
   saturating at 65535. A toe-to-heel transfer on the same foot keeps age.

For example, if left toe closes and bounces like `0,0,1,0,0,0` in the logical
sampled signal, the first two candidates are canceled by the third sample. The
contact is finally accepted after the last three consecutive ones. A short raw
pulse between sample strobes never reaches the contact decision.

When a switch is accepted, `switch_changed[i]` pulses for exactly one 100 MHz
clock. Its own 64-bit `switch_change_us` slot and the global `latest_change_us`
record the **time of confirmation**. They are not the time of the first metal
contact, which can only be known within the sample/debounce resolution. A foot
OR transition also emits a one-clock `foot_changed` pulse. Reset clears all
accepted states, age counters and timestamps. No source value is invented for
an unobserved input after reset.

Useful Verilog syntax here:

- `always @(posedge clk)` means the logic updates only at each rising FPGA
  clock edge; `<=` schedules registers to change together after that edge.
- `wire` continuously calculates a value, like `feet = toe | heel`.
- `candidate_ticks[i]` is a separate small counter for each of four switches.
- `switch_change_us[i*64 +: 64]` selects one 64-bit timestamp slot from the
  packed bus. Slot0 occupies bits0..63, slot1 bits64..127, and so on.
- `parameter` makes the make/break thresholds reusable without editing logic.

The top-level clock timer provides both the 1 kHz `sample` and free-running
microseconds. The GPIO block samples its physical pins only at `sample`, but its
two synchronizer stages run at every 100 MHz clock edge.

## What Python verifies

[`test_foot_switches.py`](../sim/gpio/test_foot_switches.py) drives raw pin
levels and clock/sample pulses. It checks each bit position, exactly 3 make and
8 break samples, candidate cancellation after bounce, simultaneous contacts,
toe-to-heel transfer, timestamps, reset and age saturation. The benchmark test
uses shortened gaps between sample pulses for runtime; the separate timer test
checks the actual 100 MHz/1 kHz strobe spacing.

[`test_pi_link_demo_top.py`](../sim/top/test_pi_link_demo_top.py) sends SPI clock
edges to the top-level module. It checks packet CRC with the Pi decoder, then
checks that a pressed left-toe switch appears in the next complete snapshot
without changing a packet already in flight. The GPIO bit remains live even
when Pi reads slower and intervening snapshots are counted as dropped.

Run both:

```bash
source ~/fpga/venv/bin/activate
make -C sim TOP=foot_switches
make -C sim TOP=pi_link_demo_top
```

The demo maps stable GPIO state into ZFP1 bytes 464..479. The Pi sees switch bits
at byte464 (bit0 left toe, bit1 left heel, bit2 right toe, bit3 right heel),
foot bits at byte465 (bit0 left, bit1 right), 16-bit foot ages at bytes468..471,
and `latest_change_us` at bytes472..479. Header flag bit2 says contacts are
present. The first 1 kHz snapshot following a confirmed transition contains the
new state. `pi.read_spi` displays the switch mask, foot mask and ages.

## Arty bench wiring

The Pi SPI demo continues on JA1..JA4. Four contact inputs use JD1..JD4 in the
same left-to-right order as above (package pins D4, D3, F4, F3). Each external
normally-open switch connects its corresponding JD signal to JD ground; the XDC
requests an FPGA pull-up. LED1 means left foot contact and LED2 right foot
contact. LED0 still indicates a complete packet waiting for the Pi.

A long robot cable can pick up noise; test with actual harness length and motor
switching. For production use, review pull-up strength, wire shielding, signal
conditioning and electrical protection at the FPGA input. The timing tests and
FPGA simulation do not establish those analog properties.

This is a complete foot-switch receive/packet path in the demo. The production
robot top, health/fault policy and Pi-side estimator still need integration.
