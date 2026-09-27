# From Verilog to a running Arty A7-100T

Target is Digilent Arty A7-100T, Artix-7 xc7a100tcsg324-1, 100 MHz. "Artix-7"
is a chip family, not a pin map: do not use these constraints on an A7-35T or a
different manufacturer's board without changing part and pins.

## What actually goes onto the FPGA

Python tests run on the PC. Verilog describes logic. Vivado synthesizes it into
LUTs, flip-flops and memory, places those resources, and routes wires between them.
The XDC tells it which package pins reach the board connectors and what timing to
meet. The final .bit file configures that fabric. Loading .v or .py directly is
not programming the FPGA.

Only modules reachable from the selected top exist in the bitstream. A hundred
other source files in rtl do not make their interfaces appear on pins. `top` is
still blinky; `pi_link_demo_top` is a standalone packet/SPI test. Neither currently
contains the real IMU + encoder + CAN robot integration.

## 1. Update and simulate (development PC)

```bash
cd ~/fpga/biped-fpga
git pull --ff-only origin main
source ~/fpga/venv/bin/activate
python scripts/run_tests.py
make -C sim TOP=pi_link WAVES=1
```

If that simulation was previously built without waves, use a separate build dir:
`make -C sim TOP=pi_link WAVES=1 SIM_BUILD=sim_build/pi_link_waves`.
Inspect it with GTKWave, using the same SIM_BUILD with `make ... view`.
The tests drive a virtual Pi's SCK/CS and decode the returned MISO bytes, including
partial transactions. Passing simulation tests logic, not physical wiring.

## 2. Build the LED demo first

```bash
source /tools/Xilinx/2026.1/Vivado/settings64.sh
cd ~/fpga/biped-fpga
vivado -mode batch -source scripts/build.tcl
```

Output: `build/top/top.bit`. Reports: `build/top/timing.rpt`, utilization.rpt,
drc.rpt, cdc.rpt, io.rpt. The script stops on negative setup or hold slack. Check
unconstrained paths and DRC findings as well (the demo LED is intentionally
untimed); passing internal timing alone does
not prove external SPI timing or electrical margins.

## 3. Connect and program over JTAG

Power the Arty correctly for its board revision and connect the PC to its USB
PROG/UART connector with a data-capable cable. That connection provides onboard
JTAG; the Pi is not needed for programming. Confirm the board is an A7-100T.

```bash
vivado -mode batch -source scripts/program.tcl -tclargs build/top/top.bit
```

Equivalent GUI: open Vivado -> Hardware Manager -> Open Target -> Auto Connect ->
select xc7a100t -> Program Device -> select the built .bit -> Program.
If no target appears, check board power, cable, USB permissions and Vivado cable
drivers. If a different device appears, stop and correct the target part.

Press BTN0: LED LD4 goes low and the counter resets. Release: the LED toggles
once per second (one full on/off cycle is TWO seconds). This validates the board,
clock, reset and programming route before sensor wiring complicates diagnosis.

## 4. Build the Pi-link demo

```bash
vivado -mode batch -source scripts/build.tcl -tclargs pi_link_demo_top constraints/arty_a7_100_pi_demo.xdc
vivado -mode batch -source scripts/program.tcl -tclargs build/pi_link_demo_top/pi_link_demo_top.bit
```

Review reports in build/pi_link_demo_top. The demo creates a snapshot every 1 ms,
sets TEST_MODE, and sends invalid/zero sensor groups. Timestamp and sequence are
real demo counters. LD4 indicates a completed packet waiting for the Pi. BTN0
restarts timestamp/sequence. Power-on reset lasts 65535 FPGA cycles (~655 us).
The actual snapshot payload is deliberately constant, so synthesis of this demo
can optimize sensor storage away; its utilization is NOT the full robot cost.

## 5. Wire the Pi demo (power off while changing wires)

Use 3.3 V logic and a common ground, short wires, and the correct header orientation.
Power the boards normally; do not connect a Pi 5 V rail to any FPGA signal pin.
The demo reserves JA1-4; coordinate with the encoder teammate before sharing Pmods.

| Signal | Arty Pmod physical position | FPGA package pin | Pi 40-pin header |
|---|---|---|---|
| SCK, Pi -> FPGA | JA1 | G13 | pin23, GPIO11/SCLK |
| CS active-low, Pi -> FPGA | JA2 | B11 | pin22, GPIO25 (manual CS) |
| MISO, FPGA -> Pi | JA3 | A11 | pin21, GPIO9/MISO |
| data_ready, FPGA -> Pi | JA4 | D12 | pin18, GPIO24 |
| GND | JA5 or JA11 | GND | e.g. pin6 GND |

