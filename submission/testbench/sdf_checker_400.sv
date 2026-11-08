// sdf_checker_400.sv -- ELEC 402 2026 Project 2. 400 MHz gate-level (SDF) checker.
// Top module: mkMultBuff_sdf_checker_400. Clock period fixed at 2.5 ns.
// The flow passes +sdf_file=submission/outputs/mkMultBuff_400_map.sdf at run time.
//
// Written from SPEC.md Section 8.2 only; no internal DUT signal is referenced.
//
// Method
//   * Inputs are launched DRV_DLY_NS (20 ps) after each rising edge (the
//     constraints specify a 0 ns input delay); all outputs are sampled at the
//     falling edge.
//   * Handshakes are taken from the sampled outputs: an operand pair is
//     accepted when EN_mult=1 and RDY_mult=1 at the falling edge, a read when
//     EN_blockRead=1 and RDY_blockRead=1.  Each accepted pair is pushed on a
//     scoreboard (32-bit signed product computed by SystemVerilog arithmetic);
//     every cycle with VALID_memVal=1 pops the scoreboard and compares
//     memVal_data with it.  The latency is not assumed; it is measured from
//     the first memory write and reported for information only.
//   * NPH fill/drain phases with mostly back-to-back traffic (so that the
//     critical paths are exercised on every cycle), a few stalled phases, the
//     directed corner operands of SPEC 8.1 and random operands biased towards
//     long carry chains.
//   * TIMING FAIL is reported for any X/Z or incorrect value on memVal_data
//     while VALID_memVal=1, for X/Z on the handshake outputs after reset, for
//     a VALID_memVal without an outstanding product, and when fewer products
//     come back than were accepted (a broken netlist cannot pass by producing
//     nothing).  ALL PASS is printed if and only if no failure occurred.
//
// Simulator limitation: Icarus Verilog 12 (iverilog -g2012 -gspecify) annotates
// the SDF IOPATH and INTERCONNECT delays but ignores $setuphold timing checks,
// so a setup violation does not produce X; the flip-flop simply captures a
// stale or partially updated value.  The checker therefore detects timing
// violations through incorrect values (every product is compared with the
// reference), in addition to X.

