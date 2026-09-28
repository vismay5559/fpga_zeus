# Foot switches: one at the center of each sole

The current [STM32 contact code](https://github.com/vismay5559/stm32_zeuss/blob/df5997328c2a5b9c37e39b1dd1c82d6919ba5887/Appli/App/contact.c) uses **two** switches total: one left and one right. Its old CubeMX pin names `L_TOE` and `R_TOE` now mean the center-sole switches; the heel pins are unused. The FPGA follows the same physical arrangement. Bit 0 always means left foot and bit 1 right foot. There is no toe/heel OR. The 16-byte ZFP1 contact record keeps its existing layout so the Pi frame length and decoder do not change; unused high bits of its two masks are zero.

Each normally-open switch connects one FPGA input to ground when pressed. The XDC requests an internal pull-up, so an open switch reads `1` and a pressed switch reads `0` (active-low). JD1 is left (package D4); JD2 is right (D3). Each switch's other wire goes to JD ground. JA1..JA4 remain reserved for the Pi SPI demo. LED1 shows left contact; LED2 right contact.

## Why wait for three and eight samples?

A metal contact can open and close several times as it hits or releases. The foot can also rock, momentarily taking pressure off a switch even while planted. At 1 kHz, the FPGA looks once every millisecond. It accepts **pressed** after three consecutive pressed readings and **released** after eight consecutive open readings. If a sample returns to the previously accepted state, the candidate count resets. Thus `pressed, pressed, open, pressed, pressed, pressed` becomes one contact event only at the final pressed reading. An open spell of seven samples while planted does not announce lift-off. These defaults are the same as the STM32 code; they are configurable RTL parameters, not measured optimum values for the final shoe.

This is **digital debounce**, not a capacitor. A capacitor plus resistor can smooth fast voltage changes electrically, but capacitance by itself neither guarantees clean edges nor proves that a foot is loaded. The FPGA input still needs a definite voltage and the mechanical gait still needs testing. The two synchronizer flip-flops reduce the chance of an asynchronous transition upsetting FPGA logic; they do not debounce. The 3/8-sample filter is what rejects short changes after synchronization. It delays a true landing by roughly 2–3 ms and a true release by roughly 7–8 ms, depending on where the edge falls relative to the next sample. A long, real opening of the center switch during foot roll can still be interpreted as lift-off; with one switch this must be checked on the robot.

## Verilog, step by step

[`foot_switches.v`](../rtl/gpio/foot_switches.v) has two synchronizer registers per input. At every 1 kHz `sample` pulse it inverts the electrical value (`0` means pressed) and compares it with the accepted state. `candidate_ticks[0]` and `[1]` independently count consecutive opposite samples. The selected `MAKE_TICKS` or `BREAK_TICKS` determines when a candidate becomes accepted. A change produces one clock pulse in `switch_changed`; `feet` and `foot_changed` equal those switch masks because there is one switch per foot. The 64-bit per-foot confirmation timestamps and latest confirmation timestamp record **when the filter accepted** a change, not the first physical touch. `left_ticks` and `right_ticks` count 1 kHz samples since their own accepted state last changed and stop at 65535 rather than wrapping.

The demo [`pi_link_demo_top.v`](../rtl/top/pi_link_demo_top.v) takes the accepted state one FPGA clock after the 1 kHz sample, ensuring the snapshot sees the just-confirmed value. It fills ZFP1 bytes 464..479: byte464 has left/right switch bits in positions 0/1, byte465 has identical foot bits, bytes468..471 contain 16-bit left/right ages, and bytes472..479 contain the latest confirmation time in microseconds. Header flag bit2 marks contacts present. [`read_spi.py`](../pi/read_spi.py) prints the two masks and ages. Other sensor groups in this bench demo remain invalid.

## Python tests and bench work

[`test_foot_switches.py`](../sim/gpio/test_foot_switches.py) supplies virtual input voltages, waits for synchronization, and sends virtual 1 kHz sample pulses. It checks left/right order, exact 3/8-sample boundaries, bounce cancellation, independent feet, event pulses and timestamps, reset, a pulse between samples, and age saturation. [`test_pi_link_demo_top.py`](../sim/top/test_pi_link_demo_top.py) clocks the complete SPI packet and runs it through the Pi decoder to check that contact bits arrive without changing a packet already in flight. The testbench shortens timer waits for simulation speed; the separate timer tests cover the hardware 100 MHz to 1 kHz ratio.

```bash
source ~/fpga/venv/bin/activate
make -C sim TOP=foot_switches
make -C sim TOP=pi_link_demo_top
python scripts/check_foot_mutations.py
python scripts/run_tests.py
```

The pinout and programming sequence are in [ARTY_A7_BRINGUP.md](ARTY_A7_BRINGUP.md). Connect and test the real switch harness before treating its debounce thresholds as final: press and release each switch, rock a planted foot, and test with motors running. An FPGA simulation cannot measure electrical noise, contact force, or whether the sole's center point reliably engages at all gait phases. The bitstream build alone is not a physical board test.
