import struct
import unittest
from pi import fpga_protocol as p


class ProtocolTests(unittest.TestCase):
    def test_layout_and_known_crc(self):
        self.assertEqual((p.HEADER.size, p.IMU.size, p.JOINT.size,
                          p.ENCODER.size, p.CONTACT.size), (32, 40, 28, 8, 16))
        self.assertEqual(p.crc16(b"123456789"), 0x29B1)
        self.assertEqual(len(p.JOINT_NAMES), 10)
        self.assertEqual(p.JOINT_ADDRESSES[-2:], ((0, 5), (1, 5)))

    def test_signed_imu_metadata_and_all_ten_joints(self):
        data = bytearray(p.PAYLOAD_SIZE)
        p.IMU.pack_into(data, 0, -256, 512, -32768, 0, 0,
                        7, 8, 0, 3, 255, 17, 0x123, 0, 2**40, -100, 20, 0)
        p.IMU.pack_into(data, 80, 0, 0, 0, 16384, 4096,
                        3, 14, 12, 3, 7, 18, 0, 0, 99, 0, 0, 0)
        for i, (bus, node) in enumerate(p.JOINT_ADDRESSES):
            p.JOINT.pack_into(data, 120 + 28*i, i + 0.25, -i, 2*i, i,
                             i, 10, 20, 8, 15, bus, node)
        pkt = p.decode(p.encode(data, 0xFFFFFFFF, 2**48, 4, 1))
        self.assertEqual(pkt.imu[0].scaled(), (-1, 2, -128, 0))
        self.assertEqual(pkt.imu[2].scaled(), (0, 0, 0, 1))
        self.assertIsNone(pkt.imu[1].scaled())
        self.assertEqual(pkt.joints[9][0], 9.25)
        self.assertEqual((pkt.sequence, pkt.timestamp_us, pkt.dropped), (0xFFFFFFFF, 2**48, 4))

    def test_corruption_truncation_and_wrong_version(self):
        frame = p.encode(bytes(p.PAYLOAD_SIZE))
        for index in (0, 4, 31, 100, 400, 638):
            broken = bytearray(frame); broken[index] ^= 1
            with self.assertRaises(ValueError): p.decode(broken)
        with self.assertRaises(ValueError): p.decode(frame[:-1])
        broken = bytearray(frame); broken[4] = 8
        broken[-2:] = struct.pack('<H', p.crc16(broken[:-2]))
        with self.assertRaises(ValueError): p.decode(broken)

    def test_invalid_metadata_even_with_valid_crc(self):
        data = bytearray(p.PAYLOAD_SIZE)
        data[10] = 1; data[11] = 255
        with self.assertRaises(ValueError): p.decode(p.encode(data))
        with self.assertRaises(ValueError): p.decode(p.encode(bytes(p.PAYLOAD_SIZE), flags=32))
        data = bytearray(p.PAYLOAD_SIZE); data[-1] = 1
        with self.assertRaises(ValueError): p.decode(p.encode(data))


if __name__ == '__main__': unittest.main()