`timescale 1ns/1ps

module mkMultBuff_sdf_checker_400;

    localparam real HALF_NS = 1.25;   // 2.5 ns period -> 400 MHz
    localparam int  N = 32;
    localparam real DRV_DLY_NS = 0.020;  // input launch delay after the rising edge
    localparam int  NPH = 6;             // fill/drain phases
    localparam int  PHASE_TIMEOUT = 4000;// cycles allowed per phase
    localparam int  MAX_MSGS = 30;

    logic clk, RST_N;
    logic EN_mult;
    logic [15:0] mult_input0, mult_input1;
    logic RDY_mult;
    logic EN_blockRead;
    logic RDY_blockRead;
    logic VALID_memVal;
    logic [N-1:0] memVal_data;
    logic EN_writeMem, EN_readMem;
    logic [5:0] writeMem_addr, readMem_addr;
    logic [N-1:0] writeMem_val, readMem_val;

    mkMultBuff #(.N(N)) DUT (
        .clk(clk), .RST_N(RST_N),
        .EN_mult(EN_mult), .mult_input0(mult_input0), .mult_input1(mult_input1),
        .RDY_mult(RDY_mult),
        .EN_blockRead(EN_blockRead), .RDY_blockRead(RDY_blockRead),
        .VALID_memVal(VALID_memVal),
        .memVal_data(memVal_data),
        .EN_writeMem(EN_writeMem), .writeMem_addr(writeMem_addr),
        .writeMem_val(writeMem_val),
        .EN_readMem(EN_readMem), .readMem_addr(readMem_addr),
        .readMem_val(readMem_val)
    );

    memory_wrapper_2port #(.DEPTH(64), .LOGDEPTH(6), .WIDTH(N), .MEMTYPE(0)) MEM (
        .clkA(clk), .aA(readMem_addr), .cenA(~EN_readMem), .q(readMem_val),
        .clkB(clk), .aB(writeMem_addr), .cenB(~EN_writeMem), .d(writeMem_val)
    );

    initial clk = 0;
    always #(HALF_NS * 1ns) clk = ~clk;

    initial begin
        string sdf_path;
        if ($value$plusargs("sdf_file=%s", sdf_path))
            $sdf_annotate(sdf_path, DUT, , , "MAXIMUM");
    end

    // ------------------------------------------------------------------
    // Random source and operands
    // ------------------------------------------------------------------
    int unsigned seed, seed0;
    function automatic int unsigned rnd();
        return $urandom(seed);
    endfunction
    function automatic bit chance(input int pct);
        return (rnd() % 100) < pct;
    endfunction

    localparam int NDIR = 10;
    logic [15:0] dir_a [NDIR];
    logic [15:0] dir_b [NDIR];
    initial begin
        dir_a[0] = 16'h8000; dir_b[0] = 16'h8000;   // (-32768, -32768)
        dir_a[1] = 16'hFFFF; dir_b[1] = 16'h0001;   // (-1, 1)
        dir_a[2] = 16'h0000; dir_b[2] = 16'h7FFF;   // (0, 32767)
        dir_a[3] = 16'h7FFF; dir_b[3] = 16'h7FFF;   // (32767, 32767)
        dir_a[4] = 16'hFFFF; dir_b[4] = 16'hFFFF;   // (-1, -1)
        dir_a[5] = 16'h7FFF; dir_b[5] = 16'h8000;   // (32767, -32768)
        dir_a[6] = 16'h8000; dir_b[6] = 16'h0001;
        dir_a[7] = 16'hFFFF; dir_b[7] = 16'h8000;
        dir_a[8] = 16'h5555; dir_b[8] = 16'hAAAA;
        dir_a[9] = 16'hAAAA; dir_b[9] = 16'h5555;
    end

    // Operand with a bias towards values that toggle long carry chains.
    function automatic logic [15:0] operand();
        int unsigned r;
        r = rnd();
        case (r % 10)
            0: return 16'h8000;
            1: return 16'h7FFF;
            2: return 16'hFFFF;
            3: return {1'b1, 15'(rnd())} | 16'h7F00;
            default: return 16'(rnd());
        endcase
    endfunction

    function automatic logic [31:0] ref_prod(input logic [15:0] a, input logic [15:0] b);
        logic signed [31:0] p;
        p = $signed(a) * $signed(b);
        return p;
    endfunction

    // ------------------------------------------------------------------
    // Scoreboard and checks (sampled at the falling edge)
    // ------------------------------------------------------------------
    localparam int SBSZ = 64 * NPH + 64;
    logic [31:0] sb_prod [SBSZ];
    logic [15:0] sb_a [SBSZ];
    logic [15:0] sb_b [SBSZ];
    longint      sb_cyc [SBSZ];
    int  n_acc, n_rd, n_ret, n_wr, n_fail;
    int  lat;
    longint cyc;
    bit  checking;

    task automatic fail(input string s);
        n_fail++;
        if (n_fail <= MAX_MSGS)
            $display("TIMING FAIL t=%0t cycle=%0d: %s", $realtime, cyc, s);
        else if (n_fail == MAX_MSGS + 1)
            $display("TIMING FAIL ... further messages suppressed");
    endtask

    task automatic sample();
        @(negedge clk);
        if (checking) begin
            if ((^{RDY_mult, RDY_blockRead, VALID_memVal, EN_writeMem, EN_readMem}) === 1'bx)
                fail($sformatf("X/Z on control outputs: RDY_mult=%b RDY_blockRead=%b VALID_memVal=%b EN_writeMem=%b EN_readMem=%b",
                     RDY_mult, RDY_blockRead, VALID_memVal, EN_writeMem, EN_readMem));
            // returned products
            if (VALID_memVal === 1'b1) begin
                if (n_ret >= n_acc)
                    fail($sformatf("VALID_memVal=1 with no outstanding product (memVal_data=%h)", memVal_data));
                else begin
                    if ((^memVal_data) === 1'bx)
                        fail($sformatf("X on memVal_data=%b, product #%0d (%0d * %0d)",
                             memVal_data, n_ret, $signed(sb_a[n_ret]), $signed(sb_b[n_ret])));
                    else if (memVal_data !== sb_prod[n_ret])
                        fail($sformatf("memVal_data=%h expected %h, product #%0d (%0d * %0d), xor=%h",
                             memVal_data, sb_prod[n_ret], n_ret, $signed(sb_a[n_ret]), $signed(sb_b[n_ret]),
                             memVal_data ^ sb_prod[n_ret]));
                end
                n_ret++;
            end
            // memory writes: count only, and measure the latency once
            if (EN_writeMem === 1'b1) begin
                if (lat < 0 && n_wr < n_acc) begin
                    lat = int'(cyc - sb_cyc[n_wr]);
                    $display("INFO t=%0t: latency measured from the first write = %0d cycles", $realtime, lat);
                end
                n_wr++;
            end
            // handshakes
            if (EN_mult === 1'b1 && RDY_mult === 1'b1) begin
                if (n_acc < SBSZ) begin
                    sb_prod[n_acc] = ref_prod(mult_input0, mult_input1);
                    sb_a[n_acc] = mult_input0;
                    sb_b[n_acc] = mult_input1;
                    sb_cyc[n_acc] = cyc;
                end
                n_acc++;
            end
            if (EN_blockRead === 1'b1 && RDY_blockRead === 1'b1)
                n_rd++;
        end
    endtask

    task automatic next_cycle();
        @(posedge clk);
        cyc++;
        #(DRV_DLY_NS * 1ns);
    endtask

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    initial begin
        int ph, i, t0, dir_idx;
        int fill_pct [NPH];
        int drain_pct [NPH];
        fill_pct[0] = 100; drain_pct[0] = 100;
        fill_pct[1] = 100; drain_pct[1] = 100;
        fill_pct[2] =  85; drain_pct[2] =  90;
        fill_pct[3] = 100; drain_pct[3] =  70;
        fill_pct[4] =  60; drain_pct[4] = 100;
        fill_pct[5] = 100; drain_pct[5] = 100;

        $timeformat(-12, 0, " ps", 0);
        seed = 402;
        void'($value$plusargs("seed=%d", seed));
        seed0 = seed;
        n_acc = 0; n_rd = 0; n_ret = 0; n_wr = 0; n_fail = 0; lat = -1; cyc = 0; checking = 0;
        RST_N = 0; EN_mult = 0; EN_blockRead = 0; mult_input0 = 0; mult_input1 = 0;

        // Synchronous reset for 4 cycles.
        for (i = 0; i < 4; i++) begin
            next_cycle();
            RST_N = 0; EN_mult = 0; EN_blockRead = 0;
            sample();
        end
        next_cycle();
        RST_N = 1;
        checking = 1;           // outputs must be known from here on
        sample();

        for (ph = 0; ph < NPH; ph++) begin
            // ---- fill ----
            t0 = cyc; dir_idx = 0;
            while (n_acc < 64 * (ph + 1)) begin
                next_cycle();
                EN_blockRead = chance(10);        // no effect expected while filling
                EN_mult = chance(fill_pct[ph]);
                if (ph == 0 && dir_idx < NDIR) begin
                    mult_input0 = dir_a[dir_idx]; mult_input1 = dir_b[dir_idx];
                    if (EN_mult) dir_idx++;
                end else begin
                    mult_input0 = operand(); mult_input1 = operand();
                end
                sample();
                if (cyc - t0 > PHASE_TIMEOUT) begin
                    fail($sformatf("phase %0d: fill not completed (%0d accepted)", ph, n_acc));
                    finish_sim();
                end
            end
            // ---- drain ----
            t0 = cyc;
            while (n_rd < 64 * (ph + 1)) begin
                next_cycle();
                EN_mult = 0;                      // quiet producer
                EN_blockRead = chance(drain_pct[ph]);
                sample();
                if (cyc - t0 > PHASE_TIMEOUT) begin
                    fail($sformatf("phase %0d: drain not completed (%0d of %0d reads accepted)", ph, n_rd, 64 * (ph + 1)));
                    finish_sim();
                end
            end
            $display("INFO t=%0t: phase %0d complete (%0d accepted, %0d returned)", $realtime, ph, n_acc, n_ret);
        end

        // Collect the last product, then stay idle for a few cycles.
        for (i = 0; i < 8; i++) begin
            next_cycle();
            EN_mult = 0; EN_blockRead = 0;
            sample();
        end
        finish_sim();
    end

    task automatic finish_sim();
        if (n_acc != 64 * NPH)
            fail($sformatf("%0d operand pairs accepted, expected %0d", n_acc, 64 * NPH));
        if (n_ret != n_acc)
            fail($sformatf("%0d products returned, %0d accepted", n_ret, n_acc));
        if (n_wr != n_acc)
            fail($sformatf("%0d memory writes, %0d accepted", n_wr, n_acc));
        $display("");
        $display("==== mkMultBuff_sdf_checker_400 summary: period %0.3f ns, seed %0d, latency %0d, %0d cycles, %0d accepted, %0d returned, %0d failure(s) ====",
                 2.0 * HALF_NS, seed0, lat, cyc, n_acc, n_ret, n_fail);
        if (n_fail == 0) $display("ALL PASS");
        else             $display("TIMING FAIL: %0d failure(s)", n_fail);
        $finish;
    endtask

endmodule : mkMultBuff_sdf_checker_400
