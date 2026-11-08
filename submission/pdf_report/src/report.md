---
title: "mkMultBuff: a pipelined signed 16 × 16 multiplier with a 64-entry fill/drain buffer at 400 MHz and 800 MHz"
subtitle: "Design report, open-source flow on Nangate45 (FreePDK45), slow corner"
author: "Claude Opus 5.5 (Anthropic), AI agent in Claude Code"
date: "8 November 2026"
---

\begin{center}\fbox{\parbox{0.92\textwidth}{\textbf{AI-generated report.} This report, the RTL, the testbenches and the flow scripts were produced by an AI agent, Claude Opus 5.5 (Anthropic), working in a Claude Code session with subagents. The model is the author of record. Every number comes from a tool log under \texttt{submission/syn\_reports/} or from the sign-off scorecards, and \texttt{notes/WORKLOG.md} records the decisions in order.}}\end{center}

# Summary of results

Two implementations of `mkMultBuff` were built, one for a 2.5 ns clock and one for a 1.25 ns clock. Each takes one pair of 16-bit operands per cycle, writes the 32-bit products to an external 64-word memory in order, and returns them once the memory is full. Both meet the slack target of SPEC Section 5 in the open-source flow at the Nangate45 slow corner (0.95 V, 125 °C) and in the GPDK045 sign-off. Area and power are judged on the sign-off results. Since the last revision, the 800 MHz design has lost 135 of its 577 flip-flops and the 400 MHz design 25 of its 166. In sign-off this cut area by 22 % and 3 %, and power by 26 % and 4 %.

| | 400 MHz (2.5 ns) | 800 MHz (1.25 ns) |
|---------------------------------------|------------:|------------:|
| Register ranks (latency) / flip-flops | 3 / 141 | 6 / 442 |
| GPDK045 sign-off: area | 2660.8 µm² | 4416.2 µm² |
| GPDK045 sign-off: power (vectorless) | 215.2 µW | 829.7 µW |
| GPDK045 sign-off: worst slack (target) | 203 ps (125) | 158 ps (62) |
| GPDK045 sign-off: SDF simulation | 1204 of 1204 products | 1162 of 1162 products |
| Previous design in sign-off: area / power | 2752.1 µm² / 224.6 µW | 5674.5 µm² / 1121.9 µW |
| Nangate45: worst setup / hold slack | +0.263 / +0.061 ns | +0.140 / +0.041 ns |
| Nangate45: cell area (sequential) | 2449.6 (637.6) µm² | 4017.9 (2000.9) µm² |
| Nangate45: power, vectorless estimate | 633.4 µW | 2186.6 µW |
| Nangate45: power from simulation, whole run | 644.7 µW | 2491.9 µW |
| Nangate45: 64-cycle fill / drain window | 1599.6 / 380.0 µW | 4530.0 / 1945.6 µW |
| RTL, gate-level and SDF checkers | ALL PASS | ALL PASS |
| Netlist that violates timing | TIMING FAIL | TIMING FAIL |
| Flip-flops proven reset by `RST_N` (F14) / RTL mutants caught | 141 of 141 / 11 of 11 | 442 of 442 / 13 of 13 |

A rerun of the whole flow from a fresh clone of the repository reproduced every netlist, SDF file and report byte for byte.

# Design decisions

## What is being minimised

The judged power is GPDK045's vectorless estimate. It assumes a default activity on every net, so it follows the number of cells and above all the number of flip-flops, each of which burns clock power every cycle, and it cannot see activity savings such as operand isolation. Slack beyond the target is worth nothing. The cost to minimise is therefore flip-flops first and cells second, subject to the slack target in both flows. The binding timing constraint is the open-source flow, because its slow corner is two to three times slower than GPDK045.

Pipelining places a register on every path that crosses a cutset of the data-flow graph, so a register rank costs the width of the cutset where it is placed [18]. Where the multiplier is cut is the main lever. The operands (32 bits) and the product (32 bits) are the narrowest cuts, and the partial-product matrix (144 bits) is the widest. Minimum-register retiming [19] solves this placement formally, but retiming a circuit with initial states needs an equivalent reset state [20]. An earlier retimed candidate lost the synchronous reset of most of its registers, which F14 forbids. The cuts were therefore placed by hand from per-rank slack measured with STA (`submission/scripts/ranks.tcl`), and every candidate went through the same flow (`eval_candidate.sh`).

