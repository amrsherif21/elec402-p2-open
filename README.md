# mkMultBuff

Design of a pipelined signed 16 × 16 multiplier with a 64-entry fill/drain buffer, implemented at 400 MHz and 800 MHz with open-source tools.

## Repository contents

| Path | Contents |
|---|---|
| `SPEC.md` | Design specification |
| `CLAUDE.md` | Instructions for the implementing agent |
| `starter/` | Interface skeleton, memory model and testbench harnesses |
| `docs/fig/` | Timing diagrams referenced in the specification |
| `submission/` | Deliverables |
| `notes/` | Work log |

## Branches

| Branch | Contents |
|---|---|
| `main` | Design, verification, flow and report |
| `live-log` | Session record and terminal recording, updated as the work proceeds |
| `check-results` | Scorecards from the GPDK045 sign-off service |
| `candidates` | Archive of the sign-off candidate commits that were not merged into `main`, so that every scorecard on `check-results` still points at a reachable commit |
