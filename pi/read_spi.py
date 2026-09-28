"""Read the bench link; run from repo root: python -m pi.read_spi --help.
Requires spidev and libgpiod Python API v2 on the Pi. No motor commands are sent.
"""
import argparse
import time
from pi.fpga_protocol import decode, FRAME_SIZE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bus', type=int, default=0)
    parser.add_argument('--device', type=int, default=0)
    parser.add_argument('--gpiochip', default='/dev/gpiochip0')
    parser.add_argument('--cs', type=int, default=25, help='GPIO line offset for manual CS')
    parser.add_argument('--ready', type=int, default=24, help='GPIO line offset for data-ready')
    parser.add_argument('--speed', type=int, default=1_000_000)
    parser.add_argument('--seconds', type=float, default=60)
    args = parser.parse_args()
    if not 1 <= args.speed <= 10_000_000:
        parser.error('speed must be 1..10000000 Hz')
    import gpiod
    import spidev
    from gpiod.line import Direction, Value
    spi = spidev.SpiDev()
    spi.open(args.bus, args.device)
    try:
        spi.mode = 0; spi.max_speed_hz = args.speed; spi.bits_per_word = 8
        spi.lsbfirst = False; spi.no_cs = True
        # Explicit GPIO CS allows setup/hold margins independent of SPI driver.
        with gpiod.request_lines(args.gpiochip, consumer='fpga-pi-link', config={
            args.cs: gpiod.LineSettings(direction=Direction.OUTPUT,
                                        active_low=True, output_value=Value.INACTIVE),
            args.ready: gpiod.LineSettings(direction=Direction.INPUT),
        }) as lines:
            start = last_print = time.monotonic()
            count = bad = gaps = resets = 0
            previous = None
            last = None
            zeros = [0] * FRAME_SIZE
            while time.monotonic() - start < args.seconds:
                if lines.get_value(args.ready) != Value.ACTIVE:
                    time.sleep(0.00005)
                    continue
                lines.set_value(args.cs, Value.ACTIVE)
                try:
                    time.sleep(0.00001)
                    raw = spi.xfer2(zeros)
                    time.sleep(0.00001)
                finally:
                    lines.set_value(args.cs, Value.INACTIVE)
                time.sleep(0.00001)
                try:
                    last = decode(raw)
                except ValueError:
                    bad += 1
                    continue
                count += 1
                if previous is not None:
                    if last.timestamp_us < previous.timestamp_us:
                        resets += 1
                    else:
                        gaps += (last.sequence - previous.sequence - 1) & 0xFFFFFFFF
                previous = last
                now = time.monotonic()
                if now - last_print >= 1:
                    print(f'{count/(now-start):.1f} packets/s, seq={last.sequence}, '
                          f'us={last.timestamp_us}, fpga_dropped={last.dropped}, '
                          f'gap={gaps}, bad={bad}, resets={resets}, '
                          f'test_mode={bool(last.flags & 0x80000000)}, '
                          f'switches={last.contacts[0]:02b}, feet={last.contacts[1]:02b}, '
                          f'contact_ticks={last.contacts[3:5]}', flush=True)
                    last_print = now
            elapsed = time.monotonic() - start
            print(f'Final: {count} valid in {elapsed:.3f}s ({count/elapsed:.1f}/s), '
                  f'{bad} invalid, {gaps} missing, {resets} resets')
    finally:
        spi.close()


if __name__ == '__main__':
    main()
