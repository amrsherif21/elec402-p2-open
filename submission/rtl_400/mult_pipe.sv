// mult_pipe.sv -- pipelined signed 16x16 multiplier: radix-4 (modified) Booth
// partial products, carry-save (3:2) reduction 9->6->4->3->2 rows and a final
// carry-propagate adder. Every pipeline cut is optional (parameters).
//   PRE_ENC  : Booth-recode the multiplier before the operand register
//   ENC_REG  : (PRE_ENC = 0 only) extra rank after the Booth recoding
//   SEL_REG  : register the selected partial products (8 x 17 bits + 8 "+1" bits)
//   CSA_REG  : bit k set -> register after carry-save level k+1 (k = 0..3)
//   GP4      : the level-4 register holds generate/propagate (c&s, c^s) of the
//              two final rows instead of the rows themselves (same width)
//   CPA_CSEL : two-stage carry-select final adder with CSW-bit blocks and
//              Kogge-Stone prefixes inside the blocks and across the blocks
//   CPA_SPLIT: (alternative) low 16 bits in one stage, high 16 bits in the next
// Register ranks (= latency from 'en' to 'p'): 1 (operand) + (PRE_ENC ? 0 : ENC_REG)
//   + SEL_REG + popcount(CSA_REG) + (CPA_CSEL | CPA_SPLIT) + 1 (product)
// Every register has a synchronous active-low reset. When 'en' is 0 the operand
// register loads zeros (operand isolation), so an idle multiplier does not toggle.
// Written for this project; the Booth recoding, the sign-extension constant and
// the prefix adders follow textbook schemes (see the report's references).
module mult_pipe #(
    parameter bit       PRE_ENC   = 1'b1,
    parameter bit       ENC_REG   = 1'b0,
    parameter bit [3:0] CSA_REG   = 4'b1000,
    parameter bit       SEL_REG   = 1'b0,
    parameter bit       CPA_SPLIT = 1'b0,
    parameter bit       CPA_CSEL  = 1'b0,
    parameter int       CSW       = 8,
    parameter bit       GP4       = 1'b0
) (
    input  logic               clk,
    input  logic               RST_N,
    input  logic               en,     // accept: load operands, else load zeros
    input  logic signed [15:0] a,      // multiplicand (unregistered input)
    input  logic signed [15:0] b,      // multiplier   (unregistered input)
    output logic signed [31:0] p       // product, registered
);
    // Booth radix-4 recoding of y: digit_i = -2 y[2i+1] + y[2i] + y[2i-1]
    function automatic logic [23:0] booth_enc(input logic [15:0] y);
        logic [16:0] yx;
        logic [7:0]  one, two, neg;
        yx = {y, 1'b0};                       // yx[k+1] = y[k], yx[0] = y[-1] = 0
        for (int i = 0; i < 8; i++) begin
            one[i] = yx[2*i+1] ^ yx[2*i];
            two[i] = (yx[2*i+2] & ~yx[2*i+1] & ~yx[2*i]) | (~yx[2*i+2] & yx[2*i+1] & yx[2*i]);
            neg[i] = yx[2*i+2];
        end
        booth_enc = {neg, two, one};
    endfunction

    // ---- stage 0: operand register (operand isolation: zeros when idle)
    logic [7:0]  one_e, two_e, neg_e;
    logic [15:0] a_e;
    generate if (PRE_ENC) begin : g_pre
        // recode the multiplier before the operand register
        logic [7:0]  one_q, two_q, neg_q;
        logic [15:0] a_q;
        always_ff @(posedge clk) begin
            if (!RST_N || !en) begin
                a_q <= '0; one_q <= '0; two_q <= '0; neg_q <= '0;
            end else begin
                a_q <= a; {neg_q, two_q, one_q} <= booth_enc(b);
            end
        end
        assign {a_e, one_e, two_e, neg_e} = {a_q, one_q, two_q, neg_q};
    end else begin : g_post
        logic [15:0] a_q, b_q;
        logic [7:0]  one_d, two_d, neg_d;
        always_ff @(posedge clk) begin
            if (!RST_N || !en) begin a_q <= '0; b_q <= '0; end
            else               begin a_q <= a;  b_q <= b;  end
        end
        assign {neg_d, two_d, one_d} = booth_enc(b_q);
        if (ENC_REG) begin : g_enc
            logic [7:0]  one_r, two_r, neg_r;
            logic [15:0] a_r;
            always_ff @(posedge clk) begin
                if (!RST_N) begin a_r <= '0; one_r <= '0; two_r <= '0; neg_r <= '0; end
                else begin a_r <= a_q; one_r <= one_d; two_r <= two_d; neg_r <= neg_d; end
            end
            assign {a_e, one_e, two_e, neg_e} = {a_r, one_r, two_r, neg_r};
        end else begin : g_noenc
            assign {a_e, one_e, two_e, neg_e} = {a_q, one_d, two_d, neg_d};
        end
    end endgenerate
    genvar i;

    localparam int NB = 32 / CSW;     // carry-select blocks

    // Kogge-Stone prefix over the NB block carries (generate = carry-out with
    // carry-in 0, propagate = carry-out with carry-in 1)
    function automatic logic [NB-1:0] bprefix(input logic [NB-1:0] g, input logic [NB-1:0] p);
        logic [NB-1:0] G, P;
        G = g; P = p;
        for (int d = 1; d < NB; d = 2 * d)
            for (int j = NB - 1; j >= d; j--) begin
                G[j] = G[j] | (P[j] & G[j-d]);
                P[j] = P[j] & P[j-d];
            end
        bprefix = G;
    endfunction

    // Kogge-Stone prefix over a CSW-bit block: G[j] / P[j] = group generate /
    // propagate of bits j..0 of the block
    function automatic logic [2*CSW-1:0] prefix(input logic [CSW-1:0] g, input logic [CSW-1:0] p);
        logic [CSW-1:0] G, P;
        G = g; P = p;
        for (int d = 1; d < CSW; d = 2 * d)
            for (int j = CSW - 1; j >= d; j--) begin
                G[j] = G[j] | (P[j] & G[j-d]);
                P[j] = P[j] & P[j-d];
            end
        prefix = {G, P};
    endfunction

    // ------------------------------------------------------------------
    // Partial-product rows. Sign extension is replaced by inverting each row's
    // sign bit and adding the constant K = -sum(2^(16+2i)) (mod 2^32); the
    // "+1" of each negative row is placed in the free bit of the next row.
    localparam logic [31:0] K = 32'hAAAB_0000;  // -(2^16+2^18+...+2^30) mod 2^32
    wire [16:0] a17 = {a_e[15], a_e};
    wire [16:0] a2  = {a_e, 1'b0};
    logic [31:0] r0, r1, r2, r3, r4, r5, r6, r7, r8;
    logic [16:0] pp [0:7];
    logic [31:0] rw [0:7];
    generate for (i = 0; i < 8; i++) begin : g_pp
        assign pp[i] = (({17{one_e[i]}} & a17) | ({17{two_e[i]}} & a2)) ^ {17{neg_e[i]}};
        if (i == 0) begin : g_r0
            assign rw[i] = {15'd0, ~pp[i][16], pp[i][15:0]};
        end else begin : g_ri
            // bits [2i+16:2i] hold the row, bit 2i-2 holds the +1 of row i-1
            assign rw[i] = {13'd0, ~pp[i][16], pp[i][15:0], 1'b0, neg_e[i-1]} << (2*i-2);
        end
    end endgenerate
    assign {r0, r1, r2, r3, r4, r5, r6, r7} = {rw[0], rw[1], rw[2], rw[3], rw[4], rw[5], rw[6], rw[7]};
    assign r8 = K | ({31'd0, neg_e[7]} << 14);

    // ------------------------------------------------------------------
    // carry-save levels (3:2 compressors on whole rows); each optionally registered
    function automatic logic [63:0] csa(input logic [31:0] x, y, z);
        csa = {((x & y) | (x & z) | (y & z)) << 1, x ^ y ^ z};
    endfunction

    // level 1: 9 -> 6, level 2: 6 -> 4, level 3: 4 -> 3, level 4: 3 -> 2
    logic [6*32-1:0] l1, l1q;
    logic [4*32-1:0] l2, l2q;
    logic [3*32-1:0] l3, l3q;
    logic [2*32-1:0] l4, l4q;
    // optional register after partial-product selection (8 rows of 17 bits + the
    // row +1 bits; the constant part of row 8 is re-created after the register)
    logic [31:0] q0, q1, q2, q3, q4, q5, q6, q7, q8;
    generate if (SEL_REG) begin : g_sel
        logic [16:0] ppq [0:7];
        logic [7:0]  negq;
        for (i = 0; i < 8; i++) begin : g_q
            always_ff @(posedge clk) ppq[i] <= RST_N ? pp[i] : 17'd0;
        end
        always_ff @(posedge clk) negq <= RST_N ? neg_e : 8'd0;
        assign q0 = {15'd0, ~ppq[0][16], ppq[0][15:0]};
        assign q1 = {13'd0, ~ppq[1][16], ppq[1][15:0], 1'b0, negq[0]} << 0;
        assign q2 = {13'd0, ~ppq[2][16], ppq[2][15:0], 1'b0, negq[1]} << 2;
        assign q3 = {13'd0, ~ppq[3][16], ppq[3][15:0], 1'b0, negq[2]} << 4;
        assign q4 = {13'd0, ~ppq[4][16], ppq[4][15:0], 1'b0, negq[3]} << 6;
        assign q5 = {13'd0, ~ppq[5][16], ppq[5][15:0], 1'b0, negq[4]} << 8;
        assign q6 = {13'd0, ~ppq[6][16], ppq[6][15:0], 1'b0, negq[5]} << 10;
        assign q7 = {13'd0, ~ppq[7][16], ppq[7][15:0], 1'b0, negq[6]} << 12;
        assign q8 = K | ({31'd0, negq[7]} << 14);
    end else begin : g_nosel
        assign {q0, q1, q2, q3, q4, q5, q6, q7, q8} = {r0, r1, r2, r3, r4, r5, r6, r7, r8};
    end endgenerate
    assign l1 = {csa(q6, q7, q8), csa(q3, q4, q5), csa(q0, q1, q2)};
    assign l2 = {csa(l1q[3*32 +: 32], l1q[4*32 +: 32], l1q[5*32 +: 32]),
                 csa(l1q[0*32 +: 32], l1q[1*32 +: 32], l1q[2*32 +: 32])};
    assign l3 = {l2q[3*32 +: 32], csa(l2q[0*32 +: 32], l2q[1*32 +: 32], l2q[2*32 +: 32])};
    // level 4 output: the two final rows {c, s}, or (GP4) their bitwise
    // generate / propagate {c & s, c ^ s}, so the adder's first gate level
    // moves in front of the level-4 register
    logic [63:0] l4cs;
    assign l4cs = csa(l3q[0*32 +: 32], l3q[1*32 +: 32], l3q[2*32 +: 32]);
    assign l4 = GP4 ? {l4cs[63:32] & l4cs[31:0], l4cs[63:32] ^ l4cs[31:0]} : l4cs;

    generate
        if (CSA_REG[0]) begin : g_r1
            always_ff @(posedge clk) l1q <= RST_N ? l1 : '0;
        end else begin : g_n1
            assign l1q = l1;
        end
        if (CSA_REG[1]) begin : g_r2
            always_ff @(posedge clk) l2q <= RST_N ? l2 : '0;
        end else begin : g_n2
            assign l2q = l2;
        end
        if (CSA_REG[2]) begin : g_r3
            always_ff @(posedge clk) l3q <= RST_N ? l3 : '0;
        end else begin : g_n3
            assign l3q = l3;
        end
        if (CSA_REG[3]) begin : g_r4
            always_ff @(posedge clk) l4q <= RST_N ? l4 : '0;
        end else begin : g_n4
            assign l4q = l4;
        end
    endgenerate
    wire [31:0] sx = l4q[31:0], sy = l4q[63:32];

    // ------------------------------------------------------------------
    // final carry-propagate adder, registered product
    generate if (CPA_CSEL) begin : g_csel
        // two-stage carry-select adder with CSW-bit blocks. Stage A: per block,
        // bit generate/propagate and an in-block Kogge-Stone prefix give the
        // block sums for carry-in 0 and carry-in 1 and the two block carry-outs.
        // Stage B: the block carries are resolved and each block sum selected.
        logic [31:0]   s0, s1, s0q, s1q;
        logic [NB-1:0] co0, co1, co0q, co1q, cin;
        for (i = 0; i < NB; i++) begin : g_blk
            logic [CSW-1:0] gg, pp_, G, P;
            if (GP4) begin : g_gp
                assign gg  = sy[CSW*i +: CSW];        // generate (registered)
                assign pp_ = sx[CSW*i +: CSW];        // propagate (registered)
            end else begin : g_cs
                assign gg  = sx[CSW*i +: CSW] & sy[CSW*i +: CSW];
                assign pp_ = sx[CSW*i +: CSW] ^ sy[CSW*i +: CSW];
            end
            assign {G, P} = prefix(gg, pp_);
            assign s0[CSW*i +: CSW] = pp_ ^ {G[CSW-2:0], 1'b0};
            assign s1[CSW*i +: CSW] = pp_ ^ {G[CSW-2:0] | P[CSW-2:0], 1'b1};
            assign co0[i] = G[CSW-1];
            assign co1[i] = G[CSW-1] | P[CSW-1];
        end
        always_ff @(posedge clk) begin
            if (!RST_N) begin
                s0q <= '0; s1q <= '0; co0q <= '0; co1q <= '0;
            end else begin
                s0q <= s0; s1q <= s1; co0q <= co0; co1q <= co1;
            end
        end
        // carry into block i = group generate of blocks i-1..0
        logic [NB-1:0] bg;
        assign bg  = bprefix(co0q, co1q);
        assign cin = {bg[NB-2:0], 1'b0};
        logic [31:0] psel;
        for (i = 0; i < NB; i++) begin : g_sel
            assign psel[CSW*i +: CSW] = cin[i] ? s1q[CSW*i +: CSW] : s0q[CSW*i +: CSW];
        end
        always_ff @(posedge clk) p <= RST_N ? psel : 32'd0;
    end else if (CPA_SPLIT) begin : g_split
        logic [16:0] lo;
        logic [15:0] lo_q, xh_q, yh_q;
        logic        c_q;
        assign lo = {1'b0, sx[15:0]} + {1'b0, sy[15:0]};
        always_ff @(posedge clk) begin
            if (!RST_N) begin
                lo_q <= '0; c_q <= 1'b0; xh_q <= '0; yh_q <= '0; p <= '0;
            end else begin
                lo_q <= lo[15:0]; c_q <= lo[16];
                xh_q <= sx[31:16]; yh_q <= sy[31:16];
                p    <= {xh_q + yh_q + {15'd0, c_q}, lo_q};
            end
        end
    end else begin : g_full
        always_ff @(posedge clk) begin
            if (!RST_N) p <= '0;
            else        p <= sx + sy;
        end
    end endgenerate
endmodule : mult_pipe