## Control

The block passes through three states, shown in Figure 1. When the 64th pair is accepted, F5 requires `RDY_mult` to fall at once, but F6 lets `RDY_blockRead` rise only after the last product reaches address 63. The state is held in the two registered ready flags, so the outputs cannot glitch. A counter of accepted pairs ends FILL, the last write ends WAIT, and the accepted read of address 63 ends DRAIN. A shift register of valid bits travels with the data, and its last bit is `EN_writeMem`. `EN_readMem` is the AND of `EN_blockRead` and the ready flag (F7), and `memVal_data` is a wire from `readMem_val` (F8).

![State machine of both implementations. The registered ready flags are the state: FILL = {1,0}, WAIT = {0,0}, DRAIN = {0,1}.](../fig/fsm.png){width=95%}

At 400 MHz the control uses 18 flops with one address pointer shared by fill and drain. At 800 MHz it uses 31 flops, down from 43. The pointers are split into two 3-bit halves with a registered carry, so the "= 63" test is short. The drain starts on the write made when the fill is closed and no other product is in flight, which is the write to address 63. Port-only copies of the two ready flags remain, because a flip-flop that drives a 23.5 fF port and the handshake logic needs 0.57 ns from the clock.

## Arithmetic

Both designs use radix-4 modified Booth partial products [10, 13]. Recoding the multiplier into eight digits halves the rows from sixteen to eight. The sign extensions are replaced by inverted sign bits and constants, and the +1 of each negated row is placed in a free bit. The multiplier is recoded before the first register, which stores 24 digit bits instead of 16 operand bits. Recoding after the register would save 8 flops, but it missed the 125 ps target at 400 MHz by 15 to 52 ps, and at 800 MHz it cost 534 µm² of extra logic to meet timing. The first register also loads zeros when no pair is accepted (operand isolation). This reuses the gate already needed for the synchronous reset and halves the measured whole-run power, although vectorless sign-off cannot see that saving.

## 400 MHz: three ranks, one internal cut at 51 bits

SPEC allows two ranks. With only the operand and product registers, the whole multiply must fit in one 2.5 ns stage, and it misses by 1.47 ns. A two-rank design without an operand register, with the logic placed before the first register, misses by 0.31 ns. The input port is driven by the SPEC's weak DFF_X1 model, and reaching 37 gates from it costs 0.83 ns before any logic. Three ranks are therefore the minimum.

The single internal cut sits at the narrowest cutset that meets the target, the two carry-save rows at the end of the tree. A bit-level tree makes those rows narrower than the row-wise tree. Table 1 compares Dadda's and Wallace's column compression [11] on the 144-bit Booth matrix. Dadda delays every reduction as long as possible, which minimises adders [21]. Wallace reduces as early as possible, which makes every intermediate cutset narrower. After four levels the Wallace tree leaves 51 bits to register, against 59 for the row tree. The final design (Figure 2) has 141 flops, generated by `submission/scripts/gen_tree.py`.

| Tree on the Booth matrix | FA / HA | Bits after level 1 / 2 / 3 / 4 |
|---------------------------------|----------:|------------------:|
| Dadda | 91 / 22 | 132 / 104 / 84 / 60 |
| Wallace | 92 / 55 | 112 / 86 / 69 / 59 |
| Wallace, no half adders in short columns | 100 / 20 | 112 / 84 / 65 / 52 |

![400 MHz datapath, three register ranks (shaded) with their widths in bits.](../fig/dp400.png){width=55%}

The critical path runs from a Booth digit in rank 1 through the selection gate, the compression tree and the ripple that resolves the lowest columns into rank 2. It arrives at 2.173 ns against 2.435 ns, for +0.263 ns.

## 800 MHz: six ranks

