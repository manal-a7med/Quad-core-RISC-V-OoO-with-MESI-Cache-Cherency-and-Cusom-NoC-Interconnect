`timescale 1ns / 1ps
`define SIM

`include "common_defs.vh"

// =============================================================================
//  Testbench: OoO Core — Comprehensive Cases & Corner-Case Suite
// =============================================================================
//  Tests 8 distinct architectural and microarchitectural corner-case categories:
//    1) Negative immediates & sign-extension arithmetic (ADDI -4, ADD, SUB < 0)
//    2) Signed vs. Unsigned comparison corner case (SLT vs. SLTU on negative)
//    3) Logical vs. Arithmetic right shift on negative (SRLI vs. SRAI)
//    4) Hardwired x0 corner case (explicit non-zero ADD to x0 must stay 0)
//    5) WAW (Write-After-Write) & WAR (Write-After-Read) hazard renaming
//    6) Out-of-Order execution bypass (independent SLL bypasses stalled chain)
//    7) Store-to-Load Forwarding & load-use RAW hazard (SW -> LW -> ADD)
//    8) Branch resolution: Not-Taken (BNE) + Taken (BEQ) with speculative
//       instruction flush recovery + LUI upper-immediate + ROB wrap-around
// =============================================================================

`define ARCH_REG(i) dut.u_regfile.regs[dut.u_rename.arch_rat[i]]

