#!/usr/bin/env bash
# waves.sh RUN -- waveform figures for the report, rendered headlessly with GTKWave
# under Xvfb. The same gate-level checker (sdf_checker_<RUN>.sv) drives the RTL and
# the SDF-annotated netlist, so the RTL and gate-level waveforms line up cycle for
# cycle. Output: submission/pdf_report/fig/wave_<RUN>_<window>_<rtl|gate>.png
set -euo pipefail
RUN=${1:-400}
B=build/$RUN/waves; F=submission/pdf_report/fig
mkdir -p "$B" "$F"
TOP=mkMultBuff_sdf_checker_$RUN
SDF=submission/outputs/mkMultBuff_${RUN}_map.sdf
MEM="starter/rtl/memory_wrapper_2port.sv starter/rtl/registerArray.sv"
[ -f build/$RUN/netlist_sim.v ] || make -s build/$RUN/netlist_sim.v RUN=$RUN
for k in rtl gate; do
  if [ $k = rtl ]; then SRC="submission/rtl_$RUN/*.sv"; SP=""
  else SRC="build/$RUN/netlist_sim.v tech/NangateOpenCellLibrary.v"; SP="-gspecify"; fi
  iverilog -g2012 $SP -DTOP=$TOP -DTSTOP=2000 -s $TOP -s wave_dumper -o $B/$k.vvp \
    submission/testbench/sdf_checker_$RUN.sv submission/scripts/waves/dumper.v $MEM $SRC
  vvp -n $B/$k.vvp +sdf_file=$SDF +wavefile=$B/$k.vcd > $B/$k.log
  grep -q "^ALL PASS" $B/$k.log
done
ev() { python3 submission/scripts/waves/vcd_events.py $B/rtl.vcd "$1" | awk -v v="$2" -v n="$3" '$2==v{c++; if(c==n){print $1; exit}}'; }
P=$([ "$RUN" = 400 ] && echo 2500 || echo 1250)
t_full=$(ev RDY_blockRead 1 1)            # drain starts (cycle after write of 63)
t_end=$(ev RDY_mult 1 2)                  # drain ends, RDY_mult back to 1
t_w0=$(ev EN_writeMem 1 1)                # first write of the first fill
D=$TOP.DUT
SIG="$D.clk $D.EN_mult $D.mult_input0 $D.mult_input1 $D.RDY_mult $D.EN_writeMem $D.writeMem_addr $D.writeMem_val $D.RDY_blockRead $D.EN_blockRead $D.EN_readMem $D.readMem_addr $D.VALID_memVal $D.memVal_data"
render() { # vcd png t0 t1
  cat > $B/g.tcl <<EOF
gtkwave::addSignalsFromList [list $SIG]
gtkwave::/Edit/Highlight_All
gtkwave::/Edit/Data_Format/Hex
gtkwave::/Edit/UnHighlight_All
gtkwave::setZoomRangeTimes $3 $4
gtkwave::/File/Grab_To_File $2
gtkwave::/File/Quit
EOF
  timeout 120 xvfb-run -a -s "-screen 0 1500x620x24" gtkwave --rcvar 'hide_sst on' \
    --rcvar 'splash_disable on' --rcvar 'initial_window_x 1500' --rcvar 'initial_window_y 600' \
    --rcvar 'color_back ffffff' --rcvar 'color_grid dddddd' --rcvar 'color_trans 000000' \
    --rcvar 'color_low 000000' --rcvar 'color_high 000000' --rcvar 'color_1 000000' \
    --rcvar 'color_0 000000' --rcvar 'color_vbox 000000' --rcvar 'color_vtrans 000000' \
    --rcvar 'color_mid 000000' --rcvar 'color_x ff0000' --rcvar 'color_xfill ffcccc' \
    --rcvar 'color_value 000000' --rcvar 'color_timeb ffffff' --rcvar 'color_time 000000' \
    --rcvar 'color_baseline 0000ff' --rcvar 'color_umark 0000ff' \
    -S $B/g.tcl $1 > $B/gtk.log 2>&1
  convert $2 -crop +0+105 +repage -gravity south -chop 0x40 +repage $2   # drop title bar, toolbar, empty strip
}
for k in rtl gate; do
  render $B/$k.vcd $F/wave_${RUN}_fill_$k.png $((t_w0 - 4*P)) $((t_w0 + 6*P))
  render $B/$k.vcd $F/wave_${RUN}_full_$k.png $((t_full - 6*P)) $((t_full + 4*P))
  render $B/$k.vcd $F/wave_${RUN}_drainend_$k.png $((t_end - 6*P)) $((t_end + 3*P))
  render $B/$k.vcd $F/wave_${RUN}_zoom_$k.png $((t_full - 1*P)) $((t_full + 2*P))
done
echo "waves $RUN: first write $t_w0 ps, drain start $t_full ps, drain end $t_end ps"
ls $F/wave_${RUN}_*
