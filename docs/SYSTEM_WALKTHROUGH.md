# How the current FPGA repository works

Start with three different things: a **Verilog module** describes logic that can exist inside the FPGA; a **Python cocotb test** pretends to be its surrounding wires and checks its behavior; and a **top module** connects pieces together and exposes board pins. Having a working module in `rtl/` does not put it in a bitstream. Only modules reachable from the chosen top are built into that bitstream.

## The target data flow

```text
BNO085 -- UART -- receiver/FIFO -- SHTP/SH-2 decoder -- raw IMU registers --+
AS5047P x4 -- encoder SPI master (teammate; pending) --------------------+
sole switches x2 -- synchronizer/debounce -------------------------------+-- 1 kHz snapshot -- Pi SPI slave -- Raspberry Pi
ODrive x10 -- two CAN FD buses (pending) -- joint registers -------------+
```

The diagram is the **target**. The current `pi_link_demo_top` connects only the clock/timer, switches and Pi SPI packet path. Its IMU/encoder/CAN bytes are zero and marked invalid. The separately tested BNO085 host is not yet wired into that top.

## What each implemented part does

1. **Clock and snapshot trigger.** The Arty clock is 100 MHz: one rising edge every 10 ns. [`cycle_timer.v`](../rtl/common/cycle_timer.v) counts 100 edges to make a microsecond, then emits a one-clock `sample` pulse every 1,000 µs. It also keeps the FPGA timestamp. This creates a schedule, not an assurance that a slow Pi will receive all attempts.
2. **Two foot switches.** Each center-sole switch pulls one JD input low when pressed. [`foot_switches.v`](../rtl/gpio/foot_switches.v) first synchronizes each input through two flip-flops. It currently makes its *accepted* contact decision at each 1 kHz sample: three pressed readings to declare contact, eight open readings to declare release. Left is bit0; right is bit1. It retains stable ages and confirmation timestamps. The [foot-switch guide](FOOT_SWITCHES.md) explains why these are debounce settings, not a low-latency motor path.
3. **BNO085 receive and transmit.** Generic [`uart_tx.v`](../rtl/uart/uart_tx.v) and [`uart_rx.v`](../rtl/uart/uart_rx.v) handle serial bits. [`fifo_sync.v`](../rtl/common/fifo_sync.v) buffers bytes. The IMU modules in [`rtl/imu`](../rtl/imu) frame/unescape UART-SHTP packets, decode SH-2 reports, retain signed integer acceleration/gyro/quaternion data, and send startup Set Feature commands for 400/400/100 Hz. Hardware does not convert them to floats. [`bno085_imu.v`](../rtl/imu/bno085_imu.v) joins these IMU pieces in simulation. They still need real board pins, capture comparison and packet integration.
4. **The Pi packet.** [`pi_snapshot.v`](../rtl/pi_link/pi_snapshot.v) copies the entire payload at an accepted `sample`, adds header/sequence/timestamp, calculates CRC, and presents one immutable 640-byte frame. It can hold only one in-flight frame. It counts later sample attempts as dropped until that frame is consumed. [`pi_spi_slave.v`](../rtl/pi_link/pi_spi_slave.v) lets the Pi clock out bytes over read-only SPI; the FPGA raises `data_ready` when a frame is ready. An incomplete read rewinds the same frame. [`pi_link.v`](../rtl/pi_link/pi_link.v) joins packet and SPI slave. [PI_LINK_PROTOCOL.md](PI_LINK_PROTOCOL.md) gives every byte offset.
5. **The current board demo and Pi software.** [`pi_link_demo_top.v`](../rtl/top/pi_link_demo_top.v) wires the timer and contacts into the Pi link. It sets `TEST_MODE`, advertises contacts present, and leaves other sensor groups invalid. [`fpga_protocol.py`](../pi/fpga_protocol.py) verifies the header, length, CRC and field constraints; [`read_spi.py`](../pi/read_spi.py) is a bench reader for the Raspberry Pi. The Pi reader is not the estimator or motor-command program.

For comparison, [`top.v`](../rtl/top/top.v) is just an LED blinky bring-up design. Building that top will not connect the Pi demo or the IMU.

## How the tests prove only their claimed behavior

- `sim/<area>/test_<module>.py` drives virtual inputs and checks the corresponding RTL outputs. The shared [`sim/Makefile`](../sim/Makefile) selects a top module and simulation parameters; [`run_tests.py`](../scripts/run_tests.py) runs all suites.
- [`test_cycle_timer.py`](../sim/common/test_cycle_timer.py) checks the real 100 MHz-to-1 kHz count. Other tests shorten wait parameters to run quickly and check logic at the corresponding boundaries.
- [`test_foot_switches.py`](../sim/gpio/test_foot_switches.py) drives open/closed voltages, bounce and sample pulses; it checks left/right bit order, exact 3/8 counts, timestamps and ages.
- [`test_pi_link_demo_top.py`](../sim/top/test_pi_link_demo_top.py) clocks a whole 640-byte SPI frame, decodes it with the Pi Python code and checks that a switch change appears in a later complete frame rather than altering an in-flight frame.
- UART/IMU suites drive serial bits, packet errors, reset and flow-control scenarios. The [UART/BNO085 walkthrough](../UART_BNO085_WALKTHROUGH.md) explains those tests from first principles. Simulation cannot establish the behavior of the real switch, cable, BNO085 or CAN bus.

After activating `~/fpga/venv`, run `python scripts/run_tests.py` from the repository root. To build and program the Arty demo, follow [ARTY_A7_BRINGUP.md](ARTY_A7_BRINGUP.md). Do not interpret a passing simulation or generated `.bit` as a physical-board result.

## Why the motor override is separate

The existing 1 kHz foot-contact output can take roughly 3 ms to confirm a press and 8 ms to confirm release. It is acceptable only as the current reporting policy. The requested future action—ignore a Pi command and send a specific ODrive torque command within 1 ms of contact—must bypass that sampler and the Pi snapshot. It needs a fast contact detector, a defined arbitration/safety rule, a CAN transmitter with bounded priority, and switch-to-drive timing measurements. None of those motor-command pieces are implemented yet; the precise command is still undecided.
