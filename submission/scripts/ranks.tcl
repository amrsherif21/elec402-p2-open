# ranks.tcl -- flop count and worst setup slack at D per register group (Q-net name). env: LIB NETLIST PERIOD
set period $::env(PERIOD)
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design mkMultBuff
source submission/scripts/constraints.tcl
array set w {}; array set n {}
foreach inst [get_cells *] {
  if {![string match DFF* [get_property $inst ref_name]]} continue
  set in [get_full_name $inst]
  set q [get_full_name [get_nets -of_objects [get_pins $in/Q]]]
  regsub {\s*\[[0-9]+\]\s*$} $q "" g
  set s [get_property [get_pins $in/D] slack_max]
  if {![info exists w($g)] || $s < $w($g)} { set w($g) $s }
  if {[info exists n($g)]} { incr n($g) } else { set n($g) 1 }
}
foreach g [lsort [array names w]] { puts [format "%-36s %4d %8.3f" $g $n($g) $w($g)] }
