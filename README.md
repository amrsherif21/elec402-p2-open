# mkMultBuff

Amr Sherif, 91007526

Design of a pipelined signed 16 x 16 multiplier with a 64-entry fill/drain buffer, implemented at 400 MHz and 800 MHz with open-source tools. The design, verification, flow scripts and report were produced by Claude Code (Opus 5.5 - medium) working from a specification file `SPEC.md` that I prepared. I also set up a GPDK045 "check service" to allow the agent to synthesize and simulate its designs with GPDK045, without the PDK files leaving the ECE server. All prompts and decisions are recorded on branch `live-log`.

## Results

Final designs synthesized with Genus on GPDK045, with static timing and SDF-annotated simulation in Questa. The full discussion is in `submission/pdf_report/report.pdf`.

| | 400 MHz | 800 MHz |
|---|---|---|
| Register ranks / flip-flops | 2 / 108 | 6 / 422 |
| Worst setup slack (target) | 158 ps (125 ps) | 79 ps (62 ps) |
| Cell area | 2427.5 µm² | 4485.3 µm² |
| Power, vectorless estimate | 177.5 µW | 732.0 µW |
| SDF-annotated simulation | 1264 of 1264 products correct | 1162 of 1162 products correct |

## Reproducing the results

```bash
bash submission/scripts/install.sh
make all RUN=400
make all RUN=800
```

The install script fetches pinned versions of Yosys, OpenSTA, Icarus Verilog and the Nangate45 library. `make all` runs synthesis, the RTL and gate-level checks, static timing, power and the reset check for one frequency. `submission/scripts/fresh_clone_rerun.sh` repeats the whole flow from a clean clone, and its log is in `submission/syn_reports/fresh_clone_rerun.log`.

## Repository contents

| Path | Contents |
|---|---|
| `SPEC.md` | Design specification |
| `CLAUDE.md` | Instructions for the implementing agent |
| `starter/` | Interface skeleton, memory model and testbench harnesses |
| `docs/fig/` | Timing diagrams referenced in the specification |
| `submission/` | Deliverables: RTL, testbenches, scripts, netlists, reports and the report PDF |
| `notes/` | Work log and reference checks |
| `.claude/` | Session hook that publishes the live log |

## Branches

| Branch | Contents |
|---|---|
| `main` | Design, verification, flow and report |
| `live-log` | Session record and terminal recording, updated as the work proceeded |
| `check-results` | Scorecards from the GPDK045 check service |
| `candidates` | Archive of the candidate commits submitted to the GPDK045 check but not merged into `main` such that every scorecard on `check-results` still points at a reachable commit |
