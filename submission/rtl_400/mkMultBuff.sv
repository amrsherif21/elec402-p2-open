// mkMultBuff.sv -- 400 MHz implementation (2.5 ns clock), Nangate45 slow corner.
//
// Pipelined signed 16x16 multiplier with a 64-entry fill/drain buffer (SPEC.md).
// Datapath: mult_pipe (radix-4 Booth, carry-save reduction, final adder), with
// 3 register ranks (LAT = @LAT@), listed in the header of the generated mult_pipe.sv.
// Latency (accept -> EN_writeMem) = LAT cycles; a LAT-bit valid shift register
// runs alongside the datapath and drives EN_writeMem (F4).
//
// Control: the two registered ready flags RDY_mult / RDY_blockRead are the
// fill / drain state machine (states FILL = {1,0}, WAIT = {0,0}, DRAIN = {0,1});
// acc_q counts operand pairs accepted in the fill phase, so pairs still in the
// pipeline count against the capacity (F5); ptr_q is the memory address, shared
// by the write pointer (fill) and the read pointer (drain), which never run in
// the same cycle (F13). All outputs come from registers except EN_readMem
// (= EN_blockRead & RDY_blockRead, F7) and memVal_data (= readMem_val, F8).
// Every register has a synchronous active-low reset (F14, F15).
module mkMultBuff #(parameter N = 32) (
    input  logic         clk,
    input  logic         RST_N,
    input  logic         EN_mult,
    input  logic [15:0]  mult_input0,
    input  logic [15:0]  mult_input1,
    output logic         RDY_mult,
    input  logic         EN_blockRead,
    output logic         RDY_blockRead,
    output logic         VALID_memVal,
    output logic [N-1:0] memVal_data,
    output logic         EN_writeMem,
    output logic [5:0]   writeMem_addr,
    output logic [N-1:0] writeMem_val,
    output logic         EN_readMem,
    output logic [5:0]   readMem_addr,
    input  logic [N-1:0] readMem_val
);
    // multiplier pipeline latency (register ranks of the generated mult_pipe.sv)
    localparam int LAT = 3;

    logic       rdy_mult_q, rdy_rd_q, vld_q;
    logic [5:0] acc_q, ptr_q;
    logic [LAT-1:0] v_q;                 // valid bit of each pipeline rank
    logic signed [31:0] p;

    wire acc = EN_mult & rdy_mult_q;
    wire rd  = EN_blockRead & rdy_rd_q;
    wire wr  = v_q[LAT-1];

    always_ff @(posedge clk) begin
        if (!RST_N) begin
            rdy_mult_q <= 1'b1; rdy_rd_q <= 1'b0; vld_q <= 1'b0;
            acc_q <= '0; ptr_q <= '0; v_q <= '0;
        end else begin
            v_q <= {v_q[LAT-2:0], acc};
            if (acc) begin
                acc_q <= acc_q + 6'd1;
                if (acc_q == 6'd63) rdy_mult_q <= 1'b0;
            end
            if (wr | rd) ptr_q <= ptr_q + 6'd1;
            if (wr && ptr_q == 6'd63) rdy_rd_q <= 1'b1;
            if (rd && ptr_q == 6'd63) begin
                rdy_rd_q <= 1'b0; rdy_mult_q <= 1'b1;
            end
            vld_q <= rd;
        end
    end

    mult_pipe u_mult (.clk(clk), .RST_N(RST_N), .en(acc), .a(mult_input0), .b(mult_input1), .p(p));

    assign RDY_mult      = rdy_mult_q;
    assign RDY_blockRead = rdy_rd_q;
    assign EN_writeMem   = wr;
    assign writeMem_addr = ptr_q;
    assign writeMem_val  = p;
    assign EN_readMem    = rd;
    assign readMem_addr  = ptr_q;
    assign VALID_memVal  = vld_q;
    assign memVal_data   = readMem_val;
endmodule : mkMultBuff
