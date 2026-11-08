# synth.tcl -- Yosys synthesis of submission/rtl_$RUN to Nangate45 (slow corner).
# Invoked by the Makefile:  yosys -c submission/scripts/synth.tcl  with env
#   RUN      400 | 800
#   LIB      Liberty file (Nangate45 slow corner)
#   ABC_D    ABC delay target in ps (may be shorter than the clock period)
#   BOOTH    1 to let Yosys build a radix-4 Booth multiplier for '*'
#   OUT      netlist path
yosys -import
set run   $::env(RUN)
set lib   $::env(LIB)
set abc_d $::env(ABC_D)
set booth [expr {[info exists ::env(BOOTH)] ? $::env(BOOTH) : 0}]
set out   $::env(OUT)
# library used by ABC for mapping (may mark slow cells dont_use); everything
# else (flip-flop mapping, area report) uses the original library
set maplib [expr {[info exists ::env(MAPLIB)] && $::env(MAPLIB) ne "" ? $::env(MAPLIB) : $lib}]
# final-adder architecture for $lcu (carry look-ahead unit): a Yosys parallel-prefix choice
set adder [expr {[info exists ::env(ADDER)] ? $::env(ADDER) : "sklansky"}]
set extra {}
if {$adder ne "ripple"} { set extra [list -extra-map +/choices/${adder}.v] }

read_liberty -lib $lib
# read every .sv file of the source directory, in any order (SPEC Section 5)
set rtl_dir [expr {[info exists ::env(RTL_DIR)] ? $::env(RTL_DIR) : "submission/rtl_${run}"}]
foreach f [lsort [glob ${rtl_dir}/*.sv]] { read_verilog -sv $f }
hierarchy -check -top mkMultBuff
set sargs [list -top mkMultBuff -flatten {*}$extra]
if {$booth} { lappend sargs -booth }
synth {*}$sargs
opt -full
# sequential mapping: Nangate has no synchronous-reset flop, so the reset is a
# gate in front of D (dfflegalize keeps it synchronous)
dfflibmap -liberty $lib
opt
# ABC: delay-oriented mapping followed by buffering and gate sizing; the
# constraint file gives ABC the input drive and the output load of SPEC Section 6
set cf [open [file rootname $out].abc.constr w]
set drv  [expr {[info exists ::env(ABC_DRIVER)] ? $::env(ABC_DRIVER) : "BUF_X1"}]
set load [expr {[info exists ::env(ABC_LOAD)] ? $::env(ABC_LOAD) : 1.0}]
if {$drv ne "" && $drv ne "none"} { puts $cf "set_driving_cell $drv" }
puts $cf "set_load $load"
close $cf
set abc_script [expr {[info exists ::env(ABC_SCRIPT)] ? $::env(ABC_SCRIPT) : "submission/scripts/abc_speed.script"}]
if {$abc_script eq "default"} {
    abc -D $abc_d -liberty $maplib -constr [file rootname $out].abc.constr
} else {
    abc -D $abc_d -liberty $maplib -script $abc_script -constr [file rootname $out].abc.constr
}
file delete [file rootname $out].abc.constr
opt_clean
setundef -zero
hilomap -singleton -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
opt_clean -purge
check -assert
tee -o [file rootname $out].stat.rpt stat -liberty $lib
write_verilog -noattr -noexpr -nohex -nodec $out