A flip-flop's clock-to-output delay (0.35 to 0.47 ns) and setup time leave about 0.72 ns of logic per 1.25 ns stage. Measured per rank, the previous seven-rank design had spare slack in several stages, and its widest ranks were the 144-bit partial-product rank and a 117-bit rank after compression level 1. The changes below removed one rank and narrowed two others.

The partial-product rank stays, because selection plus one compression level needs about 0.9 ns. The level-1 rank was removed by reordering every 3:2 compressor so that its latest-arriving input enters last, as `(x ^ y) ^ z`. With that ordering, levels 1 and 2 fit in one stage, and so do levels 3 and 4. The ranks then hold 92 and 60 bits.

The final adder was the other large cost. No single-stage 32-bit adder fits in 0.72 ns at this corner. The prefix networks of Harris's taxonomy [22] all missed: Han-Carlson [23] by 0.164 ns, Sklansky [24] by 0.176 ns, Kogge-Stone [12] by 0.177 ns, Brent-Kung [25] by 0.324 ns, and Yosys' own adder by 0.674 ns. The adder therefore takes two stages. A carry-increment adder with 4-bit blocks replaced the previous carry-select adder. Its middle rank holds the block sums for carry-in 0 and the block carry-outs for carry-in 0 and 1, which is 43 bits instead of about 64. The second stage resolves the block carries with a three-level prefix and increments the blocks that receive a carry.

![800 MHz datapath, six register ranks (shaded) with their widths in bits.](../fig/dp800.png){width=70%}

The critical path runs from a block-propagate bit in the adder's middle rank through the block-carry network and the increment select into the product register. It arrives at 1.057 ns against 1.196 ns, for +0.140 ns.

## Candidates and the sign-off decision

Three subagents evaluated candidates in parallel: cut placement and adders on the row tree, a bit-level tree generator, and clock gating. The best candidates were run through sign-off, and the final choice was made on the sign-off results.

| Candidate (sign-off) | Flops | Area (µm²) | Power (µW) | Slack (ps) |
|-------------------------------------------|----:|-------:|------:|----:|
| 800 MHz previous design | 577 | 5674.5 | 1121.9 | 148 |
| 800 MHz row tree, carry-increment adder (chosen) | 442 | 4416.2 | 829.7 | 158 |
| 800 MHz Wallace tree, carry-increment adder | 431 | 4192.6 | 922.4 | 91 |
| 400 MHz previous design | 166 | 2752.1 | 224.6 | 156 |
| 400 MHz row tree, one cut at two rows | 149 | 2648.1 | 218.6 | 441 |
| 400 MHz Wallace tree, one cut at two rows (chosen) | 141 | 2660.8 | 215.2 | 203 |

Area and power disagree at both frequencies, so the relative changes were added. At 800 MHz, the Wallace tree saves 5.1 % area but costs 11.2 % power, because its larger XOR network (100 full and 26 half adders) is charged at the default activity in vectorless analysis. The row tree was kept. At 400 MHz, the Wallace tree costs 0.5 % area and saves 1.6 % power and 8 flops, so it was chosen.

Clock gating was evaluated and rejected. A technology-independent gate (a latch plus an AND, enabled during reset to keep F14) cut the 400 MHz drain-window power by 51 to 73 %. But it raised the vectorless estimate (663 → 671 to 842 µW), because the gated clock net is charged while the port clock is not. Without a clock tree, which neither flow builds, the gated clock also arrived 1.4 to 2.0 ns late in SDF simulation, and every product failed.

# Verification

**RTL checker.** A subagent wrote `rtl_checker.sv` from SPEC.md without access to the RTL. It runs a cycle-accurate reference model of the handshake, learns the latency from the first write, and checks every output on every cycle against the requirement it belongs to (F1 to F15, data, X/Z), about 54 000 checks. Inputs change 0.1 ns after the rising edge and outputs are sampled at the falling edge, so the same checker runs race-free on the RTL and on the netlist. The stimulus covers 14 fill and drain phases (about 5900 cycles) with acceptance rates from 10 to 100 %, random operands, and the five directed pairs. It also drives the enables while their ready signal is 0, applies four resets including mid-drain, and runs one fill and one drain back to back for 64 cycles as power windows.

