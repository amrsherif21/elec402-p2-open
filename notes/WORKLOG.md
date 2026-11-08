# Work log: mkMultBuff (400 MHz and 800 MHz)

Entries are in chronological order on 2026-11-08 (UTC). An earlier draft of this log carried clock times on each entry that were estimates rather than readings, and they were wrong, so they were removed. The reliable times come from git and from file timestamps:
- session start 02:33
- checkpoints 1 and 2 committed 03:01, with check/400 pushed right after
- 800 MHz iterations 03:02–03:20 (`build/exp/*/sta.rpt`)
- checkpoint 3 committed 03:26, with check/800 pushed right after
- checkpoint 4 committed 03:27

Each entry gives what was done, why, the commands and the results. Tool logs that support reported numbers are kept under `submission/syn_reports/`.

## Checkpoint 1: toolchain

**Environment survey.** Ubuntu 24.04 x86-64, 4 cores, 15 GB RAM. Preinstalled: Icarus Verilog 12.0, Yosys 0.33 (apt), Verilator 5.020, GTKWave, Xvfb, pdflatex, pandoc. Docker CLI was present, but the daemon was not running; it was started with `dockerd &`. OpenSTA and OpenROAD are not in apt (`apt-cache policy opensta` gives no candidate).

**Nangate45 slow corner.** OpenROAD-flow-scripts ships only `NangateOpenCellLibrary_typical.lib`. The public mirror `mflowgen/freepdk-45nm`, at commit d3be42a7, holds `stdcells-wc.lib`. That file is the Nangate Open Cell Library's slow corner: `operating_conditions (slow)`, process 1.0, 0.95 V, 125 °C, default wire load `5K_hvratio_1_1`. The repository also has the typical and best-case libraries, so the worst-case file is the slowest corner available. Its `stdcells.v` is the Nangate Verilog cell library, with `specify` blocks, `$setuphold`/`$width` checks and notifier UDPs (250 specify blocks, 196 `$setuphold`). Both files are fetched by `submission/scripts/install.sh` and checked by sha256.

**OpenSTA / Yosys images.** Docker Hub has `openroad/opensta` (OpenSTA 3.1.0, f8e13cbf) and `openroad/orfs` (Yosys 0.68, OpenROAD). Both are pinned by digest in `install.sh` and in the `Makefile`. Yosys 0.68 was chosen over apt's 0.33 because it has `synth -booth` and the parallel-prefix `$lcu` maps (`+/choices/kogge-stone.v`). OpenROAD, from the same image, is used only for the Resizer (gate sizing).

**Does the simulator turn timing violations into X?** No. A test of `DFF_X1` with D changing 50 ps before CK (setup 100 ps), under `iverilog -gspecify`, captured the new value with no X (`/tmp/claude-0/probe/tc/t.v`). Icarus 12 parses `$setuphold` but does not evaluate it, so the notifier never toggles. OSS CVC, an open-source simulator that does evaluate timing checks, would have to be built from source, and building it was blocked by this session's permission policy (external code). Decision: use Icarus. Under SPEC 8.2's fallback, the gate-level checkers detect violations through incorrect values; Icarus does apply SDF IOPATH and INTERCONNECT delays, so a late D is captured stale. The report describes this limitation.

**install.sh.** It installs the apt packages, starts dockerd if needed, pulls both images by digest, fetches and checksums the library, and writes `submission/syn_reports/tool_versions.txt`. Run: `bash submission/scripts/install.sh` gave "install complete".

**Make targets.** `synth`, `check`, `sim`, `timing` and `power` take `RUN=400|800`; `timing_fail` and `all` are extra.

**SDF and Icarus.** Icarus annotates the *typ* entry of an SDF triple. This was checked on a single `BUF_X1` with `(0.1:0.5:0.9)`, which gave a 0.5 ns delay. OpenSTA's `-include_typ` writes typ as the mean of min and max, so `sdf_typmax.py` rewrites every triple as `(min:max:max)`, so the gate-level sims use the setup-pessimistic delays. Icarus also ignores the extra arguments of `$sdf_annotate` (such as "MAXIMUM") and warns about them.

## Checkpoint 2: 400 MHz

