The sign-off service of SPEC Section 8.3 synthesises the submitted RTL with GPDK045 under the Section 6 constraints, with retiming enabled at 800 MHz, and simulates the netlists with SDF back-annotation against its own testbench, which samples at the rising edge. Candidates were submitted on `check/*` branches and the final designs on `check/final` [16].

| | 400 MHz open source | 400 MHz GPDK045 | 800 MHz open source | 800 MHz GPDK045 |
|--------------------------|----------:|----------:|----------:|----------:|
| Worst slack (target) | +263 ps (125) | +S4W ps (125) | +140 ps (62) | +S8W ps (62) |
| Cell area | 2449.6 µm² | S4A µm² | 4017.9 µm² | S8A µm² |
| Vectorless power | 633.4 µW | S4P µW | 2186.6 µW | S8P µW |
| SDF simulation | ALL PASS, 384 products | Pass, S4N | ALL PASS, 384 products | Pass, S8N |

Functionally the two flows agree completely, on a different library, with a different synthesis tool, and with testbenches that sample on opposite clock edges. For the netlist run at 1.25 ns that violates timing, both flows return no product; the sign-off simulator also reports its timing-check violations directly.

Both flows meet the slack target, but the margins differ. At 800 MHz, GPDK045's margin is smaller than ours, even though its corner is faster. Its synthesis retimes the six ranks and spends the remaining slack on area recovery, which is what slack beyond the target is for. GPDK045 area is S4R and S8R of ours. Its vectorless power is S4Q and S8Q lower, which reflects the different library, supply voltage and default activity rather than the designs. Both flows rank the design changes the same way: each reduction in flip-flops lowered area and power in both. The Wallace tree's extra logic is the one case where our flow's area (−3 %) and sign-off power (+11 %) pointed in different directions, and the sign-off result decided it.