Mutation testing of the final RTL measures the checker's strength. It caught all 11 one-line faults at 400 MHz and all 13 at 800 MHz, including an early drain start, a pointer carry error and an adder carry-in error. A SAT check on each netlist proves F14, which simulation cannot show, by showing that every flip-flop's D input is constant whenever `RST_N` = 0.

**Gate-level checkers.** `sdf_checker_400.sv` and `sdf_checker_800.sv` run six mostly back-to-back phases on the SDF-annotated netlist. They report `TIMING FAIL` for any X or wrong `memVal_data` while `VALID_memVal` is 1, and also for missing products. Icarus Verilog applies the SDF delays but ignores `$setuphold` checks, so a violation shows up as a wrong product rather than X, as SPEC 8.2 allows. Both failure cases were demonstrated. A one-stage-multiplier netlist (−0.675 ns) failed at 400 MHz, and the 400 MHz netlist run at 1.25 ns (−0.951 ns) failed at 800 MHz. The sign-off simulator, which does evaluate timing checks, failed that last case too.

**RTL against gate-level waveforms.** The same gate-level checker was run on the RTL and on the annotated netlist and captured headlessly with GTKWave under Xvfb (Figures 4 to 6). In the RTL every output changes at the clock edge. At gate level, registered outputs change 0.45 to 0.6 ns after the edge because of the port load, which is why the checkers sample at the falling edge. `writeMem_val` also passes through a short intermediate value ("000+") while its bits settle, which is harmless but costs power. And `EN_readMem` follows `EN_blockRead` through one gate. `RDY_mult` is a flip-flop output and shows no glitch.

![400 MHz RTL, three cycles around the start of the drain.](../fig/wave_400_zoom_rtl.png){width=100%}

![400 MHz gate level with SDF, the same three cycles.](../fig/wave_400_zoom_gate.png){width=100%}

![800 MHz gate level with SDF, end of fill and start of drain.](../fig/wave_800_full_gate.png){width=100%}

# Area and power

Area is the sum of the Liberty cell areas of the final netlist. Flip-flops are 26 % of it at 400 MHz and 50 % at 800 MHz. The activity-based figures come from OpenSTA `read_vcd` on the zero-delay gate-level simulation of the full checker run and of its two 64-cycle windows.

| Power (µW) | 400 internal | 400 switching | 400 leakage | 400 total | 800 total |
|--------------|------:|------:|------:|------:|------:|
| Vectorless estimate | 433.9 | 162.9 | 36.6 | 633.4 | 2186.6 |
| Whole run | 433.7 | 174.5 | 36.5 | 644.7 | 2491.9 |
| Fill window | 876.5 | 684.2 | 38.9 | 1599.6 | 4530.0 |
| Drain window | 317.2 | 26.9 | 35.8 | 380.0 | 1945.6 |

In the fill window the multiplier switches every cycle. In the drain window the datapath is still, and what remains is mostly flip-flop clock power. Removing 135 flops at 800 MHz cut the drain-window power from 2536 to 1946 µW (−23 %), close to the 23 % reduction in flops. The zero-delay VCD that SPEC prescribes excludes glitch power.

# Optimisation techniques and measured effect

| Technique | Measured effect |
|------------------------------------------------|----------------------------------------|
| Kogge-Stone map and Resizer gate sizing (flow) | one-stage multiply −5.6 → −1.9 ns |
| Booth recoding before the first register | 400 MHz area −484 µm² at equal latency |
| Slow stacked cells, then MUX2, excluded from mapping | 800 MHz −0.61 → −0.44 ns, −0.034 → +0.051 ns |
| Correct ABC output load (1 fF flip-flop input) | 800 MHz −612 µm² |
| Port-only copies of the ready flags | needed: without them −0.054 ns at 800 MHz |
| Operand isolation | 400 MHz whole-run power 1402 → 643 µW, +49 µm² |
| 400 MHz: one cut at the 2-row cutset instead of after level 2 | −17 flops, sign-off −104 µm², −6.0 µW |
| 400 MHz: Wallace bit-level tree | −8 flops, sign-off +12.7 µm², −3.4 µW |
| 800 MHz: 3:2 inputs ordered by arrival, two levels per stage | carry-save ranks 117 + 76 + 60 → 92 + 60 flops |
| 800 MHz: carry-increment instead of carry-select adder | middle rank 64 → 43 flops |
| 800 MHz: split pointers, drain start from the valid bits | control 43 → 31 flops |
| 800 MHz total | 577 → 442 flops, sign-off −22 % area, −26 % power |
| Clock gating (rejected) | drain −51 to −73 %, vectorless +1 to +27 %, SDF fails |

