# Interface ownership and integration

The team owns separate modules in one repository. Module names are globally
unique; use one feature branch per person, never develop together on main.

| Folder | Responsibility |
|---|---|
| `rtl/common`, `sim/common` | FIFO, timing, shared primitives |
| `rtl/uart`, `sim/uart` | Generic serial byte transport |
| `rtl/imu`, `sim/imu` | BNO085 UART-SHTP and SH-2 reports |
| `rtl/pi_link`, `sim/pi_link` | Snapshot framing, CRC, Pi-facing SPI slave |
| `rtl/spi`, `sim/spi` | Teammate-owned encoder SPI master and AS5047P readers |
| `rtl/can`, `sim/can` | CAN FD integration and actuator records |
| `rtl/gpio`, `sim/gpio` | Foot-switch synchronization/debounce |
| `rtl/top` | Board tops connecting tested modules |
| `pi`, `tests` | Pi decoder/reader and host unit tests |
| `constraints` | Reviewed board pin assignments and timing constraints |
| `docs` | Shared protocol, ownership, and hardware procedures |

The encoder SPI master and Pi SPI slave are DIFFERENT peripherals. The FPGA
clocks the encoders; the Pi clocks the FPGA. The new Pi demo allocates JA1-4;
coordinate before putting encoder signals on that connector. Production pin
allocation is a team integration decision, not inherited silently from the demo.
The STM32 harness uses two two-device encoder daisy chains, not four individual
CS connections: check `enc_as5047p.h` in the STM32 repo before copying wiring.

Start work after the folder-reorganization commit:

```bash
git pull --ff-only origin main
git switch -c feature/encoder-spi
# edit rtl/spi/ and sim/spi/
source ~/fpga/venv/bin/activate
make -C sim TOP=your_unique_module
# commit only your files, push your branch, open a PR
```

If a teammate already has uncommitted work, commit it on their own branch before
merging/rebasing the new main. Resolve renamed paths once; do not recreate old
flat rtl files, or both modules may be compiled. Each checkout's generated build
files are ignored. Run simulations sequentially per checkout: results.xml is
shared. Use a separate git worktree for parallel local simulations.

Before integration agree on clk/rst, units, byte order, validity, update strobes,
timestamps and reset behavior. Default is 100 MHz, synchronous active-high reset.
No asynchronous multi-bit bus directly into the snapshot payload: synchronize or
cross via an appropriate FIFO first. Do not edit shared packet offsets privately.

`pi_link.payload` is 606 bytes, low byte in bits 7:0. See PI_LINK_PROTOCOL.md.
Construct it combinationally from same-clock retained sensor registers. The link
captures it on `sample_accepted`. Connect that exact signal to the IMU parser's
`snapshot` input so missed snapshots do not consume freshness. On a simultaneous
report commit, the capture sees pre-edge state and the new report stays pending.
The Pi-link demo has no real sensor producer; production payload assembly is the
next integration task. Unimplemented groups must have their valid flags clear.

Run `python scripts/run_tests.py` before merging. The Makefile and Vivado build
find `.v` files one directory below rtl automatically. Python tests live one
directory below sim and retain unique test_<module>.py names. VHDL/IP CAN cores
will need explicit build integration when added; folder existence is not support.
