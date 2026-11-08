// rtl_checker.sv -- ELEC 402 2026 Project 2. Top: mkMultBuff_tb.
//
// Self-checking RTL / zero-delay gate-level checker for mkMultBuff, written
// from SPEC.md alone (no knowledge of any particular implementation).
//
// Timing discipline (race-free for RTL and for zero-delay netlists):
//   * all inputs are driven DRV_DLY_NS after the rising edge that starts a cycle;
//   * all DUT outputs (and the testbench inputs) are sampled at the falling edge,
//     which gives the values the next rising edge will sample.
//   No internal DUT signal is referenced.
//
// Reference model: a cycle-accurate model of the ready/valid behaviour of
// SPEC.md Section 4, evaluated once per cycle at the falling edge.  The model
// is driven only by the testbench inputs and by the latency L, which is
// implementation-defined: L is learned from the first product written after
// reset and must then stay constant (F3/F4).  Every observable requirement
// is checked every cycle against the model:
//   F1  every write carries the signed product of its operand pair
//   F2  writes are in acceptance order at addresses 0,1,2,... in each fill
//   F3  one accept per cycle with EN_mult held; every write exactly L cycles
//       after its accept (constant latency)
//   F4  EN_writeMem only when a product is due (no spurious/missing writes)
//   F5  exact RDY_mult every cycle; EN_mult while RDY_mult=0 has no effect
//   F6  RDY_blockRead exactly from the cycle after the write of address 63
//       until the 64th read is accepted
//   F7  EN_readMem/readMem_addr in each accepted-read cycle, EN_readMem=0
//       otherwise (stricter reading: no reads other than accepted ones)
//   F8  VALID_memVal exactly in the cycle after each accepted read, with
//       memVal_data == readMem_val in that cycle
//   F9  EN_blockRead while RDY_blockRead=0 has no effect
//   F10 after the read of address 63: RDY_blockRead=0, RDY_mult=1
//   F11 64 products returned per drain, in order, no loss or duplication
//   F12 RDY_mult and RDY_blockRead never both 1
//   F13 EN_writeMem and EN_readMem never both 1
//   F15 outputs in the cycle after a reset edge; next fill starts at address 0
//       with full capacity (resets applied at start, mid-fill with products in
//       flight, with the buffer full but writes pending, and mid-drain)
//   DATA every product on memVal_data equals the scoreboard (SV signed math)
//   XZ  no X/Z on DUT outputs after the first reset (memVal_data only while
//       VALID_memVal=1, because it mirrors the uninitialised memory otherwise)
//   F14 is not directly observable; it is covered indirectly by F15 and XZ.
//
// Stimulus: NPHASES (14) complete fill/drain phases with different EN_mult /
// EN_blockRead densities and stall bursts, directed corner operands, random
// operands (seed +seed=N, default 402), EN_mult driven while RDY_mult=0 and
// EN_blockRead driven while RDY_blockRead=0.  Phase 1 contains the power
// windows: a fill with EN_mult held at 1 for 64 consecutive accepted cycles,
// and a drain with EN_blockRead held at 1 for 64 consecutive cycles (producer
// quiet: EN_mult=0, operands constant).  Lines
//   PWR_WIN fill <start_ps> <end_ps>
//   PWR_WIN drain <start_ps> <end_ps>
// are printed when each window ends.  +vcd=<file> dumps mkMultBuff_tb.DUT.
//
// Prints "ALL PASS" if and only if no check failed, otherwise "FAIL <n>".

