// mkMultBuff.sv -- 800 MHz implementation (1.25 ns clock), Nangate45 slow corner.
//
// Pipelined signed 16x16 multiplier with a 64-entry fill/drain buffer (SPEC.md).
// Datapath: mult_pipe (radix-4 Booth, carry-save reduction, carry-select adder),
// with
// 6 register ranks (LAT = @LAT@), listed in the header of the generated mult_pipe.sv.
// A LAT-bit valid shift register runs alongside the datapath and drives
// EN_writeMem (F4).
//
// Control: the registered ready flags rdy_mult_q / rdy_rd_q are the fill /
// drain state machine (FILL = {1,0}, WAIT = {0,0}, DRAIN = {0,1}); acc_q counts
// pairs accepted in the fill phase, so pairs in flight count against the
// capacity (F5); wp_q / rp_q are the write and read pointers. Changes from the
// 400 MHz control for timing at 1.25 ns: separate write and read pointers, and
// port-only copies of RDY_mult, RDY_blockRead, writeMem_addr, readMem_addr and
// EN_writeMem, so the output load does not slow the internal handshake logic.
// All outputs come from registers except EN_readMem (= EN_blockRead &
// RDY_blockRead, F7) and memVal_data (= readMem_val, F8).
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
    localparam int LAT = 6;

    logic       rdy_mult_q, rdy_rd_q, vld_q;
    // copies of the two ready flags that drive only the output ports, so the
    // port load does not slow the internal handshake logic (stored inverted,
    // see below)
    logic rdy_mult_on, rdy_rd_on;
    // likewise port-only copies of the memory addresses and write enable; they
    // are stored inverted (reset value all ones) so that synthesis does not
    // merge them with the internal registers, which have the same next state
    logic [5:0] wp_on, rp_on;
    logic       wr_on;
    logic [5:0] acc_q, wp_q, rp_q;
    logic [LAT-1:0] v_q;                 // valid bit of each pipeline rank
    logic signed [31:0] p;

    wire acc = EN_mult & rdy_mult_q;
    wire rd  = EN_blockRead & rdy_rd_q;
    wire wr  = v_q[LAT-1];

    always_ff @(posedge clk) begin
        if (!RST_N) begin
            rdy_mult_q <= 1'b1; rdy_rd_q <= 1'b0; vld_q <= 1'b0;
            rdy_mult_on <= 1'b0; rdy_rd_on <= 1'b1;
            wp_on <= '1; rp_on <= '1; wr_on <= 1'b1;
            acc_q <= '0; wp_q <= '0; rp_q <= '0; v_q <= '0;
        end else begin
            v_q <= {v_q[LAT-2:0], acc};
            if (acc) begin
                acc_q <= acc_q + 6'd1;
                if (acc_q == 6'd63) begin rdy_mult_q <= 1'b0; rdy_mult_on <= 1'b1; end
            end
            if (wr) begin wp_q <= wp_q + 6'd1; wp_on <= ~(wp_q + 6'd1); end
            if (rd) begin rp_q <= rp_q + 6'd1; rp_on <= ~(rp_q + 6'd1); end
            wr_on <= ~v_q[LAT-2];
            if (wr && wp_q == 6'd63) begin rdy_rd_q <= 1'b1; rdy_rd_on <= 1'b0; end
            if (rd && rp_q == 6'd63) begin
                rdy_rd_q <= 1'b0; rdy_mult_q <= 1'b1;
                rdy_rd_on <= 1'b1; rdy_mult_on <= 1'b0;
            end
            vld_q <= rd;
        end
    end

    mult_pipe u_mult (.clk(clk), .RST_N(RST_N), .en(acc), .a(mult_input0), .b(mult_input1), .p(p));

    assign RDY_mult      = ~rdy_mult_on;
    assign RDY_blockRead = ~rdy_rd_on;
    assign EN_writeMem   = ~wr_on;
    assign writeMem_addr = ~wp_on;
    assign writeMem_val  = p;
    assign EN_readMem    = rd;
    assign readMem_addr  = ~rp_on;
    assign VALID_memVal  = vld_q;
    assign memVal_data   = readMem_val;
endmodule : mkMultBuff
