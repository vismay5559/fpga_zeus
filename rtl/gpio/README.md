# Two center-sole foot contacts

`foot_switches.v` is implemented and tested. Physical switches are active-low:
open=1 from a pull-up, closed=0 to ground. Bit0 is left foot and bit1 right foot. Confirm make after 3 sampled
milliseconds and break after 8 (matching STM32 defaults). `cycle_timer.sample` is the 1 kHz sampling pulse.

Outputs include stable identical per-switch and per-foot masks, one-clock transition pulses,
per-switch transition times, latest transition time, and saturating per-foot ages.
The Pi bench demo populates bytes 464..479 of the ZFP1 packet and sets the
contacts-present flag. A production top still must connect this to the remaining
sensor and safety modules. See ../../docs/FOOT_SWITCHES.md for examples and tests.
