// mkMultBuff.sv -- 800 MHz implementation (1.25 ns clock), Nangate45 slow corner.
//
// Pipelined signed 16x16 multiplier with a 64-entry fill/drain buffer (SPEC.md).
// Datapath: mult_pipe.sv: radix-4 Booth partial products, row-wise 3:2
// carry-save reduction 9 -> 6 -> 4 -> 3 -> 2 rows with each 3:2 adding its
// latest input last, and a two-stage carry-increment adder with 4-bit blocks.
// Six register ranks (latency 6):
//   R1 operand a + Booth digits of b (40)   R2 selected partial products (144)
//   R3 four rows after levels 1-2 (92)      R4 two rows after levels 3-4 (60)
//   R5 adder stage A: block sums for carry-in 0, block carry-outs for carry-in
//      0 and 1 (43)                         R6 product (32), drives writeMem_val
// A LAT-bit valid shift register runs alongside the datapath; its last bit is
// EN_writeMem (F4).
//
// Control (31 flops): the registered ready flags rdy_mult_q / rdy_rd_q are the
// fill / drain state machine (FILL = {1,0}, WAIT = {0,0}, DRAIN = {0,1}).
// acc_q counts pairs accepted in the fill phase, so pairs in flight count
// against the capacity (F5). The drain starts in the cycle after the last write
// of the fill: the write made when the fill is closed (rdy_mult_q = 0) and no
// other product is in flight, which is the write to address 63 (F6). The write
// and read pointers are split 3+3 bits with a registered "low half = 7" flag, so
// their increment and the "= 63" test are short. RDY_mult and RDY_blockRead are
// driven by port-only copies of the ready flags, stored inverted so synthesis
// does not merge them with the internal flags; the 23.5 fF port load then does
// not slow the handshake logic. All outputs come from registers except
// EN_readMem (= EN_blockRead & RDY_blockRead, F7) and memVal_data (= readMem_val,
// F8). Every register has a synchronous active-low reset (F14, F15).
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
    // multiplier configuration (see mult_pipe.sv); LAT = register ranks
    localparam int LAT = 6;

    logic           rdy_mult_q, rdy_rd_q;     // state (internal copies)
    logic           rdy_mult_on, rdy_rd_on;   // port copies, stored inverted
    logic [5:0]     acc_q, wp_q, rp_q;
    logic           wc_q, rc_q;               // wp_q[2:0] == 7, rp_q[2:0] == 7
    logic [LAT-1:0] v_q;                      // valid bit of each pipeline rank
    logic           vld_q;                    // VALID_memVal
    logic signed [31:0] p;

    wire acc     = EN_mult & rdy_mult_q;           // accepted operand pair
    wire rd      = EN_blockRead & rdy_rd_q;        // accepted read
    wire wr      = v_q[LAT-1];                     // memory write this cycle
    wire wr_last = wr && !rdy_mult_q && v_q[LAT-2:0] == '0;   // write to address 63
    wire rp_last = rc_q && rp_q[5:3] == 3'd7;                 // read of address 63

    always_ff @(posedge clk) begin
        if (!RST_N) begin
            rdy_mult_q <= 1'b1; rdy_mult_on <= 1'b0;
            rdy_rd_q   <= 1'b0; rdy_rd_on   <= 1'b1;
            acc_q <= '0; wp_q <= '0; rp_q <= '0; wc_q <= 1'b0; rc_q <= 1'b0;
            v_q <= '0; vld_q <= 1'b0;
        end else begin
            v_q <= {v_q[LAT-2:0], acc};
            if (acc) begin
                acc_q <= acc_q + 6'd1;
                if (acc_q == 6'd63) begin rdy_mult_q <= 1'b0; rdy_mult_on <= 1'b1; end
            end
            if (wr) begin
                wp_q[2:0] <= wp_q[2:0] + 3'd1;
                if (wc_q) wp_q[5:3] <= wp_q[5:3] + 3'd1;
                wc_q <= (wp_q[2:0] == 3'd6);
            end
            if (rd) begin
                rp_q[2:0] <= rp_q[2:0] + 3'd1;
                if (rc_q) rp_q[5:3] <= rp_q[5:3] + 3'd1;
                rc_q <= (rp_q[2:0] == 3'd6);
            end
            if (wr_last) begin rdy_rd_q <= 1'b1; rdy_rd_on <= 1'b0; end      // F6
            if (rd && rp_last) begin                                          // F10
                rdy_rd_q <= 1'b0; rdy_rd_on <= 1'b1;
                rdy_mult_q <= 1'b1; rdy_mult_on <= 1'b0;
            end
            vld_q <= rd;                                                      // F8
        end
    end

    mult_pipe #(.PRE_ENC(1'b1), .SEL_REG(1'b1), .CSA_REG(4'b1010), .ORD(1'b1),
                .CPA(1), .CI1(1'b1), .CSW(4), .DRST(1'b1))
        u_mult (.clk(clk), .RST_N(RST_N), .en(acc), .a(mult_input0), .b(mult_input1), .p(p));

    assign RDY_mult      = ~rdy_mult_on;
    assign RDY_blockRead = ~rdy_rd_on;
    assign EN_writeMem   = wr;
    assign writeMem_addr = wp_q;
    assign writeMem_val  = p;
    assign EN_readMem    = rd;
    assign readMem_addr  = rp_q;
    assign VALID_memVal  = vld_q;
    assign memVal_data   = readMem_val;       // not registered again (F8)
endmodule : mkMultBuff
