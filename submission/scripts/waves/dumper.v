// dumper.v -- extra top-level module used only for the report's waveform
// figures: dumps the ports of the gate-level checker's DUT to a VCD.
`timescale 1ns/1ps
module wave_dumper;
  initial begin
    string f;
    if (!$value$plusargs("wavefile=%s", f)) f = "wave.vcd";
    $dumpfile(f);
    $dumpvars(1, `TOP.DUT);
    #(`TSTOP) $dumpflush;
  end
endmodule
