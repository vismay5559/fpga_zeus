"""ZFP1 sensor snapshot v1. See docs/PI_LINK_PROTOCOL.md for the wire contract."""
import binascii
import struct
from dataclasses import dataclass

MAGIC = b"ZFP1"
VERSION = 1
MESSAGE_STATE = 1
FRAME_SIZE = 640
HEADER_SIZE = 32
PAYLOAD_SIZE = 606
HEADER = struct.Struct("<4sBBHIQIII")
IMU = struct.Struct("<4hH6BHHQiiI")
JOINT = struct.Struct("<4fIHH4B")
ENCODER = struct.Struct("<HBBI")
CONTACT = struct.Struct("<BBHHHQ")
JOINT_NAMES = (
    "left_hip_pitch", "left_hip_roll", "left_knee_pitch", "left_ankle_pitch",
    "right_hip_pitch", "right_hip_roll", "right_knee_pitch", "right_ankle_pitch",
    "waist_roll", "waist_pitch",
)
JOINT_ADDRESSES = ((0, 1), (0, 2), (0, 3), (0, 4), (1, 1), (1, 2),
                   (1, 3), (1, 4), (0, 5), (1, 5))
DIAGNOSTICS = (
    "uart_frame_errors", "fifo_overflows", "invalid_protocols", "escape_errors",
    "length_errors", "oversize_errors", "packet_timeouts", "continuation_errors",
    "unsupported_reports", "packet_format_errors", "ignored_packets",
    "shtp_sequence_gaps", "accel_sequence_gaps", "gyro_sequence_gaps",
    "rotation_sequence_gaps", "sensor_resets", "bsn_queries", "bsn_timeouts",
    "config_retries", "confirmation_errors", "can0_rx_dropped", "can1_rx_dropped",
    "can0_tx_dropped", "can1_tx_dropped", "can0_bus_off", "can1_bus_off",
    "encoder_errors", "encoder_stalls", "command_timeouts", "last_command_seq",
    "safety_state", "health", "advertised_uart_timeout_ms",
)


def crc16(data):
    return binascii.crc_hqx(data, 0xFFFF)


def encode(payload, sequence=0, timestamp_us=0, dropped=0, flags=0):
    """Reference encoder for tests/replay; hardware performs this on the FPGA."""
    if len(payload) != PAYLOAD_SIZE:
        raise ValueError("payload must contain exactly 606 bytes")
    body = HEADER.pack(MAGIC, VERSION, MESSAGE_STATE, FRAME_SIZE, sequence,
                       timestamp_us, dropped, flags, 0) + bytes(payload)
    return body + struct.pack("<H", crc16(body))


@dataclass(frozen=True)
class ImuReport:
    raw: tuple
    accuracy_raw: int
    flags: int
    q_point: int
    accuracy_q_point: int
    status: int
    report_sequence: int
    shtp_sequence: int
    delay: int
    capture_us: int
    base_delta: int
    rebase_delta: int

    @property
    def valid(self):
        return bool(self.flags & 1)

    @property
    def new(self):
        return bool(self.flags & 2)

    def scaled(self):
        """Scale only on the Pi. Quaternion order remains i,j,k,real."""
        if not self.valid:
            return None
        return tuple(x / (1 << self.q_point) for x in self.raw)


@dataclass(frozen=True)
class Snapshot:
    sequence: int
    timestamp_us: int
    dropped: int
    flags: int
    imu: tuple
    joints: tuple
    encoders: tuple
    contacts: tuple
    diagnostics: dict
    raw: bytes


def decode(raw):
    raw = bytes(raw)
    if len(raw) != FRAME_SIZE:
        raise ValueError("wrong frame length")
    magic, version, kind, size, seq, stamp, dropped, flags, reserved = HEADER.unpack_from(raw)
    if (magic, version, kind, size) != (MAGIC, VERSION, MESSAGE_STATE, FRAME_SIZE):
        raise ValueError("unsupported frame header")
    if crc16(raw[:-2]) != struct.unpack_from("<H", raw, FRAME_SIZE - 2)[0]:
        raise ValueError("CRC mismatch")
    if flags & ~0x8000001F:
        raise ValueError("unknown header flags")
    if reserved or any(raw[612:638]):
        raise ValueError("reserved bytes must be zero in v1")
    reports = []
    for i, expected_q in enumerate((8, 9, 14)):
        f = IMU.unpack_from(raw, 32 + i * 40)
        if f[12] or f[16] or f[5] & ~7:
            raise ValueError("invalid IMU reserved bits")
        if f[5] & 1 and (f[6] != expected_q or f[8] > 3 or f[11] > 0x3FFF):
            raise ValueError("invalid IMU metadata")
        if i < 2 and (f[3] or f[4] or f[7]):
            raise ValueError("vector padding/accuracy must be zero")
        if i == 2 and f[5] & 1 and f[7] != 12:
            raise ValueError("invalid quaternion accuracy Q point")
        reports.append(ImuReport(tuple(f[:4]), f[4], *f[5:12], f[13], f[14], f[15]))
    joints = tuple(JOINT.unpack_from(raw, 152 + i * 28) for i in range(10))
    for i, joint in enumerate(joints):
        if joint[8] & ~15 or (joint[8] and joint[9:11] != JOINT_ADDRESSES[i]):
            raise ValueError("invalid actuator flags/address")
    encoders = tuple(ENCODER.unpack_from(raw, 432 + i * 8) for i in range(4))
    for raw_angle, enc_flags, pad, age in encoders:
        if raw_angle > 16383 or pad or enc_flags & ~3:
            raise ValueError("invalid encoder record")
    contacts = CONTACT.unpack_from(raw, 464)
    if contacts[2]:
        raise ValueError("invalid contact padding")
    if flags & 4 and (contacts[0] & ~3 or contacts[1] != contacts[0]):
        raise ValueError("invalid two-switch contact mask")
    diagnostics = dict(zip(DIAGNOSTICS, struct.unpack_from("<33I", raw, 480)))
    return Snapshot(seq, stamp, dropped, flags, tuple(reports), joints,
                    encoders, contacts, diagnostics, raw)
