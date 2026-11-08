#!/usr/bin/env bash
# eval_candidate.sh RUN RTL_DIR WORK_DIR [make overrides...]
# Runs one candidate implementation through the open-source flow (synth, RTL check,
# zero-delay gate sim, activity power) and prints one summary block: slack, area
# split sequential/combinational, flops, vectorless and activity power, and the flop
# count and worst setup slack of every register group (Q-net name).
# Example: bash submission/scripts/eval_candidate.sh 800 build/cand/x/rtl build/cand/x
set -uo pipefail
RUN=$1; RTL=$2; W=$3; shift 3
mkdir -p "$W/rep"
M="RUN=$RUN RTL_DIR=$RTL BUILD=$W REP=$W/rep NETLIST=$W/map.v SDF=$W/map.sdf $*"
make -s check $M > "$W/check.out" 2>&1; CHK=$(grep -c "^ALL PASS" "$W/rep/check.log" 2>/dev/null)
make -s synth $M > "$W/synth.out" 2>&1
make -s sim $M > "$W/sim.out" 2>&1;   SIM=$(grep -c "^ALL PASS" "$W/rep/sim.log" 2>/dev/null)
make -s power $M > "$W/power.out" 2>&1
PER=$([ "$RUN" = 400 ] && echo 2.5 || echo 1.25)
docker run --rm -v "$PWD:$PWD" -w "$PWD" -e LIB=tech/NangateOpenCellLibrary_slow.lib -e NETLIST="$W/map.v" \
  -e PERIOD="$PER" --entrypoint /OpenSTA/build/sta \
  openroad/opensta@sha256:4162b4be70ee69eaa42e5eb3c830433393ff46cf0370f9b6c5b814b48a221a7a \
  -no_init -no_splash -exit submission/scripts/ranks.tcl > "$W/rep/ranks.rpt" 2>&1
S="$W/rep/sta.rpt"
WNS=$(awk '/^worst slack max/{print $NF}' "$S"); WHS=$(awk '/^worst slack min/{print $NF}' "$S")
AREA=$(grep "^cell area" "$S")
TOT=$(echo "$AREA" | sed 's/cell area \([0-9.]*\).*/\1/'); SEQ=$(echo "$AREA" | sed 's/.*sequential \([0-9.]*\).*/\1/')
FF=$(awk '/^cell DFF/{n+=$3} END{print n}' "$S")
PV=$(awk '/^Total/{print $5*1e6; exit}' "$S")
PS=$(awk 'NR>2{printf "%s=%s ", $1, $NF}' "$W/rep/power_summary.txt" 2>/dev/null)
echo "== $W RUN=$RUN"
echo "check=$([ "$CHK" = 1 ] && echo PASS || echo FAIL) sim=$([ "$SIM" = 1 ] && echo PASS || echo FAIL) wns=$WNS whs=$WHS"
printf "area=%s seq=%s comb=%.1f flops=%s vectorless_uW=%.1f\n" "$TOT" "$SEQ" "$(echo "$TOT - $SEQ" | bc)" "$FF" "$PV"
echo "activity_uW: $PS"
echo "per register group (flops, worst slack):"; cat "$W/rep/ranks.rpt" | grep -v "^Warning"