module tb_ooo_corner_cases;

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
    //  Instruction Memory (27 instructions across 8 corner-case categories)
    // =========================================================================
    always @(*) begin
        icache_ack = icache_req;
        case (icache_addr)
            // --- Category 1: Negative Immediates & Signed Arithmetic ---
            32'h00: icache_rdata = 32'h00F00093; // ADDI x1,  x0,  15     -> x1  = 15
            32'h04: icache_rdata = 32'hFFC00113; // ADDI x2,  x0,  -4     -> x2  = -4 (0xFFFFFFFC)
            32'h08: icache_rdata = 32'h002081B3; // ADD  x3,  x1,  x2     -> x3  = 11
            32'h0C: icache_rdata = 32'h40110233; // SUB  x4,  x2,  x1     -> x4  = -19 (0xFFFFFFED)

            // --- Category 2: Signed vs. Unsigned Comparison on Negative ---
            32'h10: icache_rdata = 32'h001122B3; // SLT  x5,  x2,  x1     -> x5  = 1 (-4 < 15 signed)
            32'h14: icache_rdata = 32'h00113333; // SLTU x6,  x2,  x1     -> x6  = 0 (0xFFFFFFFC < 15 unsigned)

            // --- Category 3: Logical vs. Arithmetic Shift Right on Negative ---
            32'h18: icache_rdata = 32'h00215393; // SRLI x7,  x2,  2      -> x7  = 0x3FFFFFFF
            32'h1C: icache_rdata = 32'h40215413; // SRAI x8,  x2,  2      -> x8  = 0xFFFFFFFF (-1)

            // --- Category 4: Hardwired x0 Protection ---
            32'h20: icache_rdata = 32'h00308033; // ADD  x0,  x1,  x3     -> x0  = 0 (write ignored!)
            32'h24: icache_rdata = 32'h003004B3; // ADD  x9,  x0,  x3     -> x9  = 11

            // --- Category 5: WAW & WAR Register Renaming Hazards ---
            32'h28: icache_rdata = 32'h06300513; // ADDI x10, x0,  99     -> x10 = 99 (WAW older write)
            32'h2C: icache_rdata = 32'h02A00513; // ADDI x10, x0,  42     -> x10 = 42 (WAW newer write)
            32'h30: icache_rdata = 32'h003505B3; // ADD  x11, x10, x3     -> x11 = 42 + 11 = 53
            32'h34: icache_rdata = 32'h04D00513; // ADDI x10, x0,  77     -> x10 = 77 (WAR overwrite after x11 read)

            // --- Category 6: Out-of-Order Execution Bypass ---
            32'h38: icache_rdata = 32'h0015C633; // XOR  x12, x11, x1     -> x12 = 53 ^ 15 = 58
            32'h3C: icache_rdata = 32'h008666B3; // OR   x13, x12, x8     -> x13 = 0xFFFFFFFF (-1)
            32'h40: icache_rdata = 32'h00167733; // AND  x14, x12, x1     -> x14 = 58 & 15 = 10
            32'h44: icache_rdata = 32'h005197B3; // SLL  x15, x3,  x5     -> x15 = 11 << 1 = 22 (executes OoO!)

            // --- Category 7: Store-to-Load Forwarding & Load-Use RAW ---
            32'h48: icache_rdata = 32'h00F02423; // SW   x15, 8(x0)       -> Mem[8] = 22
            32'h4C: icache_rdata = 32'h00802803; // LW   x16, 8(x0)       -> x16 = 22 (forwarded from SW!)
            32'h50: icache_rdata = 32'h00E808B3; // ADD  x17, x16, x14    -> x17 = 22 + 10 = 32

            // --- Category 8: Branch Not-Taken, Branch Taken + Speculative Flush, LUI ---
            32'h54: icache_rdata = 32'h00109463; // BNE  x1,  x1,  +8     -> Not taken!
            32'h58: icache_rdata = 32'h01900913; // ADDI x18, x0,  25     -> x18 = 25
            32'h5C: icache_rdata = 32'h00108463; // BEQ  x1,  x1,  +8     -> Taken! Jumps to 0x64, flushes 0x60
            32'h60: icache_rdata = 32'h3E700913; // ADDI x18, x0,  999    -> FLUSHED speculative instruction!
            32'h64: icache_rdata = 32'h123459B7; // LUI  x19, 0x12345     -> x19 = 0x12345000
            32'h68: icache_rdata = 32'h01190A33; // ADD  x20, x18, x17    -> x20 = 25 + 32 = 57
            default: icache_rdata = 32'h00000013; // NOP
        endcase
    end

    // =========================================================================
    //  Data Memory Model (256 words)
    // =========================================================================
    reg [31:0] dmem [0:255];
    integer    mi;

    always @(posedge clk) begin
        if (!rst_n) begin
            dcache_ack   <= 0;
            dcache_rdata <= 0;
            for (mi = 0; mi < 256; mi = mi + 1) dmem[mi] <= 32'd0;
        end else if (dcache_req) begin
            dcache_ack <= 1;
            if (dcache_wr) begin
                dmem[dcache_addr[9:2]] <= dcache_wdata;
                $display("[T=%0t] DMEM WRITE  addr=0x%02h  data=%0d (0x%08h)",
                         $time, dcache_addr, dcache_wdata, dcache_wdata);
            end else begin
                dcache_rdata <= dmem[dcache_addr[9:2]];
                $display("[T=%0t] DMEM READ   addr=0x%02h  data=%0d (0x%08h)",
                         $time, dcache_addr, dmem[dcache_addr[9:2]], dmem[dcache_addr[9:2]]);
            end
        end else begin
            dcache_ack <= 0;
        end
    end

    // =========================================================================
    //  Monitors
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && dut.cdb_valid && dut.cdb_phys_rd != 6'd0)
            $display("[T=%0t] CDB         phys_reg[%0d] = %0d (0x%08h)",
                     $time, dut.cdb_phys_rd, $signed(dut.cdb_data), dut.cdb_data);
    end

    always @(posedge clk) begin
        if (rst_n && dut.rob_commit_valid) begin
            if (dut.rob_flush_out)
                $display("[T=%0t] COMMIT+FLUSH branch mispredicted -> redirect PC=0x%02h",
                         $time, dut.rob_flush_redirect_pc);
            else
                $display("[T=%0t] COMMIT      arch_rd=x%0d",
                         $time, dut.rob_commit_arch_rd);
        end
    end

    // =========================================================================
    //  Self-Checking Scoreboard
    // =========================================================================
    reg [31:0] exp_reg [0:20];
    reg [8*42:1] desc  [0:20];
    integer    commit_count;
    integer    flush_count;
    integer    ooo_sll_before_and;
    reg        and_x14_done;
    integer    pass_cnt, fail_cnt;
    integer    r;
    reg [31:0] act;

    initial begin
        exp_reg[0]  = 32'h00000000; desc[0]  = "Hardwired zero (ADD x0, x1, x3 ignored)";
        exp_reg[1]  = 32'd15;       desc[1]  = "ADDI +15";
        exp_reg[2]  = 32'hFFFFFFFC; desc[2]  = "ADDI -4 (sign-extended negative imm)";
        exp_reg[3]  = 32'd11;       desc[3]  = "ADD 15 + (-4) = 11";
        exp_reg[4]  = 32'hFFFFFFED; desc[4]  = "SUB -4 - 15 = -19";
        exp_reg[5]  = 32'd1;        desc[5]  = "SLT signed (-4 < 15) = 1";
        exp_reg[6]  = 32'd0;        desc[6]  = "SLTU unsigned (0xFFFFFFFC < 15) = 0";
        exp_reg[7]  = 32'h3FFFFFFF; desc[7]  = "SRLI logical shift (-4 >> 2)";
        exp_reg[8]  = 32'hFFFFFFFF; desc[8]  = "SRAI arithmetic shift (-4 >>> 2 = -1)";
        exp_reg[9]  = 32'd11;       desc[9]  = "ADD x0 + x3 = 11 (after write to x0)";
        exp_reg[10] = 32'd77;       desc[10] = "WAW+WAR final value of x10 = 77";
        exp_reg[11] = 32'd53;       desc[11] = "WAR reader got old x10 (42) + 11 = 53";
        exp_reg[12] = 32'd58;       desc[12] = "XOR 53 ^ 15 = 58";
        exp_reg[13] = 32'hFFFFFFFF; desc[13] = "OR 58 | (-1) = -1";
        exp_reg[14] = 32'd10;       desc[14] = "AND 58 & 15 = 10";
        exp_reg[15] = 32'd22;       desc[15] = "SLL 11 << 1 = 22 (OoO bypass)";
        exp_reg[16] = 32'd22;       desc[16] = "LW 8(x0) = 22 (Store-to-Load fwd)";
        exp_reg[17] = 32'd32;       desc[17] = "ADD x16 + x14 = 32 (Load-use RAW)";
        exp_reg[18] = 32'd25;       desc[18] = "ADDI 25 (flushed 999 did not corrupt)";
        exp_reg[19] = 32'h12345000; desc[19] = "LUI 0x12345 at branch target";
        exp_reg[20] = 32'd57;       desc[20] = "ADD x18 + x17 = 57 after branch flush";

        commit_count       = 0;
        flush_count        = 0;
        ooo_sll_before_and = 0;
        and_x14_done       = 0;
        pass_cnt           = 0;
        fail_cnt           = 0;
    end

    // Track OoO execution order & commits/flushes
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.cdb_valid && dut.cdb_data == 32'd10 && dut.cdb_phys_rd != 6'd0)
                and_x14_done <= 1'b1;
            if (dut.cdb_valid && dut.cdb_data == 32'd22 && !and_x14_done)
                ooo_sll_before_and <= 1;
            if (dut.rob_commit_valid)
                commit_count <= commit_count + 1;
            if (dut.rob_flush_out)
                flush_count <= flush_count + 1;
        end
    end

    task check_cond;
        input        cond;
        input [8*65:1] name;
    begin
        if (cond) begin
            pass_cnt = pass_cnt + 1;
            $display(" [PASS] %0s", name);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display(" [FAIL] %0s", name);
        end
    end
    endtask

    initial begin
        $dumpfile("corner_cases.vcd");
        $dumpvars(0, tb_ooo_corner_cases);

        clk = 0; rst_n = 0;
        icache_rdata = 32'h00000013;
        icache_ack = 0;
        dcache_rdata = 0;
        dcache_ack = 0;

        $display("================================================================================");
        $display(" RISC-V OoO Core — Comprehensive Corner-Case Verification Suite");
        $display("================================================================================");

        #20 rst_n = 1;
        #4000;

        $display("");
        $display("================================================================================");
        $display(" ARCHITECTURAL REGISTER FILE VERIFICATION (x0 .. x20)");
        $display("================================================================================");
        $display(" Reg | Expected   | Actual     | Corner Case Verified                          | Status");
        $display(" ----+------------+------------+-----------------------------------------------+-------");

        for (r = 0; r <= 20; r = r + 1) begin
            act = (r == 0) ? dut.u_regfile.regs[0] : `ARCH_REG(r);
            if (act === exp_reg[r]) begin
                pass_cnt = pass_cnt + 1;
                $display(" x%-2d | 0x%08h | 0x%08h | %-45s | PASS", r, exp_reg[r], act, desc[r]);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display(" x%-2d | 0x%08h | 0x%08h | %-45s | FAIL", r, exp_reg[r], act, desc[r]);
            end
        end

        $display("");
        $display("================================================================================");
        $display(" MICROARCHITECTURAL CORNER-CASE CHECKS");
        $display("================================================================================");
        check_cond(ooo_sll_before_and == 1,     "Out-of-Order bypass: SLL x15 executed before older AND x14");
        check_cond(dmem[2] === 32'd22,          "Store commit: SW x15, 8(x0) wrote 22 to Data Memory[2]");
        check_cond(flush_count == 1,            "Branch prediction: Taken BEQ triggered exactly 1 ROB flush");
        check_cond(`ARCH_REG(18) === 32'd25,    "Speculative recovery: Flushed ADDI x18, 999 rolled back");
        check_cond(commit_count == 26,          "ROB wrap-around: All 26 non-flushed instructions committed");

        $display("--------------------------------------------------------------------------------");
        $display(" TOTAL: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display(" *** ALL CORNER CASES PASSED ***");
        else               $display(" *** SOME CHECKS FAILED ***");
        $display("================================================================================");
        $finish;
    end

endmodule
