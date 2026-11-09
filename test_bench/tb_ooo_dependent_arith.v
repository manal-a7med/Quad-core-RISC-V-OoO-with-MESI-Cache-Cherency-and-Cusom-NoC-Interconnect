`timescale 1ns / 1ps
`define SIM

`include "common_defs.vh"

// =============================================================================
//  Testbench: OoO Core - Dependent Arithmetic Chain (self-checking)
//
//  Addr  Hex         Assembly              Result
//  0x00  00700093    ADDI x1,  x0,  7      x1  = 7
//  0x04  00300113    ADDI x2,  x0,  3      x2  = 3
//  0x08  002081B3    ADD  x3,  x1,  x2     x3  = 10
//  0x0C  40118233    SUB  x4,  x3,  x1     x4  = 3
//  0x10  0041F2B3    AND  x5,  x3,  x4     x5  = 2
//  0x14  0022E333    OR   x6,  x5,  x2     x6  = 3
//  0x18  003343B3    XOR  x7,  x6,  x3     x7  = 9
//  0x1C  00209433    SLL  x8,  x1,  x2     x8  = 56
//  0x20  008384B3    ADD  x9,  x7,  x8     x9  = 65
//  0x24  40648533    SUB  x10, x9,  x6     x10 = 62
//  0x28  00A2A5B3    SLT  x11, x5,  x10    x11 = 1
//  0x2C  00B50633    ADD  x12, x10, x11    x12 = 63
//  0x30+ 00000013    NOP
//
//  Checks performed:
//    A) Commits retire in program order (x1..x12)
//    B) Every expected value appears on the CDB (duplicates handled, each
//       expected register consumes one CDB match)
//    C) Architectural register file == expected values (optional, see below)
// =============================================================================

// -----------------------------------------------------------------------------
//  OPTIONAL: real expected-vs-actual register file check.
//  1) Set ARCH_REG(i) to the path of your architectural register value, e.g.
//        dut.arch_regfile[i]
//        dut.u_prf.regs[dut.commit_rat[i]]
//  2) Uncomment `define CHECK_ARCH_REGFILE
//  Left disabled by default so the file compiles with any core.
// -----------------------------------------------------------------------------
`define ARCH_REG(i) dut.u_regfile.regs[dut.u_rename.rat[i]]
`define CHECK_ARCH_REGFILE

