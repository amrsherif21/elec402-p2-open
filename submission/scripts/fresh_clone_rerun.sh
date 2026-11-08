#!/bin/bash
# fresh-clone rerun of the whole flow
set -x
SP=/tmp/claude-0/-home-user-elec402-p2-open/6503db16-82a0-5ee1-9a2e-83eb2b44d2ca/scratchpad
rm -rf $SP/fresh && git clone -q -b claude/focused-dijkstra-3f079i https://github.com/amrsherif21/elec402-p2-open $SP/fresh
cd $SP/fresh && git log --oneline | head -1
date -u +%T
bash submission/scripts/install.sh 2>&1 | tail -3
for R in 400 800; do
  make synth check sim timing power f14 RUN=$R 2>&1 | grep -E "^(worst slack|tns|cell area|ALL PASS|FAIL|TIMING FAIL|F14CHECK|fill|drain|run:|synthesis)|summary|Error|error" 
  make timing_fail RUN=$R 2>&1 | grep -E "^worst slack max|timing_fail:"
  bash submission/scripts/mutate.sh $R 2>&1 | grep killed
done
date -u +%T
git status --short | head -40
git diff --stat -- submission/outputs | tail -3
