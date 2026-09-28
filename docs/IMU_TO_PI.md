# BNO085 UART data in the Pi snapshot

The current [STM32 firmware](https://github.com/vismay5559/stm32_zeuss/blob/df5997328c2a5b9c37e39b1dd1c82d6919ba5887/Appli/App/imu_bno085.c) requests **calibrated accelerometer report 0x01** and **calibrated gyroscope report 0x02** every 2,500 µs (400 Hz each), plus **Rotation Vector report 0x05** every 10,000 µs (100 Hz). Its [state builder](https://github.com/vismay5559/stm32_zeuss/blob/df5997328c2a5b9c37e39b1dd1c82d6919ba5887/Appli/App/app.c) copies those values to `imu_accel[3]`, `imu_gyro[3]` and `imu_quat[4]` for the Pi. Acceleration includes gravity; the quaternion is the sensor's own reference orientation, separate from the project's InEKF.

The FPGA asks for the same report IDs and rates. In [`pi_link_demo_top.v`](../rtl/top/pi_link_demo_top.v), the BNO085 UART TX enters `imu_rx` on Arty JB1 and FPGA `imu_tx` leaves JB2 for the sensor UART RX. [`bno085_imu.v`](../rtl/imu/bno085_imu.v) sends startup Set Feature commands, receives UART-SHTP packets and retains the latest SH-2 values. The demo now packs those registers into **three separate 40-byte ZFP1 records** at frame offsets 32, 72 and 112. It also copies the first 20 IMU diagnostics and the advertised UART timeout into the diagnostic region. Contact bits remain live; encoder and CAN groups remain invalid and TEST_MODE stays set.

The physical values match the STM32's fields, but the **wire formats differ deliberately**:

| Report | STM32 NEXUS packet | FPGA ZFP1 packet | Pi conversion |
|---|---|---|---|
| Accelerometer | three float32 values, m/s², gravity included | three signed int16 values, Q8, fourth slot zero | divide each integer by 2⁸ |
| Gyroscope | three float32 values, rad/s | three signed int16 values, Q9, fourth slot zero | divide each integer by 2⁹ |
| Rotation Vector | four float32 values ordered `w,x,y,z` | four signed int16 values ordered `i,j,k,real`, Q14 | divide by 2¹⁴; reorder to `real,i,j,k` for STM32-style comparison |

For example, an acceleration integer of `256` in Q8 represents `1.0 m/s²`; `-256` is `-1.0 m/s²`. No floating-point calculation happens inside the FPGA. [`fpga_protocol.py`](../pi/fpga_protocol.py) decodes the frame and its `ImuReport.scaled()` method performs the division on the Pi. [`read_spi.py`](../pi/read_spi.py) prints scaled values; it labels the quaternion as `i,j,k,real` so the order is explicit.

Each record also carries its own `has_sample`, `new`, Q point, SH-2 status, report and SHTP sequence numbers, packed delay, FPGA UART packet-opening timestamp, and Base Timestamp/Rebase metadata. Rotation Vector also has Q12 accuracy metadata. The full byte layout is in [PI_LINK_PROTOCOL.md](PI_LINK_PROTOCOL.md). At a 1 kHz packet attempt rate, a 400 Hz report can legitimately repeat across snapshots. The `new` bit means a different accepted report has arrived since the **last accepted snapshot**, not that every snapshot must contain a different value. If the Pi link is busy, it does not consume freshness. If the sensor goes silent, the last raw integers remain, `has_sample` stays true and `new` goes false. A confirmed sensor reset clears validity until fresh reports arrive. A configuration-complete header bit is separate from per-report validity.

[`test_pi_link_demo_top.py`](../sim/top/test_pi_link_demo_top.py) sends serial SHTP/SH-2 bytes into the top, reads the full SPI packet and checks signed raw values, Q points, sequences, timestamp metadata, retained-but-not-new values, and reset invalidation. The separate BNO085 host tests check startup command intervals and UART reception at independent 3.000 Mbaud. Simulation uses a shortened UART divider in the top test for speed; a real sensor, 400/400/100 delivery and the Arty-to-Pi sustained packet rate remain physical tests. The current STM32 notes document substantial sensor-rate variation under different quaternion settings, so **requested rate is not a measured delivered rate**.

The Arty demo bounds each incoming UART-SHTP packet at **128 bytes** to keep the
100 MHz receive/parse path routable. Packets longer than that are rejected and
counted by `oversize_errors`; the receiver resynchronizes at the next UART
frame. This is a bench-design limit, not a proven maximum for every BNO085
configuration. Log that counter with the real sensor; if it increments, raise
the `IMU_MAX_PACKET_BYTES` parameter and recheck routed timing.