module tb_ooo_dependent_arith;

    reg         clk;
    reg         rst_n;

    // I-Cache interface
    wire [31:0] icache_addr;
    reg  [31:0] icache_rdata;
    wire        icache_req;
    reg         icache_ack;

    // D-Cache interface
    wire [31:0] dcache_addr;
    wire [31:0] dcache_wdata;
    reg  [31:0] dcache_rdata;
    wire        dcache_req;
    wire        dcache_wr;
    reg         dcache_ack;
    wire [2:0]  dcache_mem_type;

    // Core under test
    riscv_ooo_core dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .core_id        (2'b00),
        .icache_addr    (icache_addr),
        .icache_rdata   (icache_rdata),
        .icache_req     (icache_req),
        .icache_ack     (icache_ack),
        .dcache_addr    (dcache_addr),
        .dcache_wdata   (dcache_wdata),
        .dcache_rdata   (dcache_rdata),
        .dcache_req     (dcache_req),
        .dcache_wr      (dcache_wr),
        .dcache_ack     (dcache_ack),
        .dcache_mem_type(dcache_mem_type)
    );

    // 10 ns clock (100 MHz)
    always #5 clk = ~clk;

    // =========================================================================
    //  Instruction Memory
    // =========================================================================
    always @(*) begin
        icache_ack = icache_req;
        case (icache_addr)
            32'h00: icache_rdata = 32'h00700093; // ADDI x1, x0, 7
            32'h04: icache_rdata = 32'h00300113; // ADDI x2, x0, 3
            32'h08: icache_rdata = 32'h002081B3; // ADD  x3, x1, x2     -> 10
            32'h0C: icache_rdata = 32'h40118233; // SUB  x4, x3, x1     -> 3
            32'h10: icache_rdata = 32'h0041F2B3; // AND  x5, x3, x4     -> 2
            32'h14: icache_rdata = 32'h0022E333; // OR   x6, x5, x2     -> 3
            32'h18: icache_rdata = 32'h003343B3; // XOR  x7, x6, x3     -> 9
            32'h1C: icache_rdata = 32'h00209433; // SLL  x8, x1, x2     -> 56
            32'h20: icache_rdata = 32'h008384B3; // ADD  x9, x7, x8     -> 65
            32'h24: icache_rdata = 32'h40648533; // SUB  x10, x9, x6    -> 62
            32'h28: icache_rdata = 32'h00A2A5B3; // SLT  x11, x5, x10   -> 1
            32'h2C: icache_rdata = 32'h00B50633; // ADD  x12, x10, x11  -> 63
            default: icache_rdata = 32'h00000013; // NOP
        endcase
    end

    // =========================================================================
    //  Data Memory (unused in this test, connected for completeness)
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            dcache_ack   <= 0;
            dcache_rdata <= 0;
        end else if (dcache_req) begin
            dcache_ack   <= 1;
            dcache_rdata <= 32'd0;
        end else begin
            dcache_ack <= 0;
        end
    end

    // =========================================================================
    //  Monitors
    // =========================================================================
    reg [8*25:1] instr_name;
    always @(*) begin
        case (icache_addr)
            32'h00: instr_name = "ADDI x1, x0, 7";
            32'h04: instr_name = "ADDI x2, x0, 3";
            32'h08: instr_name = "ADD  x3, x1, x2";
            32'h0C: instr_name = "SUB  x4, x3, x1";
            32'h10: instr_name = "AND  x5, x3, x4";
            32'h14: instr_name = "OR   x6, x5, x2";
            32'h18: instr_name = "XOR  x7, x6, x3";
            32'h1C: instr_name = "SLL  x8, x1, x2";
            32'h20: instr_name = "ADD  x9, x7, x8";
            32'h24: instr_name = "SUB  x10, x9, x6";
            32'h28: instr_name = "SLT  x11, x5, x10";
            32'h2C: instr_name = "ADD  x12, x10, x11";
            default: instr_name = "NOP";
        endcase
    end

    always @(posedge clk) begin
        if (rst_n && icache_req && icache_ack && icache_addr <= 32'h2C)
            $display("[T=%0t] FETCH  PC=0x%02h  %0s", $time, icache_addr, instr_name);
    end

    always @(posedge clk) begin
        if (rst_n && dut.cdb_valid && dut.cdb_phys_rd != 6'd0)
            $display("[T=%0t] CDB    phys_reg[%0d] = %0d  (0x%08h)",
                     $time, dut.cdb_phys_rd, dut.cdb_data, dut.cdb_data);
    end

    always @(posedge clk) begin
        if (rst_n && dut.rob_commit_valid)
            $display("[T=%0t] COMMIT rob_head retired (arch_rd=x%0d)",
                     $time, dut.rob_commit_arch_rd);
    end

    // =========================================================================
    //  Self-checking scoreboard
    // =========================================================================
    integer    cycle_count;
    reg [31:0] exp_val  [1:12];   // expected value of x1..x12
    reg        cdb_seen [1:12];   // matched on CDB (one match per register)
    integer    commit_idx;        // number of commits seen
    integer    pass_cnt, fail_cnt;
    integer    k;                 // used only by initial block
    integer    j;                 // used only by CDB checker
    integer    r;                 // used only by report task
    reg        matched;
    reg [31:0] act;

    initial begin
        exp_val[1]  = 7;   exp_val[2]  = 3;   exp_val[3]  = 10;  exp_val[4]  = 3;
        exp_val[5]  = 2;   exp_val[6]  = 3;   exp_val[7]  = 9;   exp_val[8]  = 56;
        exp_val[9]  = 65;  exp_val[10] = 62;  exp_val[11] = 1;   exp_val[12] = 63;
        for (k = 1; k <= 12; k = k + 1) cdb_seen[k] = 0;
        commit_idx = 0; pass_cnt = 0; fail_cnt = 0;
    end

    // Check A: commits retire in program order
    always @(posedge clk) begin
        if (rst_n && dut.rob_commit_valid) begin
            commit_idx = commit_idx + 1;
            if (commit_idx <= 12) begin
                if (dut.rob_commit_arch_rd === commit_idx[4:0]) begin
                    $display("[CHECK] COMMIT #%0d  arch_rd=x%0d  expected x%0d  -> PASS",
                             commit_idx, dut.rob_commit_arch_rd, commit_idx);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("[CHECK] COMMIT #%0d  arch_rd=x%0d  expected x%0d  -> FAIL",
                             commit_idx, dut.rob_commit_arch_rd, commit_idx);
                    fail_cnt = fail_cnt + 1;
                end
            end
        end
    end

    // Check B: each CDB value claims the first unmatched register expecting it
    always @(posedge clk) begin
        if (rst_n && dut.cdb_valid && dut.cdb_phys_rd != 6'd0) begin
            matched = 0;
            for (j = 1; j <= 12; j = j + 1)
                if (!matched && !cdb_seen[j] && (dut.cdb_data === exp_val[j])) begin
                    cdb_seen[j] = 1;
                    matched = 1;
                end
        end
    end

    // Final report
    task report_results;
    begin
        $display("");
        $display("================================================================");
        $display(" VERIFICATION REPORT");
        $display("================================================================");
`ifdef CHECK_ARCH_REGFILE
        $display(" Reg | Expected | Actual   | On CDB | Result");
        $display(" ----+----------+----------+--------+-------");
`else
        $display(" Reg | Expected | On CDB | Result   (arch regfile check disabled)");
        $display(" ----+----------+--------+-------");
`endif
        for (r = 1; r <= 12; r = r + 1) begin
`ifdef CHECK_ARCH_REGFILE
            act = `ARCH_REG(r);
            if (act === exp_val[r]) begin
                pass_cnt = pass_cnt + 1;
                $display(" x%-2d | %8d | %8d | %-6s | PASS", r, exp_val[r], act,
                         cdb_seen[r] ? "yes" : "no");
            end else begin
                fail_cnt = fail_cnt + 1;
                $display(" x%-2d | %8d | %8d | %-6s | FAIL", r, exp_val[r], act,
                         cdb_seen[r] ? "yes" : "no");
            end
`else
            if (cdb_seen[r]) begin
                pass_cnt = pass_cnt + 1;
                $display(" x%-2d | %8d | yes    | PASS", r, exp_val[r]);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display(" x%-2d | %8d | no     | FAIL", r, exp_val[r]);
            end
`endif
        end
        if (commit_idx < 12) begin
            fail_cnt = fail_cnt + 1;
            $display(" Commit count: %0d (need >= 12) -> FAIL", commit_idx);
        end else begin
            pass_cnt = pass_cnt + 1;
            $display(" Commit count: %0d (need >= 12) -> PASS", commit_idx);
        end
        $display(" ----------------------------------------------------------");
        $display(" TOTAL: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display(" *** TEST PASSED ***");
        else               $display(" *** TEST FAILED ***");
        $display("================================================================");
    end
    endtask

    // =========================================================================
    //  Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("dependent_arith.vcd");
        $dumpvars(0, tb_ooo_dependent_arith);

        clk = 0; rst_n = 0;
        icache_rdata = 32'h00000013;
        icache_ack = 0;
        dcache_rdata = 0;
        dcache_ack = 0;
        cycle_count = 0;

        $display("================================================================");
        $display(" RISC-V OoO Core - Dependent Arithmetic Chain Test");
        $display("================================================================");
        $display(" Program: 12 instructions (2 immediates + 10 dependent R-type)");
        $display(" Expected: x1=7 x2=3 x3=10 x4=3 x5=2 x6=3 x7=9 x8=56 x9=65 x10=62 x11=1 x12=63");
        $display("================================================================");
        $display("");

        #20 rst_n = 1;

        // 3000 ns (300 cycles) is enough for the whole chain to commit
        #3000;

        report_results;

        $display("");
        $display(" Test Complete - %0d cycles executed", cycle_count);
        $display(" Inspect dependent_arith.vcd in GTKWave for CDB wakeups and ROB commits.");
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) cycle_count <= cycle_count + 1;
    end

endmodule