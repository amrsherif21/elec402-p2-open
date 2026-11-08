# Agent Instructions

## 1. Governing documents

`SPEC.md` governs all work in this repository. The contents of `starter/` are provided inputs and shall not be modified. Open-source material may be used under the conditions of `SPEC.md` Section 7.

## 2. Checkpoints

Work proceeds in checkpoints. At the end of each checkpoint, commit and push the work with the checkpoint named in the commit message, then report the outcome together with any open issues.

## 3. Records

- `notes/WORKLOG.md` is kept up to date while working, not written afterwards. Each entry records what was done and why, with the commands and results that support it.
- Every tool log that supports a reported figure is retained.
- A session hook publishes tool activity and the session transcript to branch `live-log` as work proceeds. The `.claude/` directory shall not be modified or disabled.

## 4. Sign-off service

Pushing a branch named `check/<label>` submits the RTL in `submission/rtl_400/` and `submission/rtl_800/` to the sign-off service described in `SPEC.md` Section 8.3. The scorecard appears on branch `check-results`, under `results/`, usually between five and twenty minutes later while the service is online, and can be read with `git fetch origin check-results`. Work should continue in the meantime rather than wait for the result. The service is intended for completed implementations, not for routine iteration.

## 5. Environment

The session runs on Ubuntu 24.04 (x86-64) with Docker available. The GitHub proxy accepts branch pushes but rejects tag pushes and branch deletions. Tools are installed through the install script required by `SPEC.md` Section 7.

## 6. Parallel execution

Independent workstreams should be assigned to subagents where this shortens the critical path, with integration and the full flow kept in the main session. Suitable workstreams include

- toolchain installation and flow scripts
- the RTL checker and the gate-level checkers, written from `SPEC.md` without reference to the RTL, so that they do not inherit its interpretation of the specification
- the 400 MHz implementation
- the 800 MHz implementation, with candidate microarchitectures evaluated in parallel and the best retained

Concurrency should remain low, as resource use is part of the evaluation.
