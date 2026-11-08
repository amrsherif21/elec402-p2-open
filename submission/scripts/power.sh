#!/usr/bin/env bash
# power.sh REP BUILD NETLIST PERIOD LIB STA_IMAGE
# Activity-based power from the gate-level VCD of `make sim`: the whole run and the
# two 64-cycle windows announced by the RTL checker as "PWR_WIN <fill|drain> <t0> <t1>".
set -euo pipefail
REP=$1 BUILD=$2 NETLIST=$3 PERIOD=$4 LIB=$5 IMG=$6
VCD=$BUILD/gate.vcd
[ -f "$VCD" ] || { echo "power.sh: $VCD missing, run make sim first"; exit 1; }
sta() {  # TAG [BEGIN END]
  docker run --rm -v "$PWD:$PWD" -w "$PWD" -e LIB="$LIB" -e NETLIST="$NETLIST" \
    -e PERIOD="$PERIOD" -e VCD="$VCD" -e TAG="$1" -e BEGIN="${2:-}" -e END="${3:-}" \
    --entrypoint /OpenSTA/build/sta "$IMG" -no_init -no_splash -exit submission/scripts/power.tcl
}
sta run > "$REP/power.rpt" 2>&1
for w in fill drain; do
  read -r _ _ t0 t1 < <(grep "^PWR_WIN $w " "$REP/sim.log" | head -1)
  sta "$w" "$t0" "$t1" >> "$REP/power.rpt" 2>&1
done
python3 submission/scripts/power_summary.py "$REP" | tee "$REP/power_summary.txt"
