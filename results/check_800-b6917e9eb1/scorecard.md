# Sign-off check check/800

Commit `b6917e9eb1c8`, checked 2026-11-08 06:48 UTC.

Each implementation is synthesized with the GPDK045 library under the constraints of SPEC.md Section 6. The resulting netlists are simulated with SDF back-annotation against an independent testbench that samples outputs at the rising edge.

| Check | Result |
|---|---|
| GPDK045 static timing, 400 MHz at 2.5 ns | WNS 156 ps, meets the slack target (target 125 ps) |
| GPDK045 cell area, 400 MHz | 2752.1 µm², within budget (limit 6000 µm²) |
| GPDK045 power estimate, 400 MHz | 224.6 µW (vectorless) |
| GPDK045 static timing, 800 MHz at 1.25 ns | WNS 148 ps, meets the slack target (target 62 ps) |
| GPDK045 cell area, 800 MHz | 5674.5 µm², within budget (limit 12000 µm²) |
| GPDK045 power estimate, 800 MHz | 1121.9 µW (vectorless) |
| Gate-level simulation with SDF, 400 MHz at 2.5 ns | Pass, 1204/1204 products, 0 timing-check messages |
| Gate-level simulation with SDF, 800 MHz at 1.25 ns | Pass, 1249/1249 products, 0 timing-check messages |
| 400 MHz netlist at 1.25 ns (informational: normally fails, which shows that violations are detected) | Fail, 0/0 products, 4058 timing-check messages; violated F1 F4 F5 F6 F8 F9 STALL |
