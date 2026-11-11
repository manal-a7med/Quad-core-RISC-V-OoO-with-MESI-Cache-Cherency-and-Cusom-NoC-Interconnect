`timescale 1ns / 1ps
`define SIM

`include "common_defs.vh"

module tb_ooo_core;
    reg clk;
    reg rst_n;

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

    // Core instantiation
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

    // Simple data memory model
    reg [31:0] dmem [0:255];

    always #5 clk = ~clk;

    // Instruction memory — returns instructions based on PC
    always @(*) begin
        icache_ack = icache_req;
        case (icache_addr)
            32'h00000000: icache_rdata = 32'h00500093; // ADDI x1, x0, 5   (x1 = 5)
            32'h00000004: icache_rdata = 32'h00A00113; // ADDI x2, x0, 10  (x2 = 10)
            32'h00000008: icache_rdata = 32'h002081B3; // ADD  x3, x1, x2  (x3 = 15)
            32'h0000000C: icache_rdata = 32'h00102023; // SW   x1, 0(x0)   (mem[0] = 5)
            32'h00000010: icache_rdata = 32'h00002203; // LW   x4, 0(x0)   (x4 = 5)
            32'h00000014: icache_rdata = 32'h00300293; // ADDI x5, x0, 3   (x5 = 3)
            32'h00000018: icache_rdata = 32'h00528333; // ADD  x6, x5, x5  (x6 = 6)
            default:      icache_rdata = 32'h00000013; // NOP
        endcase
    end

    // Data memory model — handles loads and stores
    always @(posedge clk) begin
        if (!rst_n) begin
            dcache_ack   <= 0;
            dcache_rdata <= 32'd0;
        end else if (dcache_req) begin
            dcache_ack <= 1;
            if (dcache_wr) begin
                dmem[dcache_addr[9:2]] <= dcache_wdata;
            end else begin
                dcache_rdata <= dmem[dcache_addr[9:2]];
            end
        end else begin
            dcache_ack <= 0;
        end
    end

    function [31:0] get_arch_reg;
        input [4:0] r;
        reg   [5:0] p;
        begin
            p = dut.u_rename.arch_rat[r];
            get_arch_reg = (p == 6'd0) ? 32'd0 : dut.u_regfile.regs[p];
        end
    endfunction

    integer i;
    integer pass_count = 0;
    integer fail_count = 0;

    task check_val;
        input [127:0] label;
        input [31:0]  act;
        input [31:0]  exp;
        begin
            if (act === exp) begin
                $display("  PASS: %s = %0d", label, act);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s = %0d (expected %0d)", label, act, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("ooo_core.vcd");
        $dumpvars(0, tb_ooo_core);

        clk = 0; rst_n = 0;
        dcache_rdata = 32'd0;
        dcache_ack = 0;

        for (i = 0; i < 256; i = i + 1)
            dmem[i] = 32'd0;

        $display("============================================================");
        $display(" RISC-V OoO Core — Single Core Test");
        $display("============================================================");

        #20 rst_n = 1;
        #1000;

        check_val("x1 (ADDI 5)   ", get_arch_reg(5'd1), 32'd5);
        check_val("x2 (ADDI 10)  ", get_arch_reg(5'd2), 32'd10);
        check_val("x3 (ADD x1+x2)", get_arch_reg(5'd3), 32'd15);
        check_val("x4 (LW 0(x0)) ", get_arch_reg(5'd4), 32'd5);
        check_val("x5 (ADDI 3)   ", get_arch_reg(5'd5), 32'd3);
        check_val("x6 (ADD x5+x5)", get_arch_reg(5'd6), 32'd6);
        check_val("dmem[0] (SW)  ", dmem[0],            32'd5);

        $display("============================================================");
        $display(" Single Core Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("============================================================");
        $finish;
    end
endmodule
