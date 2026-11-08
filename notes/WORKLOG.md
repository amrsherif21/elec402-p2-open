# Work log: mkMultBuff (400 MHz and 800 MHz)

Times are UTC on 2026-11-08. Each entry gives what was done, why, the commands and the results. Tool logs that support reported numbers are kept under `submission/syn_reports/`.

## Checkpoint 1: toolchain

**02:30 Environment survey.** Ubuntu 24.04 x86-64, 4 cores, 15 GB RAM. Preinstalled: Icarus Verilog 12.0, Yosys 0.33 (apt), Verilator 5.020, GTKWave, Xvfb, pdflatex, pandoc. Docker CLI was present, but the daemon was not running; it was started with `dockerd &`. OpenSTA and OpenROAD are not in apt (`apt-cache policy opensta` gives no candidate).

**02:34 Nangate45 slow corner.** OpenROAD-flow-scripts ships only `NangateOpenCellLibrary_typical.lib`. The public mirror `mflowgen/freepdk-45nm`, at commit d3be42a7, holds `stdcells-wc.lib`. That file is the Nangate Open Cell Library's slow corner: `operating_conditions (slow)`, process 1.0, 0.95 V, 125 °C, default wire load `5K_hvratio_1_1`. The repository also has the typical and best-case libraries, so the worst-case file is the slowest corner available. Its `stdcells.v` is the Nangate Verilog cell library, with `specify` blocks, `$setuphold`/`$width` checks and notifier UDPs (250 specify blocks, 196 `$setuphold`). Both files are fetched by `submission/scripts/install.sh` and checked by sha256.

**02:36 OpenSTA / Yosys images.** Docker Hub has `openroad/opensta` (OpenSTA 3.1.0, f8e13cbf) and `openroad/orfs` (Yosys 0.68, OpenROAD). Both are pinned by digest in `install.sh` and in the `Makefile`. Yosys 0.68 was chosen over apt's 0.33 because it has `synth -booth` and the parallel-prefix `$lcu` maps (`+/choices/kogge-stone.v`). OpenROAD, from the same image, is used only for the Resizer (gate sizing).

**02:38 Does the simulator turn timing violations into X?** No. A test of `DFF_X1` with D changing 50 ps before CK (setup 100 ps), under `iverilog -gspecify`, captured the new value with no X (`/tmp/claude-0/probe/tc/t.v`). Icarus 12 parses `$setuphold` but does not evaluate it, so the notifier never toggles. OSS CVC, an open-source simulator that does evaluate timing checks, would have to be built from source, and building it was blocked by this session's permission policy (external code). Decision: use Icarus. Under SPEC 8.2's fallback, the gate-level checkers detect violations through incorrect values; Icarus does apply SDF IOPATH and INTERCONNECT delays, so a late D is captured stale. The report describes this limitation.

**02:40 install.sh.** It installs the apt packages, starts dockerd if needed, pulls both images by digest, fetches and checksums the library, and writes `submission/syn_reports/tool_versions.txt`. Run: `bash submission/scripts/install.sh` gave "install complete".

**Make targets.** `synth`, `check`, `sim`, `timing` and `power` take `RUN=400|800`; `timing_fail` and `all` are extra.

**SDF and Icarus.** Icarus annotates the *typ* entry of an SDF triple. This was checked on a single `BUF_X1` with `(0.1:0.5:0.9)`, which gave a 0.5 ns delay. OpenSTA's `-include_typ` writes typ as the mean of min and max, so `sdf_typmax.py` rewrites every triple as `(min:max:max)`, so the gate-level sims use the setup-pessimistic delays. Icarus also ignores the extra arguments of `$sdf_annotate` (such as "MAXIMUM") and warns about them.

## Checkpoint 2: 400 MHz

**02:42 Checkers delegated.** A subagent wrote `rtl_checker.sv`, `sdf_checker_400.sv` and `sdf_checker_800.sv` from SPEC.md, without access to `submission/rtl_*`. It smoke-tested them against its own throwaway behavioural model and 12 broken models; all were caught.
- *Reference model:* cycle-accurate, it learns the latency L from the first write, then checks every cycle for F1–F15, data and X/Z, and prints `ALL PASS` iff there are 0 failures.
- *Stimulus:* 14 fill/drain phases with densities from 10 to 100 %, the 5 directed pairs plus extra corners, junk EN_mult/EN_blockRead while not ready, and 4 resets (power-on, mid-fill, pipeline full, mid-drain).
- *Power windows:* a 64-cycle back-to-back fill and drain, announced as `PWR_WIN` lines.
- *Interpretations it recorded:* EN_readMem=0 outside accepted reads; outputs are not checked while RST_N=0; memVal_data is X-checked only while VALID.
- *Gate-level checkers:* 6 phases, inputs driven 20 ps after the rising edge, outputs sampled at the falling edge, and TIMING FAIL on any X or wrong memVal_data, or on missing products.

**02:45 First synthesis.** Yosys default (`synth`, `abc -D`) on the simple 2-stage RTL (operand register, then the whole multiply, then the product register): 1772 µm², but WNS −5.6 ns. The critical path was 8 ns: a ripple-like final adder, plus a DFF_X1 at fanout 29 with 0.99 ns clk→Q. At this corner (SS, 0.95 V, 125 °C, 5K wire load) a gate costs 0.1–0.5 ns.