MOSI and hardware CE0 are not connected for this read-only phase. The supplied
reader disables hardware CS and drives GPIO25 so setup/hold margins are explicit.
JA physical pin numbers differ from FPGA package names; G13 is not a Pmod label.

## 6. Read packets on the Pi

Enable SPI through Raspberry Pi OS `raspi-config` (Interface Options -> SPI), then
reboot if requested. Confirm `/dev/spidev0.0` exists. Use `pinout` and `gpioinfo` to
confirm your Pi's GPIO chip and offsets: do not assume gpiochip0 on every OS/board.
The example assumes GPIO25 and GPIO24 are offsets25/24 on the selected chip.
Install dependencies in a Pi virtual environment, not the PC simulation venv:

```bash
cd /path/to/fpga_zeus
python3 -m venv .venv-pi
source .venv-pi/bin/activate
python -m pip install -r pi/requirements.txt
python -m pi.read_spi --gpiochip /dev/gpiochip0 --speed 1000000 --seconds 60
```

Ensure the user can access spidev/GPIO devices. The reader uses libgpiod API v2;
v1 distro bindings are not the same API. It polls data_ready, asserts CS, clocks
640 bytes, releases CS, and validates header/CRC before counting a packet.
Expected at 1 MHz: valid packets, TEST_MODE true, timestamps increasing, fewer than
1000 packets/s and increasing drop counts. 640 bytes alone take 5.12 ms here.

After clean operation, try 5 MHz, then 10 MHz:

```bash
python -m pi.read_spi --gpiochip /dev/gpiochip0 --speed 10000000 --seconds 60
```

At 10 MHz the wire portion is 512 us. A clean 1 kHz timer does not guarantee the
Linux reader keeps up: measure received rate, sequence gaps and FPGA drop count.
If CRC errors occur, inspect SCK/MISO/CS with a logic analyzer and lower speed;
check mode0, MSB-first and common ground. CS setup/hold >=100 ns, CS high>=200 ns,
SCK high/low>=50 ns are required. The reader deliberately adds 10 us CS margins.
These software margins are minimum waits; Linux scheduling can lengthen them.

Bench scenarios: pause the reader and resume (drops counted, no torn frames),
restart it, press BTN0 (new timestamp epoch), perform a partial transaction and
retry (same frame from byte0). A read of all 640 bytes consumes the packet even
if a physical transmission error later causes Pi CRC rejection.

## 7. Integrate actual sensor modules

Create a production top that instantiates cycle_timer, the sensor modules and
pi_link. Pack same-clock retained registers into the documented payload. Connect
sample_accepted to each producer's freshness-consume input; do not clear freshness
for snapshots rejected while busy. Fill bus/node IDs and units exactly as the
protocol says. Cross asynchronous multi-bit data safely before packing it.
Run integration tests, add actual pin/clock constraints, rebuild and rerun the
bench procedure. Pi-side scaling and InEKF are additional software integration.
The current demo does not configure/read the BNO085 or command any ODrive.

## JTAG programming versus persistent flash

`scripts/program.tcl` programs FPGA configuration RAM. Power loss removes it; an
existing QSPI image may load on the next boot. This is the normal quick test loop.

For power-up persistence, program the board's QSPI flash after the design passes:
1. Check the exact flash device fitted to your board revision from its schematic.
2. In Hardware Manager, select the FPGA -> Add Configuration Memory Device and
   choose that exact part/interface, not a guessed part from another revision.
3. Generate a compatible configuration-memory image from the working bitstream
   (Vivado's configuration-memory workflow / write_cfgmem), then Program
   Configuration Memory Device with erase, program and verify selected.
4. Set the board boot-mode jumper for SPI boot per its manual and power-cycle.
5. Verify the expected design starts without the programming PC.

Flash model selection and boot jumper depend on board revision. We do not provide
an automatic erase/flash script with an unverified part selection.

## Primary references

- [Digilent Arty A7 reference manual](https://digilent.com/reference/programmable-logic/arty-a7/reference-manual)
- [Digilent official A7-100 master XDC](https://github.com/Digilent/digilent-xdc/blob/master/Arty-A7-100-Master.xdc)
- [AMD Vivado timing report command](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/report_timing_summary)
- [AMD bitstream/programming flow](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/create_hw_bitstream)
- [Raspberry Pi GPIO/SPI documentation](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html)
- [spidev](https://github.com/doceme/py-spidev), [libgpiod v2 request API](https://libgpiod.readthedocs.io/en/v2.3/python_misc.html)
