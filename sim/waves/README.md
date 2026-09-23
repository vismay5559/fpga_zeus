# Checked-in UART waveform

`uart_rx_single_bytes.fst` is the real waveform produced by the passing
`test_uart_rx.single_bytes` cocotb test with `CLKS_PER_BIT=16`. It is deliberately
small so the evidence can live in Git. `uart_rx_single_bytes.gtkw` selects the
useful signals: asynchronous RX, synchronizer, start arming, busy state, clock
and bit counters, shift register, decoded byte, valid and frame error.

Open it from `sim/`:

```bash
make view-uart-example
```

Regenerate it with:

```bash
rm -rf sim_build/uart_rx_c16
make TOP=uart_rx COCOTB_TESTCASE=single_bytes WAVES=1
cp sim_build/uart_rx_c16/uart_rx.fst waves/uart_rx_single_bytes.fst
```