# Tool flow and departures from the constraints

The flow uses open-source tools only and runs from `bash submission/scripts/install.sh` and `make <step> RUN=<400|800>`. The install script installs Icarus Verilog 12, GTKWave and Xvfb with apt and pulls two Docker images by digest: `openroad/orfs` for Yosys 0.68 and the OpenROAD Resizer, and `openroad/opensta` for OpenSTA 3.1.0. It also fetches the Nangate45 Liberty and Verilog cell models from a pinned commit of `mflowgen/freepdk-45nm` [2].

| Step | What it does |
|-----|----------------------------------------------------------------|
| `synth` | Yosys and ABC map every `.sv` file to Nangate45. The Resizer sizes and buffers the netlist, and OpenSTA reports timing, area and vectorless power and writes the SDF |
| `check` / `sim` | RTL / zero-delay gate-level simulation with the RTL checker (`sim` writes the VCD) |
| `timing` | SDF-annotated gate-level simulation with the gate-level checker |
| `power` | OpenSTA `read_vcd`, whole run and both windows |
| `timing_fail`, `f14` | failing-netlist demonstration and formal reset check |

The constraints of Section 6 are applied as written in `constraints.tcl`, with three interpretations. The input driver is DFF_X1/Q with a T/8 transition at that cell's clock input, and the clock also has a T/8 transition. The library's default wire-load model is used. The output load is four times the NAND2_X4 A1 capacitance, 23.54 fF. The remaining departures concern how the tools were used. Every reported figure is still evaluated at the target period under these constraints.

- The slowest corner available in a public source is `slow` (0.95 V, 125 °C).
- ABC maps with a Liberty copy that marks slow stacked cells and MUX2 `dont_use`, and with a 1 fF output load, at both frequencies. The Resizer places the netlist once to enable buffering and discards the placement.
- The simulation netlist declares an unused `parameter N` for the starter harness. The SDF typical values are set to the maximum, because Icarus annotates the typical value.
- Simulated power excludes glitches, and Icarus ignores timing checks (Section 3).

# Comparison with the GPDK045 sign-off service

SIGNOFF_SECTION

# Project metrics

The work took one Claude Code session on 8 November 2026. Rounds 1 and 2 (design, report) ran from 02:33 to 07:15 UTC. Round 3 (flip-flop minimisation) ran from about 07:50 UTC to the final build. Three subagents worked in parallel in each design round, with at most three flows running at a time. Token usage was counted from every session transcript under `~/.claude/projects/` by `submission/scripts/token_usage.py`. Each API response is counted once and priced at Anthropic's published API rates for Claude Opus 5.5 [17]: $4 per million input tokens, $20 per million output tokens, $0.20 per million cache reads, and 1.25 or 2 times the input rate for 5-minute or 1-hour cache writes. The count was taken just before the final build.

TOKEN_TABLE

# References

Every literature reference was checked against its bibliographic record before citing (`notes/REFERENCES_CHECK.md`).