`timescale 1ns/1ps

module mkMultBuff_tb #(
    parameter real CLK_HALF_NS = 1.25,
    parameter int  N = 32,
    parameter real DRV_DLY_NS = 0.1,      // input launch delay after the rising edge
    parameter int  LMAX = 16,             // largest latency accepted by the checker
    parameter int  MAX_CYCLES = 100000,   // watchdog
    parameter int  NPHASES = 14,          // complete fill/drain phases
    parameter int  MAX_MSGS = 40          // failure messages printed in full
);

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
        .EN_mult(EN_mult),
        .mult_input0(mult_input0), .mult_input1(mult_input1),
        .RDY_mult(RDY_mult),
        .EN_blockRead(EN_blockRead), .RDY_blockRead(RDY_blockRead),
        .VALID_memVal(VALID_memVal), .memVal_data(memVal_data),
        .EN_writeMem(EN_writeMem), .writeMem_addr(writeMem_addr),
        .writeMem_val(writeMem_val),
        .EN_readMem(EN_readMem), .readMem_addr(readMem_addr),
        .readMem_val(readMem_val)
    );

    // The memory belongs to the testbench, not to mkMultBuff.
    memory_wrapper_2port #(
        .DEPTH(64), .LOGDEPTH(6), .WIDTH(N), .MEMTYPE(0)
    ) MEM (
        .clkA(clk), .aA(readMem_addr), .cenA(~EN_readMem), .q(readMem_val),
        .clkB(clk), .aB(writeMem_addr), .cenB(~EN_writeMem), .d(writeMem_val)
    );

    initial clk = 0;
    always #(CLK_HALF_NS * 1ns) clk = ~clk;

    // Optional SDF back-annotation hook (used by the SDF checker flow).
    initial begin
        string sdf_path;
        if ($value$plusargs("sdf_file=%s", sdf_path))
            $sdf_annotate(sdf_path, DUT, , , "MAXIMUM");
    end

    // Optional value change dump for power analysis.
    initial begin
        string vcd_path;
        if ($value$plusargs("vcd=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, mkMultBuff_tb.DUT);
        end
    end

    // ------------------------------------------------------------------
    // Check bookkeeping
    // ------------------------------------------------------------------
    localparam int C_F1 = 1,  C_F2 = 2,  C_F3 = 3,  C_F4 = 4,  C_F5 = 5,
                   C_F6 = 6,  C_F7 = 7,  C_F8 = 8,  C_F9 = 9,  C_F10 = 10,
                   C_F11 = 11, C_F12 = 12, C_F13 = 13, C_F15 = 15,
                   C_DATA = 16, C_XZ = 17, C_PHASES = 18, C_WDOG = 19, C_STIM = 20;
    localparam int NCAT = 21;

    int n_chk  [NCAT];
    int n_fail [NCAT];
    int total_fail;
    longint cyc;               // cycle index (incremented at every rising edge)

    function automatic string cat_name(input int c);
        case (c)
            C_F1: return "F1"; C_F2: return "F2"; C_F3: return "F3"; C_F4: return "F4";
            C_F5: return "F5"; C_F6: return "F6"; C_F7: return "F7"; C_F8: return "F8";
            C_F9: return "F9"; C_F10: return "F10"; C_F11: return "F11"; C_F12: return "F12";
            C_F13: return "F13"; C_F15: return "F15"; C_DATA: return "DATA"; C_XZ: return "XZ";
            C_PHASES: return "PHASES"; C_WDOG: return "WATCHDOG"; C_STIM: return "STIMULUS";
            default: return "?";
        endcase
    endfunction

    // Count a check; returns cond so that the caller prints a message on failure.
    function automatic bit ok(input int c, input bit cond);
        n_chk[c]++;
        if (!cond) begin
            n_fail[c]++;
            total_fail++;
        end
        return cond;
    endfunction

    task automatic err(input int c, input string s);
        if (total_fail <= MAX_MSGS)
            $display("ERROR [%s] t=%0t cycle=%0d: %s", cat_name(c), $realtime, cyc, s);
        else if (total_fail == MAX_MSGS + 1)
            $display("ERROR ... further failure messages suppressed (counting continues)");
    endtask

    // ------------------------------------------------------------------
    // Random source
    // ------------------------------------------------------------------
    int unsigned seed, seed0;
    function automatic int unsigned rnd();
        return $urandom(seed);
    endfunction
    function automatic bit chance(input int pct);   // 1 with probability pct %
        return (rnd() % 100) < pct;
    endfunction

    // Directed operand pairs (SPEC 8.1 first, then further corners).
    localparam int NDIR = 16;
    logic [15:0] dir_a [NDIR];
    logic [15:0] dir_b [NDIR];
    initial begin
        dir_a[0]  = -16'sd32768; dir_b[0]  = -16'sd32768;
        dir_a[1]  = -16'sd1;     dir_b[1]  =  16'sd1;
        dir_a[2]  =  16'sd0;     dir_b[2]  =  16'sd32767;
        dir_a[3]  =  16'sd32767; dir_b[3]  =  16'sd32767;
        dir_a[4]  = -16'sd1;     dir_b[4]  = -16'sd1;
        dir_a[5]  =  16'sd32767; dir_b[5]  = -16'sd32768;
        dir_a[6]  = -16'sd32768; dir_b[6]  =  16'sd32767;
        dir_a[7]  = -16'sd32768; dir_b[7]  =  16'sd1;
        dir_a[8]  =  16'sd1;     dir_b[8]  = -16'sd32768;
        dir_a[9]  =  16'sd0;     dir_b[9]  =  16'sd0;
        dir_a[10] = -16'sd32768; dir_b[10] =  16'sd0;
        dir_a[11] = -16'sd1;     dir_b[11] = -16'sd32768;
        dir_a[12] = -16'sd32768; dir_b[12] = -16'sd1;
        dir_a[13] =  16'h5555;   dir_b[13] =  16'hAAAA;
        dir_a[14] =  16'hAAAA;   dir_b[14] =  16'hAAAA;
        dir_a[15] =  16'sd2;     dir_b[15] = -16'sd3;
    end

    function automatic logic [31:0] ref_prod(input logic [15:0] a, input logic [15:0] b);
        logic signed [31:0] p;
        p = $signed(a) * $signed(b);
        return p;
    endfunction

    // ------------------------------------------------------------------
    // Reference model state (values valid for the current cycle)
    // ------------------------------------------------------------------
    localparam int PH_FILL = 0, PH_DRAIN = 1;
    int  m_phase;            // fill / drain
    int  m_acc;              // operand pairs accepted in this fill
    int  m_wr;               // products written in this fill
    int  m_rd;               // reads accepted in this drain
    int  m_ret;              // products returned (VALID) in this drain
    bit  m_active;           // first reset edge seen
    bit  m_post_reset;       // previous cycle had RST_N=0
    bit  m_after_w63;        // previous cycle wrote address 63
    bit  m_after_r63;        // previous cycle accepted read 63
    bit  m_valid_exp;        // VALID_memVal expected this cycle
    logic [31:0] m_valid_data;
    int  m_valid_addr;
    int  lat;                // learned latency, -1 = unknown
    logic [31:0] m_mem [64]; // expected memory contents
    // FIFO of accepted, not yet written products
    longint f_cyc [128];
    logic [31:0] f_prod [128];
    int  f_head, f_tail;     // count = f_tail - f_head
    int  phases_done;
    int  total_acc, total_ret;

    task automatic model_reset();
        m_phase = PH_FILL; m_acc = 0; m_wr = 0; m_rd = 0; m_ret = 0;
        m_after_w63 = 0; m_after_r63 = 0; m_valid_exp = 0;
        f_head = 0; f_tail = 0;
    endtask

    // ------------------------------------------------------------------
    // Per-cycle check and model update (called at the falling edge)
    // ------------------------------------------------------------------
    task automatic check_cycle();
        if (RST_N !== 1'b1) begin
            // Reset sampled at the coming rising edge: no output checks in this
            // cycle; the model is reset for the next one.
            if (RST_N !== 1'b0) begin
                void'(ok(C_STIM, 0)); err(C_STIM, "RST_N not 0/1");
            end
            model_reset();
            m_active = 1;
            m_post_reset = 1;
        end else if (m_active) begin
            check_active();
        end
    endtask

    task automatic check_active();
        bit exp_rdy_m, exp_rdy_b, acc, rd_acc, exp_wr;
        logic [31:0] p;

        // ---- F15: state in the cycle after a reset edge ---------------
        if (m_post_reset) begin
            if (!ok(C_F15, RDY_mult === 1'b1))       err(C_F15, $sformatf("RDY_mult=%b after reset, expected 1", RDY_mult));
            if (!ok(C_F15, EN_writeMem === 1'b0))    err(C_F15, $sformatf("EN_writeMem=%b after reset, expected 0", EN_writeMem));
            if (!ok(C_F15, writeMem_addr === 6'd0))  err(C_F15, $sformatf("writeMem_addr=%0d after reset, expected 0", writeMem_addr));
            if (!ok(C_F15, RDY_blockRead === 1'b0))  err(C_F15, $sformatf("RDY_blockRead=%b after reset, expected 0", RDY_blockRead));
            if (!ok(C_F15, EN_readMem === 1'b0))     err(C_F15, $sformatf("EN_readMem=%b after reset, expected 0", EN_readMem));
            if (!ok(C_F15, VALID_memVal === 1'b0))   err(C_F15, $sformatf("VALID_memVal=%b after reset, expected 0", VALID_memVal));
        end

        // ---- XZ --------------------------------------------------------
        // (XOR reduction is X iff any bit is X/Z; Icarus 12 mis-evaluates
        //  $isunknown on concatenations.)
        if (!ok(C_XZ, (^{RDY_mult, RDY_blockRead, VALID_memVal, EN_writeMem, EN_readMem,
                         writeMem_addr, readMem_addr, writeMem_val}) !== 1'bx))
            err(C_XZ, $sformatf("X/Z on outputs: RDY_mult=%b RDY_blockRead=%b VALID_memVal=%b EN_writeMem=%b EN_readMem=%b writeMem_addr=%b readMem_addr=%b writeMem_val=%h",
                RDY_mult, RDY_blockRead, VALID_memVal, EN_writeMem, EN_readMem, writeMem_addr, readMem_addr, writeMem_val));
        if (VALID_memVal === 1'b1)
            if (!ok(C_XZ, (^memVal_data) !== 1'bx))
                err(C_XZ, $sformatf("memVal_data=%h has X/Z while VALID_memVal=1", memVal_data));

        // ---- ready outputs ---------------------------------------------
        exp_rdy_m = (m_phase == PH_FILL) && (m_acc < 64);
        exp_rdy_b = (m_phase == PH_DRAIN);
        if (!ok(C_F5, RDY_mult === exp_rdy_m))
            err(C_F5, $sformatf("RDY_mult=%b expected %b (phase=%0d [0 fill,1 drain] accepted=%0d)", RDY_mult, exp_rdy_m,
                m_phase, m_acc));
        if (m_after_w63) begin
            if (!ok(C_F6, RDY_blockRead === 1'b1))
                err(C_F6, $sformatf("RDY_blockRead=%b in the cycle after the write of address 63, expected 1", RDY_blockRead));
        end else if (m_after_r63) begin
            if (!ok(C_F10, RDY_blockRead === 1'b0 && RDY_mult === 1'b1))
                err(C_F10, $sformatf("after read of address 63: RDY_blockRead=%b RDY_mult=%b, expected 0 and 1", RDY_blockRead, RDY_mult));
        end else begin
            if (!ok(C_F6, RDY_blockRead === exp_rdy_b))
                err(C_F6, $sformatf("RDY_blockRead=%b expected %b (phase=%0d [0 fill,1 drain] writes=%0d reads=%0d)", RDY_blockRead, exp_rdy_b,
                    m_phase, m_wr, m_rd));
        end
        if (!ok(C_F12, !(RDY_mult === 1'b1 && RDY_blockRead === 1'b1)))
            err(C_F12, "RDY_mult and RDY_blockRead both 1");
        if (!ok(C_F13, !(EN_writeMem === 1'b1 && EN_readMem === 1'b1)))
            err(C_F13, "EN_writeMem and EN_readMem both 1");

        acc    = (EN_mult === 1'b1) && exp_rdy_m;
        rd_acc = (EN_blockRead === 1'b1) && exp_rdy_b;
        if (EN_mult === 1'b1 && !exp_rdy_m)
            if (!ok(C_F5, RDY_mult === 1'b0)) err(C_F5, "EN_mult=1 while RDY_mult should be 0: DUT is ready");

        // ---- write side (F1..F4) ----------------------------------------
        exp_wr = 0;
        if (lat < 0) begin
            if (EN_writeMem === 1'b1) begin
                if (f_tail != f_head) begin
                    lat = int'(cyc - f_cyc[f_head % 128]);
                    $display("INFO t=%0t: latency learned from first product = %0d cycles", $realtime, lat);
                    if (!ok(C_F3, lat >= 0 && lat <= LMAX))
                        err(C_F3, $sformatf("latency %0d outside 0..%0d", lat, LMAX));
                    exp_wr = 1;
                end
            end else if (f_tail != f_head && (cyc - f_cyc[f_head % 128]) > LMAX) begin
                void'(ok(C_F3, 0));
                err(C_F3, $sformatf("no product written within %0d cycles of the first accept; stopping", LMAX));
                finish_sim();
            end
        end else begin
            exp_wr = (f_tail != f_head) && (f_cyc[f_head % 128] + lat == cyc);
        end

        if (exp_wr) begin
            if (!ok(C_F3, EN_writeMem === 1'b1))
                err(C_F3, $sformatf("missing write of product #%0d (accepted at cycle %0d, latency %0d)",
                    m_wr, f_cyc[f_head % 128], lat));
            p = f_prod[f_head % 128];
            if (!ok(C_F2, writeMem_addr === m_wr[5:0]))
                err(C_F2, $sformatf("writeMem_addr=%0d expected %0d", writeMem_addr, m_wr));
            if (!ok(C_F1, writeMem_val === p))
                err(C_F1, $sformatf("writeMem_val=%h expected %h (write to address %0d)", writeMem_val, p, m_wr));
            m_mem[m_wr] = p;
            f_head++;
            m_wr++;
        end else begin
            if (!ok(C_F4, EN_writeMem === 1'b0))
                err(C_F4, $sformatf("EN_writeMem=%b with no product due (addr=%0d val=%h)", EN_writeMem, writeMem_addr, writeMem_val));
        end

        // ---- read side (F7..F9) ----------------------------------------
        if (rd_acc) begin
            if (!ok(C_F7, EN_readMem === 1'b1 && readMem_addr === m_rd[5:0]))
                err(C_F7, $sformatf("accepted read #%0d: EN_readMem=%b readMem_addr=%0d, expected 1 and %0d",
                    m_rd, EN_readMem, readMem_addr, m_rd));
        end else if (EN_blockRead === 1'b1) begin
            if (!ok(C_F9, EN_readMem === 1'b0))
                err(C_F9, "EN_blockRead=1 while RDY_blockRead should be 0 caused EN_readMem=1");
        end else begin
            if (!ok(C_F7, EN_readMem === 1'b0))
                err(C_F7, "EN_readMem=1 in a cycle without an accepted read");
        end

        if (!ok(C_F8, VALID_memVal === m_valid_exp))
            err(C_F8, $sformatf("VALID_memVal=%b expected %b", VALID_memVal, m_valid_exp));
        if (m_valid_exp) begin
            if (!ok(C_F8, memVal_data === readMem_val))
                err(C_F8, $sformatf("memVal_data=%h differs from readMem_val=%h", memVal_data, readMem_val));
            if (!ok(C_DATA, memVal_data === m_valid_data))
                err(C_DATA, $sformatf("memVal_data=%h expected product %h (%0d) for address %0d",
                    memVal_data, m_valid_data, $signed(m_valid_data), m_valid_addr));
            else
                m_ret++;
            total_ret++;
            if (m_valid_addr == 63) begin
                if (!ok(C_F11, m_ret == 64))
                    err(C_F11, $sformatf("only %0d of 64 products returned correctly in this drain", m_ret));
                m_ret = 0;
            end
        end

        // ---- model update for the next cycle -----------------------------
        m_post_reset = 0;
        m_after_w63  = 0;
        m_after_r63  = 0;
        m_valid_exp  = rd_acc;
        if (rd_acc) begin
            m_valid_data = m_mem[m_rd];
            m_valid_addr = m_rd;
            m_rd++;
            if (m_rd == 64) begin
                m_phase = PH_FILL; m_acc = 0; m_wr = 0; m_rd = 0;
                m_after_r63 = 1;
                phases_done++;
                $display("INFO t=%0t: fill/drain phase %0d complete", $realtime, phases_done);
            end
        end
        if (acc) begin
            f_cyc[f_tail % 128]  = cyc;
            f_prod[f_tail % 128] = ref_prod(mult_input0, mult_input1);
            f_tail++;
            m_acc++;
            total_acc++;
        end
        if (exp_wr && m_wr == 64) begin
            m_phase = PH_DRAIN; m_rd = 0; m_ret = 0;
            m_after_w63 = 1;
        end
    endtask

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    task automatic finish_sim();
        int c;
        $display("");
        $display("==== mkMultBuff_tb summary (seed=%0d, period=%0.3f ns, latency=%0d, cycles=%0d) ====",
                 seed0, 2.0 * CLK_HALF_NS, lat, cyc);
        $display("  fill/drain phases completed: %0d, products accepted: %0d, returned: %0d",
                 phases_done, total_acc, total_ret);
        for (c = 1; c < NCAT; c++)
            if (cat_name(c) != "?")
                $display("  %-8s checks=%8d  failures=%0d", cat_name(c), n_chk[c], n_fail[c]);
        if (total_fail == 0)
            $display("ALL PASS");
        else
            $display("FAIL %0d check(s) failed", total_fail);
        $finish;
    endtask

    // Watchdog
    initial begin
        #(2.0 * CLK_HALF_NS * (MAX_CYCLES + 1000) * 1ns);
        void'(ok(C_WDOG, 0));
        err(C_WDOG, "simulation timeout");
        finish_sim();
    end

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    // Configuration of the running phase
    int  cfg_fill_pct, cfg_drain_pct;   // EN density while ready
    int  cfg_junk_pct;                  // EN density while not ready
    int  cfg_stall_pct;                 // chance per cycle of starting a stall burst
    bit  cfg_pwr;                       // power-window phase
    bit  cfg_directed;                  // start the fill with the directed pairs
    int  cfg_rst_acc;                   // reset when this many accepted (-1: off)
    bit  cfg_rst_full;                  // reset when 64 accepted and writes still pending
    int  cfg_rst_rd;                    // reset when this many reads accepted (-1: off)
    int  cfg_rst_len;
    int  stall_m, stall_b, dir_idx;
    realtime cyc_start;
    realtime pwr_fill_start, pwr_drain_start;
    int  pwr_fill_cnt, pwr_drain_cnt;
    bit  pwr_fill_done, pwr_drain_done;
    int  period_ps;

    function automatic longint ps(input realtime t);
        return longint'($rtoi(t * 1000.0 + 0.5));
    endfunction

    task automatic next_cycle();
        @(posedge clk);
        cyc++;
        cyc_start = $realtime;
        if (cyc > MAX_CYCLES) begin
            void'(ok(C_WDOG, 0));
            err(C_WDOG, "cycle limit reached");
            finish_sim();
        end
        #(DRV_DLY_NS * 1ns);
    endtask

    task automatic sample();
        @(negedge clk);
        check_cycle();
    endtask

    task automatic do_reset(input int ncyc, input string why);
        int i;
        $display("INFO t=%0t: applying reset for %0d cycle(s) (%s; model accepted=%0d written=%0d read=%0d)",
                 $realtime, ncyc, why, m_acc, m_wr, m_rd);
        for (i = 0; i < ncyc; i++) begin
            if (i > 0) next_cycle();
            RST_N = 0;
            EN_mult = 0;
            EN_blockRead = 0;
            mult_input0 = rnd();
            mult_input1 = rnd();
            sample();
        end
    endtask

    // Drive the inputs of one cycle (model state is the one valid for this cycle).
    task automatic drive();
        bit rdy_m, rdy_b;
        rdy_m = m_active && m_phase == PH_FILL && m_acc < 64;
        rdy_b = m_active && m_phase == PH_DRAIN;
        RST_N = 1;

        // ---- producer ----
        if (cfg_pwr && !pwr_drain_done && (m_phase == PH_DRAIN || (m_phase == PH_FILL && m_acc == 64))) begin
            EN_mult = 0;                               // quiet producer: hold operands
        end else if (rdy_m) begin
            if (stall_m > 0) begin
                stall_m--; EN_mult = 0;
            end else if (!cfg_pwr && chance(cfg_stall_pct)) begin
                stall_m = 2 + rnd() % 12; EN_mult = 0;
            end else
                EN_mult = cfg_pwr ? 1'b1 : chance(cfg_fill_pct);
            if (EN_mult && cfg_directed && dir_idx < NDIR) begin
                mult_input0 = dir_a[dir_idx]; mult_input1 = dir_b[dir_idx]; dir_idx++;
            end else if (EN_mult && chance(4)) begin
                int j; j = rnd() % NDIR;
                mult_input0 = dir_a[j]; mult_input1 = dir_b[j];
            end else begin
                mult_input0 = rnd(); mult_input1 = rnd();
            end
            if (cfg_pwr && !pwr_fill_done && m_acc == 0) pwr_fill_start = cyc_start;
        end else begin
            EN_mult = cfg_pwr ? 1'b0 : chance(cfg_junk_pct);
            mult_input0 = rnd(); mult_input1 = rnd();
        end

        // ---- consumer ----
        if (rdy_b) begin
            if (cfg_pwr) begin
                EN_blockRead = 1;
                if (!pwr_drain_done && m_rd == 0) pwr_drain_start = cyc_start;
            end else if (stall_b > 0) begin
                stall_b--; EN_blockRead = 0;
            end else if (chance(cfg_stall_pct)) begin
                stall_b = 2 + rnd() % 12; EN_blockRead = 0;
            end else
                EN_blockRead = chance(cfg_drain_pct);
        end else begin
            EN_blockRead = cfg_pwr ? 1'b0 : chance(cfg_junk_pct);
        end
    endtask

    // Track the power windows (called after sample()).
    task automatic track_pwr(input bit was_acc, input bit was_rd);
        if (cfg_pwr && !pwr_fill_done) begin
            if (was_acc) pwr_fill_cnt++;
            else if (pwr_fill_cnt > 0) begin
                void'(ok(C_STIM, 0)); err(C_STIM, "power fill window not back-to-back");
            end
            if (pwr_fill_cnt == 64) begin
                pwr_fill_done = 1;
                $display("PWR_WIN fill %0d %0d", ps(pwr_fill_start), ps(pwr_fill_start) + 64 * period_ps);
            end
        end
        if (cfg_pwr && !pwr_drain_done) begin
            if (was_rd) pwr_drain_cnt++;
            if (pwr_drain_cnt == 64) begin
                pwr_drain_done = 1;
                $display("PWR_WIN drain %0d %0d", ps(pwr_drain_start), ps(pwr_drain_start) + 64 * period_ps);
            end
        end
    endtask

    // Run cycles until the model completes one more fill/drain phase.
    task automatic run_phase(input int fill_pct, input int drain_pct, input int junk_pct,
                             input int stall_pct, input bit pwr, input bit directed,
                             input int rst_acc, input bit rst_full, input int rst_rd);
        int target;
        bit was_acc, was_rd;
        cfg_fill_pct = fill_pct; cfg_drain_pct = drain_pct; cfg_junk_pct = junk_pct;
        cfg_stall_pct = stall_pct; cfg_pwr = pwr; cfg_directed = directed;
        cfg_rst_acc = rst_acc; cfg_rst_full = rst_full; cfg_rst_rd = rst_rd;
        dir_idx = 0; stall_m = 0; stall_b = 0;
        target = phases_done + 1;
        $write("INFO t=%0t: phase %0d: fill %0d%%, drain %0d%%, junk %0d%%, stalls %0d%%",
               $realtime, target, fill_pct, drain_pct, junk_pct, stall_pct);
        if (pwr)        $write(", POWER WINDOWS");
        if (directed)   $write(", directed operands");
        if (rst_acc >= 0) $write(", reset mid-fill");
        if (rst_full)   $write(", reset when full");
        if (rst_rd >= 0) $write(", reset mid-drain");
        $write("\n");
        while (phases_done < target) begin
            next_cycle();
            if (cfg_rst_acc >= 0 && m_phase == PH_FILL && m_acc >= cfg_rst_acc && f_tail != f_head) begin
                cfg_rst_acc = -1;
                do_reset(1, "mid-fill, products in flight");
            end else if (cfg_rst_full && m_phase == PH_FILL && m_acc == 64 && f_tail != f_head) begin
                cfg_rst_full = 0;
                do_reset(1, "all 64 accepted, writes pending");
            end else if (cfg_rst_rd >= 0 && m_phase == PH_DRAIN && m_rd >= cfg_rst_rd && m_valid_exp) begin
                cfg_rst_rd = -1;
                do_reset(2, "mid-drain, read data pending");
            end else begin
                drive();
                was_acc = (EN_mult === 1'b1) && m_phase == PH_FILL && m_acc < 64;
                was_rd  = (EN_blockRead === 1'b1) && m_phase == PH_DRAIN;
                sample();
                track_pwr(was_acc, was_rd);
            end
        end
    endtask

    initial begin
        int i, ph;
        int dens [6];
        dens[0] = 10; dens[1] = 25; dens[2] = 50; dens[3] = 75; dens[4] = 95; dens[5] = 100;

        seed = 402;
        void'($value$plusargs("seed=%d", seed));
        seed0 = seed;
        period_ps = $rtoi(2.0 * CLK_HALF_NS * 1000.0 + 0.5);
        lat = -1; cyc = 0; total_fail = 0; phases_done = 0; total_acc = 0; total_ret = 0;
        m_active = 0; m_post_reset = 0;
        model_reset();
        for (i = 0; i < NCAT; i++) begin n_chk[i] = 0; n_fail[i] = 0; end

        RST_N = 0; EN_mult = 0; EN_blockRead = 0; mult_input0 = 0; mult_input1 = 0;
        $timeformat(-12, 0, " ps", 0);
        $display("INFO: mkMultBuff_tb seed=%0d period=%0.3f ns", seed, 2.0 * CLK_HALF_NS);

        // Initial reset: 3 cycles.
        @(posedge clk); cyc++; #(DRV_DLY_NS * 1ns);
        do_reset(3, "power-on");

        //        fill drain junk stall pwr dir rst_acc full rst_rd
        run_phase( 70,  70,  50,   2,  0,  1,   -1,   0,  -1);   // 1: directed pairs, random stalls
        run_phase(100, 100,   0,   0,  1,  0,   -1,   0,  -1);   // 2: power windows (back-to-back)
        run_phase( 30,  30,  60,   0,  0,  0,   -1,   0,  -1);   // 3: sparse traffic
        run_phase(100,  50,  50,   0,  0,  0,   40,   0,  -1);   // 4: reset mid-fill (in flight)
        run_phase( 90,  60,  50,   3,  0,  1,   -1,   0,  20);   // 5: reset mid-drain
        run_phase(100, 100, 100,   0,  0,  0,   -1,   1,  -1);   // 6: reset when full, writes pending
        for (ph = 0; ph < NPHASES - 6; ph++)
            run_phase(dens[(ph + 2) % 6], dens[(ph * 5 + 1) % 6], 50, (ph % 3) * 2, 0, ph == 3, -1, 0, -1);

        // Idle tail: nothing may happen.
        cfg_fill_pct = 0; cfg_drain_pct = 0; cfg_junk_pct = 0; cfg_stall_pct = 0; cfg_pwr = 0;
        for (i = 0; i < 2 * LMAX; i++) begin
            next_cycle();
            RST_N = 1; EN_mult = 0; EN_blockRead = chance(50); mult_input0 = rnd(); mult_input1 = rnd();
            sample();
        end

        if (!ok(C_PHASES, phases_done >= 8 && phases_done == NPHASES))
            err(C_PHASES, $sformatf("%0d complete fill/drain phases, expected %0d", phases_done, NPHASES));
        if (!ok(C_PHASES, pwr_fill_done && pwr_drain_done))
            err(C_PHASES, "power windows not completed");
        finish_sim();
    end

endmodule
