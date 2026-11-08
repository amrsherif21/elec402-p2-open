The sign-off service of SPEC Section 8.3 synthesises the submitted RTL with GPDK045 under the Section 6 constraints, with retiming enabled at 800 MHz, and simulates the netlists with SDF back-annotation against its own testbench, which samples at the rising edge. Candidates were submitted on `check/*` branches and the final designs on `check/final` [16].

| | 400 MHz open source | 400 MHz GPDK045 | 800 MHz open source | 800 MHz GPDK045 |
|--------------------------|----------:|----------:|----------:|----------:|
| Worst slack (target) | +263 ps (125) | +203 ps (125) | +140 ps (62) | +158 ps (62) |
| Cell area | 2449.6 µm² | 2660.8 µm² | 4017.9 µm² | 4416.2 µm² |
| Vectorless power | 633.4 µW | 215.2 µW | 2186.6 µW | 829.7 µW |
| SDF simulation | ALL PASS, 384 products | Pass, 1204 of 1204 | ALL PASS, 384 products | Pass, 1162 of 1162 |

Functionally the two flows agree completely, on a different library, with a different synthesis tool, and with testbenches that sample on opposite clock edges. For the netlist run at 1.25 ns that violates timing, both flows return no product. The sign-off simulator also reports its timing-check violations directly.

Both flows meet the slack target with different margins: at 400 MHz, 203 ps in sign-off against 263 ps in our flow, and at 800 MHz, 158 against 140 ps. The scorecard does not state its corner. A commercial synthesis tool closes timing to the constraint and then recovers area with the slack it has left, so its margin says little about raw speed. GPDK045 area is 8.6 % (400 MHz) and 9.9 % (800 MHz) larger than ours. Its vectorless power is 2.9 and 2.6 times lower, which reflects the different library, supply voltage and default activity rather than the designs. Both flows ranked every flip-flop reduction the same way. The one disagreement was the Wallace tree at 800 MHz, where our flow showed 1.8 % less area and sign-off showed 11.2 % more power. The judged sign-off result decided that choice.
