# ZFP1 sensor snapshot, version 1

This is a new FPGA protocol, not STM32 NEXUS v8. Reviewed STM32 baseline:
[df59973](https://github.com/vismay5559/stm32_zeuss/tree/df5997328c2a5b9c37e39b1dd1c82d6919ba5887),
434-byte v8 packet, eight leg joints, floats and STM32-computed estimator state.
ZFP1 keeps ten actuators and integer IMU values; fusion and scaling run on the Pi.
No placeholder estimated height, orientation, velocity, or foot height is labeled
as a measured result. The BNO085 quaternion remains reference-only.

## Transport and ownership

640 bytes, little-endian numeric fields. SPI mode 0, MSB-first within each byte,
read-only in this version: no MOSI command parser or motor actuation is implemented.
100 MHz FPGA clk, SCK <=10 MHz with high and low times each >=50 ns. CS setup and
hold >=100 ns; CS high between transactions >=200 ns. These are simulation/design
limits, not a measured board speed guarantee. Start bench tests at 1 MHz.
Pi waits for data_ready, asserts CS, reads exactly 640 bytes, releases CS. MISO is
tristated by the board top when CS is high. Empty reads return zero. Extra clocks
after a frame return zero until CS goes high. The GPIO-CS host reader supplies
10 us margins around transactions. Clock pauses are allowed.

The FPGA samples its producer at 1 kHz but keeps ONE immutable packet in flight.
Preparation computes CRC over 638 bytes, one byte per FPGA clock (~6.38 us).
Until the last byte is accepted, a new sample is dropped and counted; sequence
advances on every attempted sample. This bounded single-slot policy avoids torn
frames but does not buffer a slow Pi. A partially read frame is rewound on CS
release and must be retried from its first byte. A fully clocked frame is consumed
even if the Pi later rejects its CRC; this version has no ACK/retransmit queue.
FPGA reset discards the frame, timestamp epoch, sequence and drop counter.

At 10 MHz the wire time is 512 us/frame, excluding host scheduling/CS overhead.
At 1 MHz it is 5.12 ms: dropped snapshots are expected. Measure sustained throughput
on the Pi; do not infer 1 kHz delivery from the timer alone. No lossless history of
multiple IMU reports per snapshot is claimed; a report-event FIFO is separate work.

## Header and regions

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | ASCII ZFP1: 5a 46 50 31 |
| 4 | 1 | version = 1 |
| 5 | 1 | message type = 1 (sensor snapshot) |
| 6 | 2 | total length = 640 |
| 8 | 4 | attempted snapshot sequence, modulo 2^32 |
| 12 | 8 | FPGA free-running capture time in us |
| 20 | 4 | cumulative saturating dropped snapshots, sampled with header |
| 24 | 4 | flags: bit0 IMU configured, bit1 encoders present, bit2 contacts present, bit3 CAN0 present, bit4 CAN1 present; bit31 TEST_MODE; others zero |
| 28 | 4 | reserved zero |
| 32 | 40 | acceleration record |
| 72 | 40 | gyro record |
| 112 | 40 | BNO085 Rotation Vector record |
| 152 | 280 | ten 28-byte actuator records |
| 432 | 32 | four 8-byte encoder records |
| 464 | 16 | foot contact record |
| 480 | 132 | 33 diagnostic uint32 values |
| 612 | 26 | reserved zero |
| 638 | 2 | CRC16-CCITT-FALSE over bytes 0..637, low byte first |

CRC poly=0x1021, init=0xffff, no reflection, xorout=0. Check vector ASCII
123456789 -> 0x29b1. Python uses binascii.crc_hqx. This checksum covers FPGA-to-Pi
transmission; it cannot recover errors already accepted on the BNO085 UART link.

## IMU record (offsets relative to record start)

| Offset | Type | Meaning |
|---:|---|---|
| 0 | int16[4] | x,y,z,0 for accel/gyro; i,j,k,real for quaternion |
| 8 | uint16 | quaternion accuracy bits, zero for accel/gyro |
| 10 | uint8 | flags: bit0 has_sample, bit1 new, bit2 base_timestamp_valid |
| 11 | uint8 | Q point: accel=8, gyro=9, quaternion=14 when valid |
| 12 | uint8 | accuracy Q point=12 for valid quaternion, otherwise zero |
| 13 | uint8 | SH-2 status 0..3 |
| 14 | uint8 | SH-2 report sequence |
| 15 | uint8 | SHTP packet sequence |
| 16 | uint16 | packed SH-2 delay, low 14 bits; preserve without reinterpretation |
| 18 | uint16 | reserved zero |
| 20 | uint64 | opening-boundary FPGA capture timestamp in us |
| 28 | int32 | SH-2 Base Timestamp delta metadata |
| 32 | int32 | SH-2 Rebase delta metadata |
| 36 | uint32 | reserved zero |

Pi scales int / 2^Q. Accel includes gravity. Quaternion conversion to legacy
w,x,y,z is [real,i,j,k]. Invalid records may contain retained old integers; validity
is authoritative and `scaled()` returns None. Silence retains the value, while
successfully captured snapshots consume new. Timestamps are arrival times, not
claimed sensor sampling instants. Sensor reset clears validity until new reports.

## Actuator records

Indices 0..7 preserve the current leg map: left hip pitch/roll/knee/ankle, then
right hip pitch/roll/knee/ankle. Index8=waist roll (bus0,node5);
index9=waist pitch (bus1,node5). Other indices use nodes1..4 on their leg's bus.
This uses explicit addresses; DO NOT compute the index as bus*5+node-1.

| Relative offset | Type | Meaning |
|---:|---|---|
| 0 | float32 bits | drive position, output-shaft turns |
| 4 | float32 bits | drive velocity, output-shaft turns/s |
| 8 | float32 bits | reported torque estimate in Nm |
| 12 | float32 bits | actual transmitted target in output-shaft turns |
| 16 | uint32 | axis_error |
| 20 | uint16 | position/velocity age in us, saturating at 65535 |
| 22 | uint16 | heartbeat age in us, saturating at 65535 |
| 24 | uint8 | axis_state |
| 25 | uint8 | bits: 0 position/velocity valid, 1 heartbeat valid, 2 torque valid, 3 target valid |
| 26 | uint8 | bus index |
| 27 | uint8 | node ID |

The FPGA copies float bit patterns from CAN; it need not calculate floats. Pi
converts turns to radians and applies verified frame calibration. Verify drive
configuration actually reports output-shaft units before populating valid fields.
Age indicates freshness independently of validity. An absent group is all zero,
flags clear, and its array index still identifies the expected joint.

## Encoder and contact records

Encoders: left hip spring, left knee spring, right hip spring, right knee spring.
Relative offsets: 0 uint16 raw14 count; 2 uint8 flags (valid bit0, new bit1);
3 reserved zero; 4 uint32 age_us. Pi performs zero-offset/sign/wrap calibration
into signed spring deflection radians. Do not substitute it for drive joint angle.

Contacts: offset0 uint8 debounced center-sole switch bits (left bit0, right bit1; bits2..7 zero);
1 uint8 foot bits equal to switch bits (left bit0, right bit1; bits2..7 zero); 2 uint16 reserved;
4 uint16[2] stable ticks left/right; 8 uint64 timestamp_us of most recent switch
change. Header bit2 indicates whether the GPIO subsystem is present; health describes faults.
When contacts are present, the Pi decoder rejects nonzero mask bits 2..7 and
a foot mask that differs from the switch mask.
The Arty Pi demo now populates this record from synchronized, debounced foot
switches; its other sensor groups remain invalid/test-mode.

## Diagnostics

33 uint32 values starting at byte480, in this order (matching Python DIAGNOSTICS):

```
uart_frame_errors fifo_overflows invalid_protocols escape_errors
length_errors oversize_errors packet_timeouts continuation_errors
unsupported_reports packet_format_errors ignored_packets shtp_sequence_gaps
accel_sequence_gaps gyro_sequence_gaps rotation_sequence_gaps sensor_resets
bsn_queries bsn_timeouts config_retries confirmation_errors
can0_rx_dropped can1_rx_dropped can0_tx_dropped can1_tx_dropped
can0_bus_off can1_bus_off encoder_errors encoder_stalls command_timeouts
last_command_seq safety_state health advertised_uart_timeout_ms
```

Counters saturate unless otherwise specified by the source. `last_command_seq`
is a wrapping command sequence, not a counter; safety_state uses BOOT=0, IDLE=1,
ARMED=2, FAULT=3. health bits0..5 follow STM32 IMU/encoder/CAN0/CAN1/Pi-link/timing
faults. No command path currently exists: command-related fields remain zero and
no ARMED state is produced by this link. Expanding semantics requires joint review.

## Implementation boundary and next steps

Implemented: snapshot atomicity/CRC, SPI reads and abort recovery, Pi decoder,
1 kHz timer, standalone invalid-payload demo. The generic snapshot accepts a
packed same-clock payload; it does not validate producer fields. Production
sensor/CAN/encoder/GPIO payload assembly and Pi-side estimator integration remain.
The existing STM32 USB reader does not decode this protocol. Pi policy adapters,
commands/gains, acknowledgements, watchdog integration and full robot top are
separate work, not implied by the SPI reader being complete.
