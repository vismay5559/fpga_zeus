# BNO085 implementation contract and verification plan

Updated 2026-09-22. FPGA-only implementation order: FIFO, command transport and
deframer exercises, report decoder, snapshot integration. Only the FIFO skeleton
and UART timing tests are delivered at this stage. The acceptance tests listed
below for command sending, decoding and snapshots are requirements, not passing
tests for hardware that already exists.

## Reports and STM32 baseline

The initial FPGA configuration is chosen to match the settings found in
`vismay5559/stm32_zeuss` at commit
`dac1862eb4639769f8e0b20e18c9e2a5dc1035d0`:
[imu_bno085.c](https://github.com/vismay5559/stm32_zeuss/blob/dac1862eb4639769f8e0b20e18c9e2a5dc1035d0/Appli/App/imu_bno085.c),
[main.c](https://github.com/vismay5559/stm32_zeuss/blob/dac1862eb4639769f8e0b20e18c9e2a5dc1035d0/Appli/Core/Src/main.c).
This is a source-code baseline, not confirmation of the binary flashed on the MCU.
The FPGA is the sole BNO085 host in this project: it sends startup commands and
receives reports. No STM32 connection is required.

| SH-2 report | ID | Requested interval in STM32 | Requested rate | Storage in FPGA |
|---|---|---|---|---|
| Calibrated acceleration, gravity included | 0x01 | 2500 us | 400 Hz | signed 16-bit x/y/z, Q8 |
| Calibrated gyroscope | 0x02 | 2500 us | 400 Hz | signed 16-bit x/y/z, Q9 |
| Rotation Vector | 0x05 | 10000 us | 100 Hz, enabled | signed 16-bit i/j/k/real, Q14 |

Q points verified in the **SH-2 Reference Manual v1.9**, sections 6.5.9,
6.5.13 and 6.5.18. Rotation Vector also has a heading accuracy field, Q12 radians.
Preserve its bits and SH-2 status alongside the quaternion. Preserve wire component
order explicitly; the STM32 maps real to `quat[0]` (w,x,y,z).
The Pi scales each signed value by `2**(-q_point)`. No FPGA floating point,
gravity removal, quaternion normalization or fusion. Quaternion is a comparison
reference only, never an input to the user's InEKF.

`imu_request_reports()` sends Rotation Vector, accelerometer, then gyro, with a
5 ms delay after each Set Feature; it then queries the accelerometer configuration.
Feature flags, sensitivity, batch interval and sensor-specific word are zero.
UART is 3,000,000 baud, 8N1. `uart_tx_spaced()` waits 120 us after every transmitted
wire byte, including escape and framing bytes. Preserve these settings in a named
`stm32_match` profile; query all three actual intervals for diagnostics later.

The driver calls `q_to_float()` before storing measurements. Thus current source
does not retain the same integer representation requested for this FPGA. Preserve
the FPGA integers; compare original captured report bytes, or convert on the Pi
before comparing with STM32 values. MCU per-report counters are locally incremented
counts, not copies of the SHTP or SH-2 wire sequence fields. Its parser also does not
validate the declared SHTP length. Match configuration and correctly received values;
do not reproduce those parser limitations.

### Requested rate versus delivered rate

Use the 400 Hz acceleration, 400 Hz gyro and 100 Hz Rotation Vector profile for
both simulation and FPGA startup. It is the starting operating profile, not a
side-by-side comparison mode. Do not silently change these intervals after startup.

The BNO08X datasheet v1.16 section 6.9 lists maxima of 500 Hz accelerometer,
400 Hz gyro and 400 Hz Rotation Vector, warns about simultaneous maximum rates,
and describes discrete rate selection. Firmware comments record acceleration of
about 216 Hz with all three requested at 400 Hz, and about 158 Hz in another
experiment after lowering quaternion to 100 Hz. Those are historical observations
in comments, not newly reproduced measurements or proof of a particular cause.

Recommendation: begin with the identical 400/400/100 request profile, measure each
stream separately, and treat acceleration AND gyro <=250 Hz as failure of the
user's requirement. Do not use total packets/s or 1 kHz snapshot rate as the sensor
rate. Check Get Feature responses, per-report sequences, interarrival distributions,
UART errors and overflow counts on a capture shared by both receivers. Run a
sustained bench capture (e.g. 60 s after startup) before claiming a supported rate.
If necessary, try a separate 500 Hz accelerometer / 400 Hz gyro / 100 Hz quaternion
profile: 500 Hz is the documented accelerometer maximum, but it is an experiment,
not a promise that this combination will work. Keep quaternion enabled as requested.
No currently inspected evidence establishes a sustained >250 Hz acceleration rate
with quaternion enabled on this particular setup.

## Clock and byte pacing

100 MHz / 33 = 3.030303 Mbaud, +1.0101% relative to 3 Mbaud. The receiver sees
333.333... ns sender bits against its 330 ns bit timer. `test_uart_rx_bno085.py`
drives independent rational bit deadlines with <1 ps rounding error, all 256 byte
values, four start phases, and +/-100 ppm sender offsets. The ppm offsets are an
explicit simulation stress budget; verify the actual sensor crystal and FPGA
oscillator tolerances before making a hardware timing guarantee.

Keep the 100 MHz domain initially. A 96 MHz MMCM output would give 32 clocks/bit
and remove divider error, but adds clock/reset constraints and a 96-to-100 MHz
transfer boundary. These clocks can be related; do not blindly false-path the
crossing. Handle MMCM LOCKED/reset and either time the transfer correctly or use a
proper CDC bridge. It does not remove the sensor's independent clock error.
If margin proves insufficient, consider a fractional baud clock-enable at 100 MHz
(33/33/34 clocks) before adding another clock domain. See AMD UG472 and UG949.

The BNO08X datasheet section 1.2.3.1 and SHTP v1.10 section 4.5 specify at least
100 us **between host-to-sensor bytes**, not only between packets. Use a command
sender parameter `TX_BYTE_GAP_US` (default 120 to match STM32) and `CLK_HZ`.
Measure conservatively from the END of a byte's stop bit to the START of the next
byte. At 100 MHz, 120 us is 12,000 cycles. Apply across packet boundaries too.
Do not change the generic UART transmitter to impose this device-specific delay.
Use TX frame completion, not merely byte acceptance, to start the gap timer.

A 17-byte Set Feature plus 4-byte SHTP header plus protocol ID and two flags is
24 wire bytes without escaping: approximately 2.84 ms with 23 idle gaps of 120 us
and 3 Mbaud bits. STM32 also delays after the last byte (~2.96 ms total), then 5 ms
after each feature request. Escaping increases time further. The sender must also
respect SHTP UART buffer status notifications/queries and their expiry; the byte
gap alone is not buffer flow control.

## Packet integrity and recovery

SHTP over UART v1.10 section 4 specifies flags (0x7E), escapes (0x7D, XOR 0x20),
protocol ID, and SHTP content; it specifies **no CRC/checksum field**. Do not add an
imaginary CRC or treat the reference to RFC-1662 escaping as a CRC requirement.
Protocol ID 0 carries UART control messages; ID 1 carries SHTP packets.

Design requirements:

- Collect into bounded staging storage; publish measurements only after closing
  delimiter and validation of the entire packet. No partial live-register updates.
- Validate decoded length (including the four-byte SHTP header), minimum/maximum,
  channel, protocol ID, report boundaries and report sizes. Parse the continuation
  bit separately; reject/count unsupported continuations without masking them into
  an apparently valid standalone report. Establish limits from advertisement and
  explicit implementation bounds; do not allocate from unchecked wire lengths.
- Unknown sensor reports cannot be skipped by guessing their length. Either use a
  verified size table or discard the packet and report an unsupported-report error.
- Track SHTP sequence separately per channel and SH-2 sequence per report type,
  with modulo-256 rollover. A gap diagnoses loss; it does not verify payload bits.
- Abort staged data on UART framing error, malformed escape, timeout, sensor reset
  notification or FIFO overflow. After overflow, flush queued bytes and invalidate
  staging before hunting a new delimiter; never splice bytes across a loss event.
- On FPGA startup, begin in HUNT_FLAG and ignore preceding bytes. Clear escape
  state at delimiters, tolerate repeated flags, then require a complete valid frame.
  Never depend on seeing a boot advertisement from an already-running sensor.
- Count a sensor reset on a validated reset/initialization indication, deduplicated
  for one reset episode. A truncated packet alone does not prove a sensor reset;
  count it as a framing/timeout fault until there is positive evidence.

A bit flip that changes a measurement while preserving valid structure can remain
undetected. Plausibility checks on the Pi (range, motion continuity, quaternion norm,
status) can flag some such cases but cannot guarantee integrity. Retain original
integer values with status; do not silently clamp them. A CRC on the FPGA-to-Pi
snapshot protects that later link only, not bytes already corrupted from the IMU.

Expose separate saturating 32-bit counters in the eventual Pi register map:
`sensor_reset_count` (per reset episode), `length_error_count` (per rejected packet),
`fifo_overflow_count` (per dropped byte/write), `uart_frame_error_count`,
`escape_error_count`, `packet_timeout_count`, `unsupported_report_count`,
`continuation_error_count`, and per-channel sequence-gap events. Counters clear on
FPGA reset; any software-clear interface must be explicit. They are requirements
for later modules, not outputs already implemented by the FIFO skeleton.

## Per-report freshness contract

Each report's eventual register bank stores signed integer components, a Q-point
field, SHTP channel and sequence, SH-2 report sequence and status, 64-bit FPGA
`capture_us`, `has_sample`, and `new_since_last_snapshot`.

SHTP sequence belongs to a channel/packet, not to an individual sensor: multiple
reports in a packet share it. Preserve the SH-2 per-report sequence too. Do not use
sequence changes alone as the freshness flag (wraparound and shared packets).

Capture `capture_us` from the free-running 1 MHz counter at synchronized H_INTN
assertion for the packet and carry it with its reports. With no H_INTN connection,
explicitly select a fallback timestamp at receipt of the opening flag byte.
This is an arrival/capture timestamp, not the sensor's sampling instant. Preserve
SH-2 base timestamp/delay information as metadata for later sample-time alignment;
do not silently label receive time as sample time.

Commit sets a per-report pending bit. A snapshot copies the last complete value,
metadata and pending bit, then consumes pending. If commit and snapshot share an
edge, snapshot takes pre-edge state; the new commit remains pending for the next
snapshot. If the IMU goes silent, the first snapshot may consume an earlier pending
update; every subsequent snapshot has new=false, with value/sequence/time retained.
Before the first report, has_sample=false. A confirmed sensor reset invalidates
has_sample and pending until new data; retained bits are never presented as current.

## Explicit acceptance tests for later exercises

| Test name | Required observation |
|---|---|
| `tx_gap_measured_each_wire_byte` | Measure stop-end to next start for every byte including escapes/flags and packet boundaries; verify 100 and 120 us parameter settings. |
| `stm32_configuration_matches` | Decode outgoing commands; compare IDs, order, intervals, flags, batching, 120 us byte pacing and 5 ms feature gaps against pinned firmware. |
| `uart_control_buffer_status` | Parse protocol-ID-0 BSN; no command without sufficient unexpired buffer allowance; BSQ/timeout recovery terminates. |
| `reports_target_400_hz` | Simulate 400 reports/s of each type and interleaved/batched arrivals; compare exact integers, signs, component order and metadata. Also run 400/400/100 baseline. |
| `silent_imu_retains_value_clears_new` | Stop one report and then all reports mid-run; each bank retains last data/time/seq, and consumed new flags stay false. |
| `snapshot_same_edge_as_report` | No torn values or lost/double-consumed freshness at coincident commit/snapshot. |
| `mid_packet_sensor_reset_recovers` | Truncate packet, emit valid reset/boot traffic, then clean reports; no partial publish, reset counter increments once and decoder resumes. |
| `corrupted_length_recovers` | Exercise lengths <4, too short/long versus actual, oversized, and unsupported continuation; no unbounded wait or write, exact counter delta, next good packet decodes. |
| `fifo_overflow_recovers` | Stall consumer, overflow at each packet region including escapes, flush and resync; count dropped bytes and decode subsequent complete packet without stale-byte splicing. |
| `attach_mid_stream_resynchronizes` | Start at all bit positions, header/payload/escape/stop positions; hunt flags then accept a complete packet, even with no advertisement. |
| `sequence_rollover_and_loss` | Independent channel/report sequence spaces, 255-to-0 wrap, loss diagnostics; no assumed accel/gyro/quaternion simultaneity. |
| `truncation_timeout_and_bad_escape` | Explicit timeout and malformed-escape counters; retain last values, discard staged updates, resume on valid framing. |
| `plausible_payload_corruption` | Demonstrate that a structurally valid bit-flipped value cannot always be rejected without a checksum; do not claim complete corruption detection. |
| `stm32_capture_replay` | Replay the exact same recorded stream to Python reference and FPGA; compare per-report events, not just latest-value snapshots. |

The FPGA is the sole host: after reset it waits for the BNO085 advertisement, requests
the 400/400/100 profile, confirms configured intervals through Get Feature responses,
and owns reset recovery. The 1 kHz snapshot can collapse burst arrivals into one last
value, so use a temporary report-event trace when validating individual report rates.

## Sources

- [SH-2 Reference Manual v1.9](https://www.ceva-ip.com/wp-content/uploads/SH-2-Reference-Manual.pdf), sections 6.5.9, 6.5.13, 6.5.18, 6.5.5 and 7.2.
- [SHTP v1.10](https://www.ceva-ip.com/wp-content/uploads/Sensor-Hub-Transport-Protocol.pdf), sections 4.1-4.5.
- [BNO08X datasheet v1.16](https://docs.sparkfun.com/SparkFun_VR_IMU_Breakout_BNO086_QWIIC/assets/component_documentation/BNO080_085-Datasheet_v1.16.pdf), sections 1.2.3.1 and 6.9.
- [AMD UG472](https://www.amd.com/content/dam/xilinx/support/documents/user_guides/ug472_7Series_Clocking.pdf) and [UG949 clock crossings](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Limiting-Synchronous-Clock-Domain-Crossing-Paths).
