`timescale 1ns / 1ps
`define SIM

`include "common_defs.vh"
`include "mesi_defines.vh"

module tb_quad_core;
    reg         clk;
    reg         rst_n;
    wire [3:0]  core_active;
    wire        mem_busy;

    // Top-level SoC (includes 4x OoO cores, 4x L1I, 4x L1D, MESI bus, L2, and Main Memory)
    quad_core_top dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .core_active (core_active),
        .mem_busy    (mem_busy)
    );

    // 10ns clock period (100 MHz)
    always #5 clk = ~clk;

    // Performance and coherence event counters
    integer cycle_count;
    integer mem_access_count;
    integer bus_rd_count;
    integer bus_rdx_count;
    integer bus_upgr_count;
    integer bus_flush_count;
    integer snoop_hit_count;
    integer snoop_hitm_count;
    integer snoop_ack_count;
    integer l2_resp_count;

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count      <= 0;
            mem_access_count <= 0;
            bus_rd_count     <= 0;
            bus_rdx_count    <= 0;
            bus_upgr_count   <= 0;
            bus_flush_count  <= 0;
            snoop_hit_count  <= 0;
            snoop_hitm_count <= 0;
            snoop_ack_count  <= 0;
            l2_resp_count    <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (dut.mc_ack)
                mem_access_count <= mem_access_count + 1;

            if (dut.u_snoop.state == 3'b000 && dut.u_snoop.next_state != 3'b000) begin
                case (dut.sc_req_cmd)
                    `BUS_READ:  bus_rd_count    <= bus_rd_count + 1;
                    `BUS_READX: bus_rdx_count   <= bus_rdx_count + 1;
                    `BUS_UPGR:  bus_upgr_count  <= bus_upgr_count + 1;
                    `BUS_FLUSH: bus_flush_count <= bus_flush_count + 1;
                endcase
            end

            if (dut.u_snoop.state == 3'b010) begin // COLLECT_RESPONSES
                if (dut.u_snoop.hit)  snoop_hit_count  <= snoop_hit_count + 1;
                if (dut.u_snoop.hitm) snoop_hitm_count <= snoop_hitm_count + 1;
                if ((dut.sc_snoop_resp[1:0] == `SNOOP_ACK) ||
                    (dut.sc_snoop_resp[3:2] == `SNOOP_ACK) ||
                    (dut.sc_snoop_resp[5:4] == `SNOOP_ACK) ||
                    (dut.sc_snoop_resp[7:6] == `SNOOP_ACK))
                    snoop_ack_count <= snoop_ack_count + 1;
            end

            if (dut.l2_resp_valid)
                l2_resp_count <= l2_resp_count + 1;
        end
    end

    // Helper functions to read each core's architectural register values
    function [31:0] get_core_reg;
        input integer c;
        input [4:0]   arch_r;
        reg   [5:0]   phys_r;
        begin
            case (c)
                0: begin
                    phys_r = dut.core_gen[0].u_core.u_rename.arch_rat[arch_r];
                    get_core_reg = (phys_r == 6'd0) ? 32'd0 : dut.core_gen[0].u_core.u_regfile.regs[phys_r];
                end
                1: begin
                    phys_r = dut.core_gen[1].u_core.u_rename.arch_rat[arch_r];
                    get_core_reg = (phys_r == 6'd0) ? 32'd0 : dut.core_gen[1].u_core.u_regfile.regs[phys_r];
                end
                2: begin
                    phys_r = dut.core_gen[2].u_core.u_rename.arch_rat[arch_r];
                    get_core_reg = (phys_r == 6'd0) ? 32'd0 : dut.core_gen[2].u_core.u_regfile.regs[phys_r];
                end
                default: begin
                    phys_r = dut.core_gen[3].u_core.u_rename.arch_rat[arch_r];
                    get_core_reg = (phys_r == 6'd0) ? 32'd0 : dut.core_gen[3].u_core.u_regfile.regs[phys_r];
                end
            endcase
        end
    endfunction

    integer pass_count = 0;
    integer fail_count = 0;
    integer c, r;
    reg [31:0] exp_val [1:12];
    reg [31:0] act_val;

    initial begin
        $dumpfile("quad_core.vcd");
        $dumpvars(0, tb_quad_core);

        clk   = 0;
        rst_n = 0;

        // Expected architectural register values for all 4 cores
        exp_val[1]  = 32'd42;  // LW   x1,  0x100(x0)
        exp_val[2]  = 32'd10;  // LW   x2,  0x104(x0)
        exp_val[3]  = 32'd52;  // ADD  x3,  x1, x2
        exp_val[4]  = 32'd32;  // SUB  x4,  x1, x2
        exp_val[5]  = 32'd60;  // ADDI x5,  x3, 8
        exp_val[6]  = 32'd60;  // LW   x6,  0x108(x0) (after SW x5, 0x108(x0))
        exp_val[7]  = 32'd52;  // LW   x7,  0x120(x0) (after SW x3, 0x120(x0))
        exp_val[8]  = 32'd112; // ADD  x8,  x6, x7
        exp_val[9]  = 32'd80;  // XOR  x9,  x8, x4
        exp_val[10] = 32'd90;  // OR   x10, x9, x2
        exp_val[11] = 32'd1;   // SLT  x11, x4, x3
        exp_val[12] = 32'd91;  // ADD  x12, x10, x11

        // Initialize Main Memory with instructions and shared data
        #1;
        // Instructions at 0x0000_0000 .. 0x0000_0034
        dut.u_mem.mem[0]  = 32'h10002083; // 0x00: LW   x1,  256(x0)  [0x100] -> 42
        dut.u_mem.mem[1]  = 32'h10402103; // 0x04: LW   x2,  260(x0)  [0x104] -> 10
        dut.u_mem.mem[2]  = 32'h002081B3; // 0x08: ADD  x3,  x1, x2           -> 52
        dut.u_mem.mem[3]  = 32'h40208233; // 0x0C: SUB  x4,  x1, x2           -> 32
        dut.u_mem.mem[4]  = 32'h00818293; // 0x10: ADDI x5,  x3, 8            -> 60
        dut.u_mem.mem[5]  = 32'h10502423; // 0x14: SW   x5,  264(x0)  [0x108] <= 60
        dut.u_mem.mem[6]  = 32'h12302023; // 0x18: SW   x3,  288(x0)  [0x120] <= 52
        dut.u_mem.mem[7]  = 32'h10802303; // 0x1C: LW   x6,  264(x0)  [0x108] -> 60
        dut.u_mem.mem[8]  = 32'h12002383; // 0x20: LW   x7,  288(x0)  [0x120] -> 52
        dut.u_mem.mem[9]  = 32'h00730433; // 0x24: ADD  x8,  x6, x7           -> 112
        dut.u_mem.mem[10] = 32'h004444B3; // 0x28: XOR  x9,  x8, x4           -> 80
        dut.u_mem.mem[11] = 32'h0024E533; // 0x2C: OR   x10, x9, x2           -> 90
        dut.u_mem.mem[12] = 32'h003225B3; // 0x30: SLT  x11, x4, x3           -> 1
        dut.u_mem.mem[13] = 32'h00B50633; // 0x34: ADD  x12, x10, x11         -> 91

        // Shared Data in Main Memory at 0x0000_0100 (word index 64)
        dut.u_mem.mem[64] = 32'd42;       // 0x0100 = 42
        dut.u_mem.mem[65] = 32'd10;       // 0x0104 = 10
        dut.u_mem.mem[66] = 32'd0;        // 0x0108 = 0 (will be written to 60)
        dut.u_mem.mem[72] = 32'd0;        // 0x0120 = 0 (will be written to 52)

        $display("============================================================================");
        $display(" Quad-Core RISC-V OoO SoC — Full System & MESI Coherence Verification");
        $display("============================================================================");
        $display(" Architecture: 4x RV32I OoO cores, MESI Snoop Coherence Bus");
        $display(" Cache:        4KB L1I + 4KB L1D per core, 16KB 4-way shared L2");
        $display(" Memory:       64KB Main Memory via Memory Controller & Arbiter");
        $display("============================================================================");

        #29 rst_n = 1;
        $display("[T=%0t] Reset released — all 4 cores executing program", $time);

        // Run for 800 cycles so all 4 cores complete all instruction fetches,
        // L1D/L2 misses, MESI upgrades, cache-to-cache transfers, and ROB commits
        #8000;

        $display("");
        $display("============================================================================");
        $display(" PER-CORE ARCHITECTURAL REGISTER VERIFICATION (Cores 0..3, x1..x12)");
        $display("============================================================================");
        for (c = 0; c < 4; c = c + 1) begin
            $display(" --- Core %0d ---", c);
            for (r = 1; r <= 12; r = r + 1) begin
                act_val = get_core_reg(c, r[4:0]);
                if (act_val === exp_val[r]) begin
                    $display("   Core %0d | x%-2d | Expected: %4d | Actual: %4d | PASS", c, r, exp_val[r], act_val);
                    pass_count = pass_count + 1;
                end else begin
                    $display("   Core %0d | x%-2d | Expected: %4d | Actual: %4d | FAIL", c, r, exp_val[r], act_val);
                    fail_count = fail_count + 1;
                end
            end
        end

        $display("");
        $display("============================================================================");
        $display(" CACHE HIERARCHY & MESI COHERENCE BUS VERIFICATION");
        $display("============================================================================");
        $display("   Total Cycles Run       : %0d", cycle_count);
        $display("   Main Memory Transfers  : %0d (8x L1I fills + 2x L2 data misses)", mem_access_count);
        $display("   L2 Cache Responses     : %0d", l2_resp_count);
        $display("   BusRd   Transactions   : %0d", bus_rd_count);
        $display("   BusRdX  Transactions   : %0d", bus_rdx_count);
        $display("   BusUpgr Transactions   : %0d", bus_upgr_count);
        $display("   Snoop HIT  Events      : %0d", snoop_hit_count);
        $display("   Snoop HITM Events      : %0d (Cache-to-Cache modified transfers)", snoop_hitm_count);
        $display("   Snoop ACK  Events      : %0d (Shared invalidations)", snoop_ack_count);

        if (mem_access_count >= 10) begin
            $display("   [PASS] Memory Controller & Arbiter serviced L1I and L2 misses (%0d accesses)", mem_access_count);
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Insufficient memory accesses (%0d)", mem_access_count);
            fail_count = fail_count + 1;
        end

        if (bus_rd_count >= 4) begin
            $display("   [PASS] Coherence Bus executed BusRd transactions (%0d)", bus_rd_count);
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] BusRd count too low (%0d)", bus_rd_count);
            fail_count = fail_count + 1;
        end

        if ((bus_upgr_count + bus_rdx_count) >= 4) begin
            $display("   [PASS] Coherence Bus executed write coherence transactions (BusUpgr=%0d, BusRdX=%0d)",
                     bus_upgr_count, bus_rdx_count);
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Write coherence transactions missing");
            fail_count = fail_count + 1;
        end

        if (snoop_hit_count > 0 && snoop_hitm_count > 0) begin
            $display("   [PASS] Snoop Controller verified both SNOOP_HIT (%0d) and SNOOP_HITM (%0d) cache-to-cache transfers",
                     snoop_hit_count, snoop_hitm_count);
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Missing snoop HIT (%0d) or HITM (%0d) events", snoop_hit_count, snoop_hitm_count);
            fail_count = fail_count + 1;
        end

        if (l2_resp_count >= 4) begin
            $display("   [PASS] Shared L2 Cache serviced coherence requests (%0d responses)", l2_resp_count);
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Shared L2 Cache did not respond (%0d)", l2_resp_count);
            fail_count = fail_count + 1;
        end

        $display("----------------------------------------------------------------------------");
        $display(" TOTAL: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0)
            $display(" >>> ALL QUAD-CORE FULL-SYSTEM & COHERENCE CHECKS PASSED! <<<");
        else
            $display(" >>> SOME CHECKS FAILED <<<");
        $display("============================================================================");

        $finish;
    end
endmodule
