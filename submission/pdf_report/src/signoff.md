The sign-off service of SPEC Section 8.3 synthesises the submitted RTL with GPDK045 under the Section 6 constraints, with retiming enabled at 800 MHz. It simulates the netlists with SDF back-annotation against its own testbench, which samples at the rising edge. Candidates were submitted on `check/*` branches and the final designs on `check/final` [16].

| | 400 MHz open source | 400 MHz GPDK045 | 800 MHz open source | 800 MHz GPDK045 |
|--------------------------|----------:|----------:|----------:|----------:|
| Worst slack (target) | +172 ps (125) | +158 ps (125) | +124 ps (62) | +75 ps (62) |
| Cell area | 2183.9 µm² | 2427.5 µm² | 3864.2 µm² | 4240.5 µm² |
| Vectorless power | 550.9 µW | 177.5 µW | 2113.7 µW | 805.9 µW |
| SDF simulation | ALL PASS, 384 products | Pass, 1264 of 1264 | ALL PASS, 384 products | Pass, 1162 of 1162 |

Functionally the two flows agree completely, on a different library, with a different synthesis tool, and with testbenches that sample on opposite clock edges. That includes the combinational `writeMem_val` at 400 MHz. For the netlist run at 1.25 ns that violates timing, both flows return no product, and the sign-off simulator also reports its timing-check violations directly.

At 400 MHz the slacks agree closely (172 against 158 ps). At 800 MHz sign-off reports 75 ps where our flow reports 124 ps. Across the round 4 candidates, the two flows differed by up to about 60 ps in either direction. GPDK045 area is 11 % (400 MHz) and 10 % (800 MHz) larger than ours. Its vectorless power is 3.1 and 2.6 times lower, which reflects the different library, supply voltage and default activity rather than the designs.

The two flows ranked the candidates differently in one respect. Our flow's vectorless power fell with every flip-flop removed. In sign-off, changes that cost slack, such as the combinational output path at 800 MHz and the digit-gated reset, raised power despite saving cells. The final choices were therefore made only on sign-off results.
