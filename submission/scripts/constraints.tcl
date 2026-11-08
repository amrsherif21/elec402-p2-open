# constraints.tcl -- SPEC.md Section 6 constraints for OpenSTA. Needs $period (ns).
set clk_port [get_ports clk]
create_clock -name clk -period $period $clk_port
set_clock_transition [expr {$period / 8.0}] [get_clocks clk]
set in_ports [lsearch -inline -all -not -exact [all_inputs] $clk_port]
set_input_delay  0.0 -clock clk $in_ports
set_output_delay 0.0 -clock clk [all_outputs]
# input drive: output of the smallest D flip-flop (DFF_X1/Q), whose clock input
# has a transition of one eighth of the clock period
set_driving_cell -lib_cell DFF_X1 -pin Q -from_pin CK \
    -input_transition_rise [expr {$period / 8.0}] \
    -input_transition_fall [expr {$period / 8.0}] $in_ports
# output load: 4 x input capacitance of NAND2_X4 (pin A1)
set c_nand [get_property [get_lib_pins */NAND2_X4/A1] capacitance]
set_load [expr {4.0 * $c_nand}] [all_outputs]
# pre-layout wire estimate: the library's default wire-load model
set_wire_load_model -name 5K_hvratio_1_1