**Checkers delegated.** A subagent wrote `rtl_checker.sv`, `sdf_checker_400.sv` and `sdf_checker_800.sv` from SPEC.md, without access to `submission/rtl_*`. It smoke-tested them against its own throwaway behavioural model and 12 broken models; all were caught.
- *Reference model:* cycle-accurate, it learns the latency L from the first write, then checks every cycle for F1–F15, data and X/Z, and prints `ALL PASS` iff there are 0 failures.
- *Stimulus:* 14 fill/drain phases with densities from 10 to 100 %, the 5 directed pairs plus extra corners, junk EN_mult/EN_blockRead while not ready, and 4 resets (power-on, mid-fill, pipeline full, mid-drain).
- *Power windows:* a 64-cycle back-to-back fill and drain, announced as `PWR_WIN` lines.
- *Interpretations it recorded:* EN_readMem=0 outside accepted reads; outputs are not checked while RST_N=0; memVal_data is X-checked only while VALID.
- *Gate-level checkers:* 6 phases, inputs driven 20 ps after the rising edge, outputs sampled at the falling edge, and TIMING FAIL on any X or wrong memVal_data, or on missing products.

**First synthesis.** Yosys default (`synth`, `abc -D`) on the simple 2-stage RTL (operand register, then the whole multiply, then the product register): 1772 µm², but WNS −5.6 ns. The critical path was 8 ns: a ripple-like final adder, plus a DFF_X1 at fanout 29 with 0.99 ns clk→Q. At this corner (SS, 0.95 V, 125 °C, 5K wire load) a gate costs 0.1–0.5 ns.

**Flow improvements, measured on the same RTL.**
- *Parallel-prefix adder maps* (`-extra-map +/choices/{sklansky,kogge-stone}.v`) plus an ABC script with buffering and sizing, after ORFS `abc_speed.script` (BSD-3): WNS −3.8 to −4.1 ns.
- *OpenROAD Resizer without placement* (`repair_design`, `repair_timing`; wire-load parasitics; `setRC.tcl` from ORFS nangate45): −3.83 → −1.92 ns. Buffer insertion fails without placement (RSZ-0075), so only sizing and pin swapping take effect.
- *Conclusion:* a one-stage 16×16 multiply needs about 4.4 ns at this corner. 400 MHz needs the multiply split over two stages, and 800 MHz over about four.

**Own multiplier `mult_pipe.sv`.** It uses radix-4 modified Booth with 8 partial products. Sign extension is replaced by inverted sign bits plus the constant 0xAAAB0000, and each row's +1 sits in the free bit of the next row. Carry-save 3:2 levels go 9→6→4→3→2, then a final adder. Every pipeline cut is a parameter (PRE_ENC, ENC_REG, CSA_REG[3:0], CPA_SPLIT). Verified standalone against `a*b` over 200k random and corner pairs in several configurations (0 errors), and inside mkMultBuff with the independent RTL checker in 4 configurations (all ALL PASS).

**Sweep of the 400 MHz cut** (`build/exp/run.sh`; Yosys + Resizer + OpenSTA; area is post-Resizer):

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

**Full 400 MHz flow (`make synth|check|sim|timing|power RUN=400`).**
- *synth:* WNS +0.152 ns, hold WNS +0.053 ns, TNS 0, area 2386.6 µm² (sequential 753.8 µm²); vectorless power estimate 652.5 µW.
- *check:* ALL PASS, 14 phases, about 5900 cycles, latency 3.
- *sim (zero delay):* ALL PASS.
- *timing (SDF, typ=max):* ALL PASS, 384 products.
- *Netlist parameter:* the netlist has no parameter N, but the harness instantiates `mkMultBuff #(.N(N))`. The sim targets therefore use `build/<RUN>/netlist_sim.v`, which adds an unused `parameter N = 32`; the official netlist is unchanged.

**Netlists that must fail (`make timing_fail RUN=400|800`).**
- *400:* the variant with no carry-save register (`submission/testbench/timing_fail/rtl_onestage`), synthesized with the same flow at 2.5 ns, has WNS −1.469 ns. The checker printed `TIMING FAIL: 172 failure(s)`; the first was `memVal_data=87fc0013 expected 00000013`.
- *800:* the 400 MHz netlist, timed and back-annotated at 1.25 ns, has WNS −1.091 ns. The checker reports TIMING FAIL: the drain never starts, because the control path fails.
- *Logs:* `submission/syn_reports/{400,800}/timing_fail/`.

**Power (`make power RUN=400`).** OpenSTA `read_vcd -scope mkMultBuff_tb/DUT -begin_time/-end_time` on the zero-delay gate-level VCD:

| case | power µW |
|---|---|
| whole run | 642.8 |
| 64-cycle fill window | 1480.1 |
| 64-cycle drain window | 430.4 |
| vectorless estimate | 652.5 |

In the drain window the internal power of the 158 flip-flops' clock pins dominates. Operand isolation (zeros loaded when idle) keeps the datapath quiet.