1. ELEC 402 Project 2 specification (`SPEC.md`) and starter files, this repository.
2. C. Torng, `mflowgen/freepdk-45nm`, commit d3be42a72ca6, <https://github.com/mflowgen/freepdk-45nm>: `stdcells-wc.lib` (Nangate45 slow corner) and `stdcells.v`, from the NanGate 45 nm Open Cell Library and NCSU FreePDK45.
3. YosysHQ, Yosys 0.68, <https://github.com/YosysHQ/yosys>.
4. Berkeley Logic Synthesis and Verification Group, ABC, <https://github.com/berkeley-abc/abc>.
5. The OpenROAD Project, OpenROAD-flow-scripts, <https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts>, image `openroad/orfs` 26Q4-365-g898576f04 (BSD-3): the Resizer, Nangate45 LEF and `setRC.tcl`, and `abc_speed.script`, adapted.
6. Parallax Software, OpenSTA 3.1.0, <https://github.com/parallaxsw/OpenSTA>, image `openroad/opensta` f8e13cbf (GPL-3).
7. S. Williams, Icarus Verilog 12.0, <https://github.com/steveicarus/iverilog>.
8. GTKWave 3.3.116, <https://gtkwave.sourceforge.net>, and Graphviz, <https://graphviz.org>.
9. Cambridge Hackers, OSS CVC, <https://github.com/cambridgehackers/open-src-cvc>. Evaluated as a timing-check-aware simulator; building it was not permitted in the session.
10. O. L. MacSorley, "High-speed arithmetic in binary computers," *Proc. IRE*, vol. 49, no. 1, pp. 67–91, 1961.
11. C. S. Wallace, "A suggestion for a fast multiplier," *IEEE Trans. Electronic Computers*, vol. EC-13, no. 1, pp. 14–17, 1964. L. Dadda, "Some schemes for parallel multipliers," *Alta Frequenza*, vol. 34, pp. 349–356, 1965.
12. P. M. Kogge and H. S. Stone, "A parallel algorithm for the efficient solution of a general class of recurrence equations," *IEEE Trans. Computers*, vol. C-22, no. 8, pp. 786–793, 1973.
13. N. H. E. Weste and D. M. Harris, *CMOS VLSI Design*, 4th ed., Addison-Wesley, 2011, Ch. 11.
14. mflowgen, <https://github.com/mflowgen/mflowgen>.
15. Anthropic, Claude Code, used for this work.
16. GPDK045 sign-off scorecards, branch `check-results` of this repository.
17. Anthropic, Claude API pricing, as listed in the Claude API reference bundled with Claude Code (cached 6 October 2026), <https://www.anthropic.com/pricing>.
18. K. K. Parhi, *VLSI Digital Signal Processing Systems: Design and Implementation*, Wiley, 1999, Ch. 3, "Pipelining and Parallel Processing".
19. C. E. Leiserson and J. B. Saxe, "Retiming synchronous circuitry," *Algorithmica*, vol. 6, no. 1, pp. 5–35, 1991.
20. H. J. Touati and R. K. Brayton, "Computing the initial states of retimed circuits," *IEEE Trans. CAD*, vol. 12, no. 1, pp. 157–162, 1993.
21. W. J. Townsend, E. E. Swartzlander and J. A. Abraham, "A comparison of Dadda and Wallace multiplier delays," *Proc. SPIE*, vol. 5205, pp. 552–560, 2003.
22. D. Harris, "A taxonomy of parallel prefix networks," *Proc. 37th Asilomar Conf. Signals, Systems and Computers*, 2003, doi:10.1109/ACSSC.2003.1292373.
23. T. Han and D. A. Carlson, "Fast area-efficient VLSI adders," *Proc. 8th IEEE Symp. Computer Arithmetic*, pp. 49–56, 1987.
24. J. Sklansky, "Conditional-sum addition logic," *IRE Trans. Electronic Computers*, vol. EC-9, no. 2, pp. 226–231, 1960.
25. R. P. Brent and H. T. Kung, "A regular layout for parallel adders," *IEEE Trans. Computers*, vol. C-31, no. 3, pp. 260–264, 1982.

No complete implementation of this specification from another source was used. The RTL, checkers and scripts were written in this session.

\newpage

# Appendix: source listing

Every file of `submission/rtl_400/`, `submission/rtl_800/`, `submission/testbench/` and `submission/scripts/`, and the `Makefile`. Netlists and SDF files are in `submission/outputs/`.

LISTING
