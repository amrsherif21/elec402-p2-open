# Sign-off check check/final

Commit `efbfecdf64f2`, checked 2026-11-08 09:06 UTC.

Each implementation is synthesized with the GPDK045 library under the constraints of SPEC.md Section 6. The resulting netlists are simulated with SDF back-annotation against an independent testbench that samples outputs at the rising edge.

| Check | Result |
|---|---|
| GPDK045 static timing, 400 MHz at 2.5 ns | WNS 203 ps, meets the slack target (target 125 ps) |
| GPDK045 cell area, 400 MHz | 2660.8 µm², within budget (limit 6000 µm²) |
| GPDK045 power estimate, 400 MHz | 215.2 µW (vectorless) |
| GPDK045 static timing, 800 MHz at 1.25 ns | WNS 158 ps, meets the slack target (target 62 ps) |
| GPDK045 cell area, 800 MHz | 4416.2 µm², within budget (limit 12000 µm²) |
| GPDK045 power estimate, 800 MHz | 829.7 µW (vectorless) |
| Gate-level simulation with SDF, 400 MHz at 2.5 ns | Pass, 1204/1204 products, 0 timing-check messages |
| Gate-level simulation with SDF, 800 MHz at 1.25 ns | Pass, 1162/1162 products, 0 timing-check messages |
| 400 MHz netlist at 1.25 ns (informational: normally fails, which shows that violations are detected) | Fail, 0/0 products, 3754 timing-check messages; violated F1 F2 F4 F5 F6 F8 F9 STALL |
