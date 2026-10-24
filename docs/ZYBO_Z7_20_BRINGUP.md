# Zybo Z7-20 first power-up and BNO085 UART bench test

The purchased **Zybo Z7-20** has a **Zynq-7020** (`xc7z020clg400-1`). Zynq
contains a processor system (PS) and FPGA fabric (PL). These designs use only
the PL, programmed over USB-JTAG; no Linux image or processor program is needed
for the first test. The on-board J12 USB serial port connects to a *PS* UART,
not directly to the IMU UART implemented in the PL.

Pin assignments below come from Digilent's
[Zybo Z7 master XDC](https://github.com/Digilent/digilent-xdc/blob/master/Zybo-Z7-Master.xdc).
Power and boot settings come from the
[Zybo Z7 reference manual](https://digilent.com/reference/_media/reference/programmable-logic/zybo-z7/zybo-z7_rm.pdf).
Check the board silkscreen and breakout revision before connecting anything.

## 1. Power and blink

1. Set JP6 to **WALL**. Plug a regulated **5 V, at least 2.5 A**, center-positive
   2.1 mm supply into J17. Never use a 12 V adapter. Set SW4 ON; LD13 PGOOD
   should light. Connect J12 micro-USB to the development computer for JTAG.
2. Set JP5 to **JTAG** using the board silkscreen, and power cycle after moving it.
3. From the repo root run:

   ```bash
   vivado -mode batch -source scripts/build.tcl
   vivado -mode batch -source scripts/program.tcl
   ```

   This selects `zybo_z7_20_top`, creates `build/zybo_z7_20_top/zybo_z7_20_top.bit`,
   and programs it temporarily over JTAG. LED0 should toggle once per second;
   BTN0 holds it off. Programming is lost at power-off. The scripts select the
   Zynq-7020 part directly, so installing separate board files is optional.

If Vivado says there is no valid license, fix Vivado licensing first. A Python
simulation pass cannot generate or validate a board bitstream.

## 2. Adafruit BNO085 UART-SHTP, then the Pi link

Power **off** before wiring. Adafruit's
[BNO085 UART guide](https://learn.adafruit.com/adafruit-9-dof-orientation-imu-fusion-breakout-bno085/arduino)
uses **P1 high, P0 low** for regular UART. P0 high selects UART-RVC, a different
protocol. On the breakout, **SDA is UART data out** and **SCL is UART data in**.

| Connection | Zybo Z7-20 | Other end |
|---|---|---|
| Power | JE pin 6 or 12, 3.3 V | BNO085 VIN and P1 |
| Common ground | JE pin 5 or 11 | BNO085 GND |
| Sensor to FPGA | JE pin 1, `imu_rx` | BNO085 SDA |
| FPGA to sensor | JE pin 2, `imu_tx` | BNO085 SCL |
| Pi SPI clock | JE pin 3, `pi_sck` | Pi SCLK |
| Pi chip select | JE pin 4, `pi_cs_n` | Pi CE/CS |
| FPGA to Pi SPI data | JE pin 7, `pi_miso` | Pi MISO |
| FPGA to Pi ready | JE pin 8, `pi_data_ready` | Pi 3.3 V GPIO input |
| Left/right contacts | JD pins 1/2 | Each switch to ground when pressed |

These are **3.3 V logic signals**; never drive an FPGA input with 5 V. Both
the breakout and Pi need a shared ground with the Zybo. No Pi or switches are
needed for the initial UART hardware connection. Build the sensor-only image:

```bash
vivado -mode batch -source scripts/build.tcl -tclargs zybo_z7_20_imu_top
vivado -mode batch -source scripts/program.tcl -tclargs build/zybo_z7_20_imu_top/zybo_z7_20_imu_top.bit
```

LED0 is a heartbeat; LED1 means startup was confirmed; LED2 means both accel
and gyro reports have arrived; LED3 means a quaternion report has arrived.
These latched LEDs **do not prove 400/400/100 Hz**, only that the corresponding
reports were decoded at least once. Numeric values and rate measurements require
an ILA or the full Pi SPI demo below. In the full demo LED0 = packet ready and
LED1/2 = left/right contact; those LEDs do **not** show IMU sample validity.

Build and program the full bench demo:

```bash
vivado -mode batch -source scripts/build.tcl -tclargs zybo_z7_20_demo_top
vivado -mode batch -source scripts/program.tcl -tclargs build/zybo_z7_20_demo_top/zybo_z7_20_demo_top.bit
```

The wrapper uses the PL-side 125 MHz K17 clock and an MMCM to supply 100 MHz
to the already-simulated UART/timer/Pi design. It still requests 400 Hz
accelerometer, 400 Hz gyro and 100 Hz rotation-vector reports over 3 Mbaud
UART-SHTP. The bitstream uses the existing 128-byte receive limit and retains
the existing error counters and fixed-point outputs. Verify actual sensor rates,
the UART margin and SPI delivery on the physical board; simulation cannot
establish those results. Only the FPGA should drive the BNO085 SCL/UART RX pin.

## Legacy Arty builds

The previous board remains supported for comparison:

```bash
vivado -mode batch -source scripts/build.tcl -tclargs top
vivado -mode batch -source scripts/build.tcl -tclargs pi_link_demo_top
vivado -mode batch -source scripts/program.tcl -tclargs build/top/top.bit
```

Never program an Arty bitstream onto the Zybo, or use the Arty XDC for Zybo
wiring. Generated bitstreams are not committed to Git.