**Mutation test of the RTL checker (`submission/scripts/mutate.sh 400`).** 11 one-line mutants of the real RTL, covering ready/valid off-by-ones, missing resets, ignored enables and wrong data source. All 11 were killed (`submission/syn_reports/400/mutation.log`).

**check/400 pushed** (`git push origin HEAD:refs/heads/check/400`, commit 60ed005). Work continued without waiting. Note: `rtl_800/` was still empty at that point, so the 800 part of that scorecard is expected to fail.

## Checkpoint 3: 800 MHz

**First 800 MHz probes** (`build/exp/run.sh`, mult_pipe configurations at 1.25 ns): WNS between −1.1 and −2.8 ns. The critical path was the `RST_N` input: one DFF_X1-modelled driver into 90 to 174 synchronous-reset gates, 1.4 to 2.6 ns. The Resizer cannot buffer it without placement (RSZ-0075 makeBufferedNet failed), and ABC's `buffer -p` changed nothing (the results were bit-identical).
- **Fix in resize.tcl:** a throw-away floorplan plus global placement, made only so the Resizer can insert buffers. Timing inside the Resizer stays on the wire-load model (no `estimate_parasitics`), so it is the same view as sign-off STA. Result at 800 MHz: −1.24 → −0.73 ns. At 400 MHz the result is identical (+0.152 ns, 2387 µm²).

**Parallel candidate evaluations (two subagents) while I iterated on the Booth/CSA candidate:**
- *(B) Behavioural `*` + R extra ranks + ABC retiming (`build/cand_retime/`):*
  - Best result: WNS −0.20 ns at R=8, about 6.1k µm². Retiming in ABC uses unit delays, so the result saturates near −0.2 ns.
  - Plain retiming breaks F14: 319 of 432 flops had no reset after retiming, and ABC even moved registers onto RST_N. Keeping F14 needs a non-standard strip/re-add-reset step.
  - Sign-off risk: the RTL alone is a one-stage multiplier followed by delay ranks, which GPDK045 sign-off would not retime. **Rejected.**
  - Its SAT-based F14 netlist check was adopted as `make f14`.
- *(C) Baugh-Wooley + Dadda, hand cut:* result pending at the time of writing; see below.
- *(A) Booth/CSA mult_pipe, my own:* iterations below.

**Booth/CSA iterations at 1.25 ns** (each fix found from the STA critical path; area is post-Resizer):

