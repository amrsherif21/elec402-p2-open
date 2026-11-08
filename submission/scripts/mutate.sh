#!/usr/bin/env bash
# mutate.sh RUN -- mutation test of the RTL checker: each mutant is a one-line change
# of submission/rtl_<RUN>/mkMultBuff.sv; the checker must report FAIL for every one.
set -uo pipefail
RUN=${1:-400}
HALF=$([ "$RUN" = 400 ] && echo 1.25 || echo 0.625)
SRC=submission/rtl_$RUN
W=build/mutants_$RUN
mkdir -p "$W"
LOG=submission/syn_reports/$RUN/mutation.log
: > "$LOG"
mutants=(
  "acc_q == 6'd63|acc_q == 6'd62|RDY_mult drops one pair early"
  "if (wr \&\& ptr_q == 6'd63) rdy_rd_q <= 1'b1;|if (wr \&\& ptr_q == 6'd62) rdy_rd_q <= 1'b1;|drain starts before the last write"
  "if (rd \&\& ptr_q == 6'd63) begin|if (rd \&\& ptr_q == 6'd62) begin|drain ends one read early"
  "vld_q <= rd;|vld_q <= EN_blockRead;|VALID_memVal ignores RDY_blockRead"
  "wire acc = EN_mult \& rdy_mult_q;|wire acc = EN_mult;|EN_mult accepted while not ready"
  "wire rd  = EN_blockRead \& rdy_rd_q;|wire rd  = rdy_rd_q;|reads without EN_blockRead"
  "rdy_mult_q <= 1'b1; rdy_rd_q <= 1'b0; vld_q <= 1'b0;|rdy_mult_q <= 1'b1; vld_q <= 1'b0;|RDY_blockRead not reset"
  "acc_q <= '0; ptr_q <= '0; v_q <= '0;|acc_q <= '0; ptr_q <= '0;|valid pipeline not reset"
  "v_q <= {v_q\[LAT-2:0\], acc};|v_q <= {v_q[LAT-2:0], EN_mult};|valid bit set by unaccepted pairs"
  "assign memVal_data   = readMem_val;|assign memVal_data   = writeMem_val;|wrong data source"
  "assign EN_readMem    = rd;|assign EN_readMem    = rdy_rd_q;|EN_readMem held during drain"
)
ok=0; tot=0
for m in "${mutants[@]}"; do
  IFS='|' read -r from to desc <<< "$m"
  tot=$((tot+1)); d=$W/m$tot; mkdir -p "$d"
  cp "$SRC"/*.sv "$d"/
  sed -i "s/$from/$to/" "$d/mkMultBuff.sv"
  if cmp -s "$SRC/mkMultBuff.sv" "$d/mkMultBuff.sv"; then
    echo "mutant $tot ($desc): NOT APPLIED" | tee -a "$LOG"; continue
  fi
  iverilog -g2012 -s mkMultBuff_tb -P mkMultBuff_tb.CLK_HALF_NS=$HALF -o "$d/a.vvp" \
     submission/testbench/rtl_checker.sv starter/rtl/memory_wrapper_2port.sv starter/rtl/registerArray.sv "$d"/*.sv
  res=$(vvp -n "$d/a.vvp" | grep -E "^(ALL PASS|FAIL)" | tail -1)
  case "$res" in FAIL*) ok=$((ok+1));; esac
  echo "mutant $tot ($desc): $res" | tee -a "$LOG"
done
echo "killed $ok of $tot mutants" | tee -a "$LOG"
