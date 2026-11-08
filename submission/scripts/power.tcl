# power.tcl -- activity-based power with OpenSTA from the gate-level VCD.
# env: LIB NETLIST PERIOD VCD TAG [BEGIN END] (VCD time units, ps)
set period $::env(PERIOD)
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design mkMultBuff
source submission/scripts/constraints.tcl
set args [list -scope mkMultBuff_tb/DUT]
set win "whole run"
if {[info exists ::env(BEGIN)] && $::env(BEGIN) ne ""} {
    lappend args -begin_time $::env(BEGIN) -end_time $::env(END)
    set win "$::env(BEGIN)..$::env(END) ps"
}
read_vcd {*}$args $::env(VCD)
puts "== power $::env(TAG): window $win, VCD $::env(VCD)"
report_power -digits 4
