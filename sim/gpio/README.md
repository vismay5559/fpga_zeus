# Foot-switch tests

Run from the repository root after activating the simulation environment:

```bash
make -C sim TOP=foot_switches
make -C sim TOP=pi_link_demo_top
```

The first tests active-low bit order, debounce, bounce, age and transition times.
The second sends real SPI bits through the board demo and decodes the contact
record with the Pi's Python decoder.