| step | change | WNS ns | area µm² |
|---|---|---|---|
| e800b | PRE_ENC, CS after L2 & L4, CPA split 16/16 | −1.136 | 3655 |
| g800b | + placement-backed buffering | −0.729 | 4182 |
| i800a | + SEL_REG (register after PP select), all 4 CSA levels registered, 2-stage carry-select adder | −0.610 | 5413 |
| k800a | + ABC maps with a Liberty copy in which slow stacked cells are `dont_use` (`lib_dont_use.py`; `abc -dont_use` did not reach ABC's SCL) | −0.440 | 5573 |
| m800b | carry-select adder rewritten with explicit in-block Kogge-Stone prefix computing both carry-in sums at once (Yosys had built `x+y+1` as two chained adders); 4-bit blocks | −0.159 | 5853 |
| n800b | separate write and read pointers (the shared pointer drove 2 ports, 47 fF) | −0.090 | 5965 |
| r800b | port-only copies of RDY_*, addresses and EN_writeMem, stored inverted so Yosys does not merge them with the internal copies (`(* keep *)` did not prevent merging) | −0.014 | 5786 |
| t800b | block-carry prefix in stage B instead of a ripple | −0.034 | 5933 |
| u800b | MUX2 also dont_use (MUX2_X1 0.24 ns) | +0.051 | 5893 |
| v800b | GP4: L4 register holds generate/propagate of the final rows, moving the adder's first gate level into the L4 stage (0.36 ns slack there) | +0.136 | 5824 |
| x800 | ABC output load 23.5 → 1 fF: ABC sees every flop D pin as a primary output and had buffered each as if it drove the 23.5 fF port load | +0.150 | 5211 |
| x800_1010 | CS registers only after L2 and L4 (473 flops instead of 577+) | −0.004 | 4431 |
| y800_a | same, GP4 = 0 | +0.023 | 4465 |
| z800_1011 | CS after L1, L2, L4 | −0.004 | 4973 |
| **z800_1101** | **CS after L1, L3, L4 (L2+L3 share a stage: L3 is a single 3:2 on 3 of 4 rows)** | **+0.075** | **4755** |

ABC results vary by about ±0.1–0.2 ns with small netlist-structure changes. For example, the 400 MHz RTL with the newer mult_pipe.sv (logically identical for its parameters) maps to −0.037 ns instead of +0.152 ns, so rtl_400 keeps its verified mult_pipe.sv. Each final configuration is deterministic, and the knobs are fixed per RUN in the Makefile (ABC_DRIVER, ABC_LOAD, DONT_USE).

**rtl_800 = z800_1101** (latency 7, 577 flops; config in `submission/rtl_800/mkMultBuff.sv`). It meets the 62 ps target at the lowest area of the passing variants. The 1111 variant has more slack (+0.150 ns) but costs +456 µm² and about +0.34 mW of vectorless power.

| step | result |
|---|---|
| `make check RUN=800` | ALL PASS, latency 7 |
| `make synth RUN=800` | WNS +0.075 ns, hold +0.041 ns, 4755.0 µm², vectorless 2727.6 µW |
| `make sim RUN=800` | ALL PASS |
| `make timing RUN=800` | ALL PASS, 384 products |
| `make power RUN=800` | run 3073 µW, fill window 5210 µW, drain window 2536 µW |
| `make f14 RUN=400` | 166/166 flops reset-gated (SAT) |
| `make f14 RUN=800` | 577/577 flops reset-gated (SAT) |

`make synth RUN=400` with the final scripts and the 400 knobs reproduces the committed netlist exactly: +0.152 ns, 2386.552 µm², and `git status` shows the netlist and SDF unchanged.

**Candidate (C), Baugh-Wooley + Dadda (subagent, `build/cand_dadda/`).**
- *Best version (v6):* WNS +0.150 ns, hold +0.076 ns, 5278 µm², 616 flops, latency 8, check/sim ALL PASS.
- *Power (µW):*

  | case | (C) Dadda v6 | (A) Booth/CSA |
  |---|---|---|
  | whole run | 3279 | 3073 |
  | fill window | 5725 | 5210 |
  | drain window | 2702 | 2536 |
  | vectorless | 2820 | 2728 |

- *Control:* it independently found the same control problem (ptr/RDY port load) and solved it with inverted twin registers and split 3-bit counters.
- *Two smaller variants it rejected:* v7 drops the product register (writeMem_val comes from logic); v8 puts the PP/tree logic on the input path (0.97 ns), which is risky for the sign-off testbench.

**Decision for 800 MHz: (A) Booth/CSA `z800_1101`.**
- Both (A) and (C) meet the 62 ps target. (A) has 10 % less area (4755 vs 5278 µm²) and 6–9 % less power in every case, which SPEC Section 5 ranks after timing and area.
- (C) has twice the slack margin (150 ps vs 75 ps), but the target is met by both.
- (B), retiming, fails timing (−0.20 ns) and needs reset re-insertion; rejected.

**Mutation test at 800 MHz** (`submission/scripts/mutate.sh 800`): 13/13 mutants killed. The extra mutants vs 400 are EN_writeMem one cycle early, the inverted port copy not reset, and a carry-select carry-in error in mult_pipe.

**Waveform figures** (`submission/scripts/waves/waves.sh 400|800`). The same gate-level checker drives the RTL and the SDF-annotated netlist, so the waves line up. GTKWave 3.3.116 runs under `xvfb-run` with `-S` Tcl scripts (`/File/Grab_To_File`), light colours set by `--rcvar`, and ImageMagick crops. Windows: first writes, transition to drain, end of drain, and a 3-cycle zoom.

Gate-level only effects visible in the zoom:
- clock-to-output delay of 0.45–0.7 ns on the registered outputs at 400 MHz;
- a short intermediate value on writeMem_val while bits with different clk→Q settle;
- EN_readMem following EN_blockRead (driven 20 ps after the edge) through one AND gate.

RDY_mult is a register output in both designs, so it shows no glitch.

## Checkpoint 4: power

Activity-based power uses OpenSTA `read_vcd` on the zero-delay gate-level VCD of `make sim`, which runs the full RTL-checker stimulus. It is reported for the whole run and for the two 64-cycle windows announced by the checker (`PWR_WIN`, passed as `-begin_time/-end_time`). The vectorless "synthesis estimate" is `report_power` with OpenSTA's default input activity of 0.1. Reports: `submission/syn_reports/<RUN>/{sta.rpt,power.rpt,power_summary.txt}`.

Power in µW, slow corner (0.95 V, 125 °C):

| case | 400 MHz | 800 MHz |
|---|---|---|
| vectorless estimate | 652.5 | 2727.6 |
| whole run | 642.8 | 3073.1 |
| fill window (64 back-to-back accepts) | 1480.1 | 5209.5 |
| drain window (64 back-to-back reads, producer idle) | 430.4 | 2535.6 |

In the drain window, sequential internal (clock) power dominates: 158 flops at 400 MHz and 577 at 800 MHz, with no clock gating.

**Operand-isolation experiment** (400 MHz, `build/noiso400`; operand registers load the inputs every cycle instead of zeros when nothing is accepted). Files: `submission/syn_reports/400/experiments/`.
- Area: 2337.9 µm², against 2386.6 µm² with isolation.
- Power: whole run 1402.0 µW (+118 %), fill window 1471.1 µW, drain window 428.6 µW. The windows hardly change because the checker keeps the producer quiet in the drain window. Over the whole run, the random operands presented while not ready (F5/F11 stimulus) toggle the multiplier without isolation.
- Vectorless estimate: 755.9 µW.
- Isolation costs about 49 µm² of gating and removes about 54 % of the whole-run power.

Glitch power is not included, because the VCD is from the zero-delay simulation that SPEC Section 7 prescribes for `sim`. This is noted in the report.

## Checkpoint 5: report

**Report** (`submission/pdf_report/report.pdf`). Built by `bash submission/scripts/build_report.sh`: pandoc 3.1.3 + pdflatex from `submission/pdf_report/src/report.md`. The script fills four placeholders:
- the sign-off section, from `src/signoff.md`;
- the token table, from `submission/scripts/token_usage.py`;
- the end time;
- the full source listing appendix.

Figures: Graphviz state and datapath diagrams (`src/*.dot`) and the GTKWave captures. The report is marked AI-generated on its first page, with author Claude Opus 5.5 (Anthropic).

**Token usage** (`submission/scripts/token_usage.py`). It reads every transcript under `~/.claude/projects/-home-user-elec402-p2-open/`: the main session and the 3 subagents. Each API response is counted once (deduplicated by message id and request id), and costs use Anthropic API prices for Claude Opus 5.5:
- $4 / $20 per MTok input / output;
- cache reads $0.20;
- cache writes 1.25× input (5 min) or 2× input (1 h).

At the first measurement (03:40) the total was 279 responses and $24.72. The final numbers are in the report.

**Sign-off service.** `check/400` (60ed005) and `check/800` (b6917e9) were pushed at about 03:02 and 03:27. Repeated `git fetch origin check-results` returned "couldn't find remote ref", and `git ls-remote` shows no such branch, so no scorecard was available while the report was being built. The report states this and lists the differences to expect.

**Fresh-clone rerun.** The script is in the scratchpad (`fresh.sh`). It clones the pushed branch, runs `install.sh`, `make synth check sim timing power f14` for both RUNs, `make timing_fail` for both, and the mutation tests, then reports `git status` and diffs the netlists against the committed ones. The result is recorded below.

**Fresh-clone rerun result** (`submission/scripts/fresh_clone_rerun.sh`, log `submission/syn_reports/fresh_clone_rerun.log`).
- *Run:* the clone of 8f205c3 ran from 03:34:16 to 03:36:14, with install.sh and the Docker images already cached.
- *Both RUNs reproduce the committed results exactly:*
  - 400 MHz: +0.152 ns, 2386.552 µm², power 652.53 / 642.80 / 1480.10 / 430.37 µW;
  - 800 MHz: +0.075 ns, 4755.016 µm², 2727.60 / 3073.10 / 5209.50 / 2535.60 µW;
  - check, sim and timing all ALL PASS; F14 166/166 and 577/577; timing_fail TIMING FAIL for both; mutants 11/11 and 13/13.
- *`git status` after the run:* only logs changed (synth.log, resize.log and the tool_versions.txt date). Netlists, SDF and reports are byte-identical.

## Report revision after sign-off (07:00–07:15 UTC)

**Sign-off scorecards** (`git fetch origin check-results`, `results/check_{400-60ed005585,800-b6917e9eb1}/scorecard.md`).
- *Correction:* the user reports that the service was online throughout the session. It did not trigger because the session environment had not been set up for it. The report's earlier wording ("probably offline") was wrong and has been corrected.
- *Checked:* both commits at 06:37 / 06:48 UTC, after the environment fix.
- *GPDK045 results:*

  | | 400 MHz | 800 MHz |
  |---|---|---|
  | WNS (target) | 156 ps (125) | 148 ps (62) |
  | Area | 2752.1 µm² | 5674.5 µm² |
  | Vectorless power | 224.6 µW | 1121.9 µW |
  | SDF simulation | pass, 1204/1204 products, 0 timing-check messages | pass, 1249/1249 products |

  Informational check: the 400 MHz netlist at 1.25 ns fails, with 0 products, 4058 timing-check messages, and F1 F4 F5 F6 F8 F9 STALL violated. This matches our own `make timing_fail RUN=800` (same netlist, same period, no product returned).
- *Comparison with the open-source results:*
  - functional results agree;
  - GPDK045 area is 15–19 % larger;
  - GPDK045 vectorless power is 2.4–2.9× lower (different library, voltage and default activity);
  - the 800 MHz design draws 4.2× the power of the 400 MHz design in our flow and 5.0× in GPDK045;
  - 400 MHz slack is nearly equal in both flows; at 800 MHz GPDK045 has 2× the margin (corner not stated; commercial tools spend slack on area recovery).

**Report rewritten for concision.** The user asked for a results summary first, then design decisions, at about half the length. Main-text prose went from 5,650 to 2,728 words (3,805 with tables), and all ten SPEC Section 9 items are kept. Section order:
1. summary;
2. design decisions (control, arithmetic, 400 MHz, 800 MHz with change table and candidates);
3. verification;
4. area/power;
5. optimisation;
6. tool flow and departures;
7. GPDK045 comparison;
8. metrics;
9. references, with the appendix after them.

RTL untouched.

**Build fixes.**
- The first rebuild failed silently. LaTeX could not render "≈" (U+2248), and `| tail -1` hid the error, so the old PDF stayed in place. "≈" and "…" are now declared in the header.
- `token_usage.py` now labels subagents by their task description from `*.meta.json` and states the model once.

## Round 3: minimum flops (RTL optimisation)

**Merge** of `origin/main` (e1b93d2), which changed SPEC Section 5 and CLAUDE Section 4:
- the 5 % slack target must also hold in sign-off, and slack beyond it is worth nothing;
- area and power are judged on the GPDK045 sign-off results (vectorless power);
- candidates may be submitted to sign-off (about 3 min each, one at a time).

Consequence: the cost to minimise is flops and cells in the RTL itself. Sign-off synthesises the RTL with its own tool, so our ABC/Resizer knobs only matter for meeting slack in our flow.

**Tooling.**
- `submission/scripts/eval_candidate.sh RUN RTL_DIR WORK` runs check, synth, sim and power on one candidate and prints slack, area seq/comb, flops, vectorless and activity power, and flops and slack per register group (`submission/scripts/ranks.tcl`). One run takes about 35 s.
- Baseline 800 MHz per group:

  | group | flops | slack |
  |---|---:|---:|
  | operand + digits | 40 | |
  | PP | 144 | 0.166 |
  | L1 | 117 | 0.368 |
  | L2+3 | 76 | 0.075 |
  | g/p | ≈60 | |
  | csel A | ≈64 | |
  | product | 32 | 0.079 |
  | control | ≈44 | |

**400 MHz experiments (mine)**, `build/cand400/`. 800 MHz mapping knobs (BUF_X1 driver, 1 fF load, dont-use list) unless noted.

| candidate | ranks | flops | WNS ns | area (seq/comb) µm² | vectorless µW | activity run/fill/drain µW |
|---|---|---:|---:|---|---:|---|
| current (Booth digits, CS after L2, product) | 3 | 166 | +0.224 | 2547 (751/1797) | 664.5 | 677/1566/434 |
| digits, CS after L4 (2 rows, 59 b), product **(p1c4)** | 3 | 149 | +0.207 | 2518 (674/1844) | 663.2 | 659/1607/398 |
| raw operands (recode after reg), CS after L4 (p0c4) | 3 | 141 | +0.110 (+0.073/+0.083 with other knobs) | 3165 (638/2528) | 746.9 | 765/2084/394 |
| p1c4 / p0c4 with the old 400 knobs | 3 | 149 / 141 | −0.035 / −0.269 | 2341 / 3550 | | |
| 2 ranks: no operand register, CS after L2 (r2c0100) | 2 | 125 | −0.314 | 2737 (566/2171) | 800.0 | 882/1629/349 |
| 2 ranks: no operand register, CS after L3 | 2 | 139 | −1.100 | 2844 | | |

Notes on these results:
- 2 ranks with operands and product only is the one-stage multiplier: −1.469 ns (see the timing_fail variant).
- The 2-rank designs with logic before the first register fail because the input port, modelled as a DFF_X1 driver, drives 37 loads (0.83 ns) and the product stage also misses (−0.155 ns).
- Decision for 400: **p1c4**. The only internal cut is at the narrowest cutset that meets the target (2 carry-save rows, 59 bits), saving 17 flops. Recoding after the register would save another 8 but misses 125 ps in our flow. The 400 knobs in the Makefile change to the 800 knobs.

**Parallel workers (subagents), one flow each:**
- (a) 800 MHz cut placement and final-adder comparison on the row tree;
- (b) 800 MHz bit-level Dadda/Wallace tree on the Booth PPs, plus 400;
- (c) clock-gating feasibility on p1c4.

**References** were checked before citing (`notes/REFERENCES_CHECK.md`). Harris's taxonomy page range could not be confirmed, so it is cited without pages.

**Clock gating (worker c, `build/cg/`): rejected.**
- *Implementation:* a technology-independent latch-plus-AND gate in RTL. The enable includes `!RST_N`, so F14 still holds: the SAT check passes 149/149, and a separate SAT proof shows the latch input is 1 during reset. Yosys does not map latches with `dfflibmap`, so an extra mapping to DLL_X1 was needed.
- *Results on p1c4, 400 MHz:*

  | | baseline | gated |
  |---|---|---|
  | drain window | 398 µW | 109–196 µW |
  | whole run | 659 µW | 503–534 µW |
  | vectorless estimate (the judged metric) | 663 µW | 671–842 µW |
  | SDF check without a clock tree | pass | fails 384/384 |

- *Why the vectorless estimate rises:* the gated clock net is charged but the port-driven clock is not, and default activities keep the enable mostly on.
- *Why the SDF check fails:* the gating gate reaches the flops 1.4–2.0 ns after clk. That skew is invisible to ideal-clock STA, so every product is wrong in SDF simulation.
- *What it would take:* a clock tree (TritonCTS), propagated clocks and hold buffers (variant d3, operand register ungated). Sign-off builds no clock tree, so it would see the failing case.
- *800 MHz:* the same and worse; a tree delay of 0.35–0.5 ns is 30–40 % of the period.
- *Decision:* no clock gating. The only gain is activity-based, the judged metric gets worse, and sign-off SDF is at risk.

**Sign-off of the 400 MHz candidate p1c4** (`check/c400-p1c4`, 0fbf037, checked 08:19 UTC). Against the previous design:

| | previous | p1c4 |
|---|---|---|
| WNS | 156 ps | 441 ps |
| area | 2752.1 µm² | **2648.1 µm² (−3.8 %)** |
| vectorless power | 224.6 µW | **218.6 µW (−2.7 %)** |
| SDF simulation | | pass, 1204/1204 |

**800 MHz cut + adder worker (a), `build/cand800a/`**, 19 runs.

| | baseline | e18 |
|---|---|---|
| ranks | 7 | 6 |
| flops | 577 | **442** |
| flops per rank | | R1 40 / PP 144 / after L2 92 / after L4 60 / adder middle 43 / product 32 / control 31 |
| WNS | +0.075 ns | +0.129 ns |
| area (seq/comb) | | 4022 µm² (2001/2022) |
| vectorless power | | 2189 µW |
| activity run / fill / drain | | 2493 / 4535 / 1946 µW |

What each change did:
- *Cuts:* the L1 rank (117 bits) is dropped. That became possible once each 3:2 adds its latest-arriving input last, `(x^y)^z`.
- *Adder:* the carry-select adder is replaced by a two-stage carry-increment adder with 4-bit blocks. The middle rank holds the block sums for carry-in 0 plus carry-outs for carry-in 0 and 1: 43 flops instead of about 59.
- *Single-stage adders:* none fits. Han-Carlson −0.164, Sklansky −0.176, Kogge-Stone −0.177, Brent-Kung −0.324, Yosys `+` −0.674 ns.
- *Control:* 43 → 31 flops. Split 3+3-bit pointers and a drain-start condition taken from the valid register replace the 12 address/EN_writeMem port copies. Both ready-flag copies are still needed.
- *What did not work:* PRE_ENC=0 saves 8 flops but adds 534 µm² of comb. The 144-bit PP rank cannot be avoided, because select + L1 is about 0.9 ns against a 0.715 ns budget. Five ranks would need 3.73 ns of logic.

e18 passes SDF timing sim (384/384) and F14 (442/442). It was submitted to sign-off as `check/c800-e18` (89c8d99, with rtl_400 = p1c4).

**Bit-level tree worker (b), `build/cand800b/`.** The generator `gen_tree.py`, now `submission/scripts/gen_tree.py`, emits a drop-in mult_pipe with Booth PPs and a Dadda or Wallace bit-level tree.

*Booth matrix (144 bits, height 9, 4 levels):*

| tree | FA/HA | cutsets after L1/L2/L3/L4 |
|---|---|---|
| Dadda | 91/22 | 132/104/84/60 |
| Wallace | 92/55 | 112/86/69/59 |
| Wallace, no HA on short columns | 100/20 | 112/84/65/52 |

Wallace reduces bits earlier, so its mid-tree cutsets are narrower, which is what pipelining needs.

*Best results in our flow:*
- 800 MHz, w24r3gt5re: 6 ranks, 431 flops, +0.096 ns, 3951 µm², vectorless 2155 µW.
- 400 MHz, w4r3cpa: 3 ranks, 141 flops, +0.151 ns.
- 800 MHz combined with e18's control (build/cand800c/combo): 420 flops, +0.085 ns.

**Sign-off of the candidates** (all meet timing, all pass SDF simulation):

| check | 400 area / power / WNS | 800 area / power / WNS |
|---|---|---|
| previous designs | 2752.1 / 224.6 / 156 | 5674.5 / 1121.9 / 148 |
| c400-p1c4 | 2648.1 / 218.6 / 441 | (old 800) |
| c800-e18 | (p1c4) | **4416.2 / 829.7 / 158** |
| c-wallace (w4r3cpa + w24r3gt5re) | **2660.8 / 215.2 / 203** | 4192.6 / 922.4 / 91 |
| c-combo (w4r3cpa + Wallace tree, e18 control) | 2660.8 / 215.2 / 203 | 4192.9 / 929.8 / 90 |

Units: area µm², power µW, WNS ps.

**Decision.** Area and power disagree, so I took the sum of the relative changes in area and power:
- 800 MHz: Wallace is −5.1 % area but +11.2 % power against e18, so **e18** wins.
- 400 MHz: Wallace is +0.5 % area and −1.6 % power against p1c4, so **w4r3cpa** wins, with 8 fewer flops.

The Wallace 800 MHz design probably loses on vectorless power because its bit-level XOR network is larger: 100 FA + 26 HA against e18's row tree, and vectorless analysis charges every cell at default activity. The control simplification (−11 flops) did not change the sign-off area at all (the commercial flow probably merges the duplicates itself).

**Final RTL.**
- *rtl_400:* w4r3cpa, regenerated from `submission/scripts/gen_tree.py --mode wallace --rawlevels 3 --nosel --cuts 4 --gp cpa --cpa one --res-budget 1.9` (identical body); top unchanged except the header.
- *rtl_800:* e18's parameterised mult_pipe (header documents the new options) under a cleaned top with only the chosen control (31 flops, same function as e18).
- *Makefile:* the 400 knobs become the 800 knobs.
- *Mutation test:* new 800 MHz mutant set, 13/13 killed; 400 still 11/11.

**Full flow on the final designs:**

| | 400 MHz | 800 MHz |
|---|---|---|
| WNS | +0.263 ns | +0.140 ns |
| area (seq) | 2449.6 µm² (637.6) | 4017.9 µm² (2000.9) |
| flops | 141 | 442 |
| vectorless | 633.4 µW | 2186.6 µW |
| run / fill / drain | 644.7 / 1599.6 / 380.0 µW | 2491.9 / 4530.0 / 1945.6 µW |
| check / sim / timing | ALL PASS | ALL PASS |
| F14 | 141/141 | 442/442 |
| timing_fail | TIMING FAIL (−0.675 ns) | TIMING FAIL (−0.951 ns) |

Waveforms were regenerated.

**Final sign-off** (`check/final`, efbfecd, checked 09:06 UTC). Results are identical to the candidate checks.

| | area | vectorless power | WNS | SDF simulation |
|---|---|---|---|---|
| 400 MHz | 2660.8 µm² | 215.2 µW | 203 ps | 1204/1204 |
| 800 MHz | 4416.2 µm² | 829.7 µW | 158 ps | 1162/1162 |

The informational check (the 400 MHz netlist at 1.25 ns) fails, as it should.

Against the previous designs this is −3.3 % area and −4.2 % power at 400 MHz, and −22.2 % area and −26.0 % power at 800 MHz.

**Report** rewritten for round 3 at the same length. New sections:
- the cost model (cutset width, retiming and initial states);
- the 400 MHz rank analysis and Wallace cutsets;
- the 800 MHz rank and adder decisions;
- a candidate table with the sign-off decision;
- clock gating;
- new datapath figures.

New references (Parhi, Leiserson-Saxe, Touati-Brayton, Townsend et al., Harris, Han-Carlson, Sklansky, Brent-Kung) were checked first (`notes/REFERENCES_CHECK.md`).