**02:50 Flow improvements, measured on the same RTL.**
- *Parallel-prefix adder maps* (`-extra-map +/choices/{sklansky,kogge-stone}.v`) plus an ABC script with buffering and sizing, after ORFS `abc_speed.script` (BSD-3): WNS −3.8 to −4.1 ns.
- *OpenROAD Resizer without placement* (`repair_design`, `repair_timing`; wire-load parasitics; `setRC.tcl` from ORFS nangate45): −3.83 → −1.92 ns. Buffer insertion fails without placement (RSZ-0075), so only sizing and pin swapping take effect.
- *Conclusion:* a one-stage 16×16 multiply needs about 4.4 ns at this corner. 400 MHz needs the multiply split over two stages, and 800 MHz over about four.

**03:00 Own multiplier `mult_pipe.sv`.** It uses radix-4 modified Booth with 8 partial products. Sign extension is replaced by inverted sign bits plus the constant 0xAAAB0000, and each row's +1 sits in the free bit of the next row. Carry-save 3:2 levels go 9→6→4→3→2, then a final adder. Every pipeline cut is a parameter (PRE_ENC, ENC_REG, CSA_REG[3:0], CPA_SPLIT). Verified standalone against `a*b` over 200k random and corner pairs in several configurations (0 errors), and inside mkMultBuff with the independent RTL checker in 4 configurations (all ALL PASS).

**03:05 Sweep of the 400 MHz cut** (`build/exp/run.sh`; Yosys + Resizer + OpenSTA; area is post-Resizer):

| config | latency | area µm² | WNS ns |
|---|---|---|---|
| operand reg, CS reg after L4 (CSA_REG=1000) | 3 | 3146 | −0.202 |
| + Booth-encoded rank (ENC_REG) | 4 | 2820 | +0.001 |
| CS reg after L2 | 3 | 2871 | +0.004 |
| CS reg after L3 | 3 | 2903 | −0.170 |
| Booth recoding before the operand reg (PRE_ENC), CS after L4, sklansky | 3 | 2311 | −0.354 |
| PRE_ENC, CS after L4, kogge-stone | 3 | 2347 | +0.045 |
| **PRE_ENC, CS after L2, kogge-stone** | **3** | **2387** | **+0.152** |
| PRE_ENC, CS after L2/L4, Resizer margin 0.3 | 3 | same | no change (sizing saturates) |

- *PRE_ENC:* recoding the multiplier (one/two/neg, 24 bits) before the operand register saved about 500 µm². The recoding logic is small, and it removes the recoder from the multiply stage and the fan-out of the b bits.
- *Adders:* Kogge-Stone was consistently better than Sklansky and Han-Carlson for the final adder. ABC's `-D` has no effect with this script.
- *Choice:* PRE_ENC, CS register after L2, Kogge-Stone, Resizer setup margin 0.15 ns. This is the only configuration that meets the 125 ps target.

**03:15 Full 400 MHz flow (`make synth|check|sim|timing|power RUN=400`).**
- *synth:* WNS +0.152 ns, hold WNS +0.053 ns, TNS 0, area 2386.6 µm² (sequential 753.8 µm²); vectorless power estimate 652.5 µW.
- *check:* ALL PASS, 14 phases, about 5900 cycles, latency 3.
- *sim (zero delay):* ALL PASS.
- *timing (SDF, typ=max):* ALL PASS, 384 products.
- *Netlist parameter:* the netlist has no parameter N, but the harness instantiates `mkMultBuff #(.N(N))`. The sim targets therefore use `build/<RUN>/netlist_sim.v`, which adds an unused `parameter N = 32`; the official netlist is unchanged.

**03:20 Netlists that must fail (`make timing_fail RUN=400|800`).**
- *400:* the variant with no carry-save register (`submission/testbench/timing_fail/rtl_onestage`), synthesized with the same flow at 2.5 ns, has WNS −1.469 ns. The checker printed `TIMING FAIL: 172 failure(s)`; the first was `memVal_data=87fc0013 expected 00000013`.
- *800:* the 400 MHz netlist, timed and back-annotated at 1.25 ns, has WNS −1.091 ns. The checker reports TIMING FAIL: the drain never starts, because the control path fails.
- *Logs:* `submission/syn_reports/{400,800}/timing_fail/`.

**03:25 Power (`make power RUN=400`).** OpenSTA `read_vcd -scope mkMultBuff_tb/DUT -begin_time/-end_time` on the zero-delay gate-level VCD:

| case | power µW |
|---|---|
| whole run | 642.8 |
| 64-cycle fill window | 1480.1 |
| 64-cycle drain window | 430.4 |
| vectorless estimate | 652.5 |

In the drain window the internal power of the 158 flip-flops' clock pins dominates. Operand isolation (zeros loaded when idle) keeps the datapath quiet.

**03:28 Mutation test of the RTL checker (`submission/scripts/mutate.sh 400`).** 11 one-line mutants of the real RTL, covering ready/valid off-by-ones, missing resets, ignored enables and wrong data source. All 11 were killed (`submission/syn_reports/400/mutation.log`).
