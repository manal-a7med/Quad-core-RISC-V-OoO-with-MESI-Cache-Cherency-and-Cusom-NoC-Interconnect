`timescale 1ns / 1ps
// ============================================================================
// tb_cache.v - L1 data cache unit test (MESI transitions, data, write-back)
// ============================================================================
// The CPU side uses the real req/ack handshake (no fixed delays), a small bus
// model answers bus requests from a line memory a few cycles later, and
// snoops are injected for one cycle like the snoop controller does. A HITM
// snoop's data is written back to the line memory, as the L2 would be.
// ============================================================================
`include "mesi_defines.vh"
`include "common_defs.vh"

module tb_cache;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [31:0]  cpu_addr = 0, cpu_wdata = 0;
    wire [31:0]  cpu_rdata;
    reg          cpu_req = 0, cpu_wr = 0;
    wire         cpu_ack;
    reg  [2:0]   cpu_mem_type = `MEM_WORD;
    reg  [3:0]   cpu_amo = `AMO_NONE;
    wire [31:0]  bus_addr;
    wire [255:0] bus_wdata;
    reg  [255:0] bus_rdata = 0;
    wire         bus_req;
    wire [2:0]   bus_cmd;
    reg          bus_ack = 0, bus_grant = 0, bus_shared = 0;
    reg  [31:0]  snoop_addr = 0;
    reg  [2:0]   snoop_cmd = 0;
    reg          snoop_valid = 0;
    wire [1:0]   snoop_resp;
    wire [255:0] snoop_data;
    wire         snoop_data_valid;

    l1_dcache dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .cpu_req(cpu_req),
        .cpu_wr(cpu_wr), .cpu_ack(cpu_ack), .cpu_mem_type(cpu_mem_type), .cpu_amo(cpu_amo),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_req(bus_req),
        .bus_cmd(bus_cmd), .bus_ack(bus_ack), .bus_grant(bus_grant), .bus_shared(bus_shared),
        .snoop_addr(snoop_addr), .snoop_cmd(snoop_cmd), .snoop_valid(snoop_valid),
        .snoop_resp(snoop_resp), .snoop_data(snoop_data), .snoop_data_valid(snoop_data_valid));

    // ------------------------------------------------------------------
    // Bus model: line memory indexed by addr[12:5]; answers 3 cycles after
    // a request with a one-cycle grant + ack
    // ------------------------------------------------------------------
    reg [255:0] mem [0:255];
    reg         shared_next = 0;     // bus_shared for the next fill
    integer     n_read = 0, n_readx = 0, n_upgr = 0, n_flush = 0, bwait = 0;
    always @(negedge clk) begin
        if (bus_ack) begin
            bus_ack = 0; bus_grant = 0; bus_shared = 0; bwait = 0;
        end else if (bus_req) begin
            if (bwait == 2) begin
                case (bus_cmd)
                    `BUS_READ:  n_read  = n_read + 1;
                    `BUS_READX: n_readx = n_readx + 1;
                    `BUS_UPGR:  n_upgr  = n_upgr + 1;
                    `BUS_FLUSH: begin n_flush = n_flush + 1; mem[bus_addr[12:5]] = bus_wdata; end
                    default: ;
                endcase
                bus_rdata  = mem[bus_addr[12:5]];
                bus_shared = shared_next;
                bus_grant  = 1; bus_ack = 1; bwait = 0;
            end else bwait = bwait + 1;
        end else bwait = 0;
    end

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    integer pass_count = 0, fail_count = 0;
    task check(input cond, input [8*64-1:0] what);
        begin
            if (cond) begin pass_count = pass_count + 1; $display("  PASS: %0s", what); end
            else      begin fail_count = fail_count + 1; $display("  FAIL: %0s", what); end
        end
    endtask

    reg [31:0] rd; integer cyc;
    task access(input [31:0] a, input wr, input [31:0] wd, input [2:0] mt);
        begin
            @(negedge clk);
            cpu_addr = a; cpu_wr = wr; cpu_wdata = wd; cpu_mem_type = mt; cpu_req = 1; cyc = 0;
            @(negedge clk); #1;              // (#1: let other negedge drivers settle)
            while (!cpu_ack && cyc < 200) begin @(negedge clk); #1; cyc = cyc + 1; end
            rd = cpu_rdata;
            if (!cpu_ack) $display("  (no ack for %h)", a);
            @(posedge clk); #1 cpu_req = 0; cpu_wr = 0;
        end
    endtask
    task load(input [31:0] a);                    begin access(a, 0, 0, `MEM_WORD); end endtask
    task store(input [31:0] a, input [31:0] d);   begin access(a, 1, d, `MEM_WORD); end endtask

    reg [1:0] s_resp; reg s_dv; reg [255:0] s_data;
    task snoop(input [31:0] a, input [2:0] cmd);
        begin
            @(negedge clk); snoop_addr = a; snoop_cmd = cmd; snoop_valid = 1;
            @(negedge clk); snoop_valid = 0;
            s_resp = snoop_resp; s_dv = snoop_data_valid; s_data = snoop_data;
            if (s_resp == `SNOOP_HITM) mem[a[12:5]] = s_data;     // to "L2"
        end
    endtask

    function [1:0] line_state(input [31:0] a);
        reg [5:0] i; reg [1:0] s0, s1;
        begin
            i = a[10:5];
            s0 = dut.state_bits[{1'b0, i}*2 +: 2];
            s1 = dut.state_bits[{1'b1, i}*2 +: 2];
            if      (s0 != `MESI_INVALID && dut.tag0[i] == a[31:11]) line_state = s0;
            else if (s1 != `MESI_INVALID && dut.tag1[i] == a[31:11]) line_state = s1;
            else line_state = `MESI_INVALID;
        end
    endfunction

    integer k, r0, rx0, u0, f0;
    task bus_mark; begin r0 = n_read; rx0 = n_readx; u0 = n_upgr; f0 = n_flush; end endtask

    initial begin
        for (k = 0; k < 256; k = k + 1)
            mem[k] = {32'h8 + k, 32'h7 + k, 32'h6 + k, 32'h5 + k, 32'h4 + k, 32'h3 + k, 32'h2 + k, 32'h1 + k} - {8{32'h80}};
        // line 0x80 (address 0x1000) holds words 1..8
        #22 rst_n = 1;

        $display("============================================================");
        $display(" L1 Data Cache - MESI unit tests (handshake based)");
        $display("============================================================");

        $display("--- 1: read miss, I -> E");
        bus_mark; load(32'h1000);
        check(rd == 32'h1 && n_read == r0 + 1, "read miss returns word 0 after one BusRd");
        check(line_state(32'h1000) == `MESI_EXCLUSIVE, "line is Exclusive");

        $display("--- 2: read hit");
        bus_mark; load(32'h101C);
        check(rd == 32'h8 && n_read == r0 && cyc == 0, "read hit returns word 7 in two cycles, no bus traffic");

        $display("--- 3: store hit on E, silent E -> M");
        bus_mark; store(32'h1000, 32'hCAFE_BABE);
        check(n_read + n_readx + n_upgr == r0 + rx0 + u0, "no bus traffic");
        check(line_state(32'h1000) == `MESI_MODIFIED, "line is Modified");
        load(32'h1000);
        check(rd == 32'hCAFE_BABE, "store visible to a later load");

        $display("--- 4: snoop BusRd on M -> S with HITM");
        snoop(32'h1000, `BUS_READ);
        check(s_resp == `SNOOP_HITM && s_dv && s_data[31:0] == 32'hCAFE_BABE, "HITM, supplies the modified line");
        check(line_state(32'h1000) == `MESI_SHARED, "line is Shared");
        @(negedge clk);
        check(snoop_resp == `SNOOP_NONE && !snoop_data_valid, "response cleared after one cycle");

        $display("--- 5: store hit on S -> BusUpgr -> M");
        bus_mark; store(32'h1004, 32'h1234_5678);
        check(n_upgr == u0 + 1, "one BusUpgr");
        check(line_state(32'h1004) == `MESI_MODIFIED, "line is Modified");
        load(32'h1004); check(rd == 32'h1234_5678, "upgraded store visible");
        load(32'h1000); check(rd == 32'hCAFE_BABE, "rest of the line kept");

        $display("--- 6: snoop BusRdX on M -> I with HITM");
        snoop(32'h1000, `BUS_READX);
        check(s_resp == `SNOOP_HITM && s_dv && s_data[63:32] == 32'h1234_5678, "HITM, supplies word 1");
        check(line_state(32'h1000) == `MESI_INVALID, "line is Invalid");

        $display("--- 7: store miss -> BusRdX -> M");
        bus_mark; store(32'h1000, 32'hABCD_EF01);
        check(n_readx == rx0 + 1, "one BusRdX");
        check(line_state(32'h1000) == `MESI_MODIFIED, "line is Modified");
        load(32'h1000); check(rd == 32'hABCD_EF01, "store merged into the fetched line");
        load(32'h1004); check(rd == 32'h1234_5678, "other words come from memory");

        $display("--- 8: byte and halfword stores");
        access(32'h1009, 1, 32'h0000_00AA, `MEM_BYTE);
        access(32'h100E, 1, 32'h0000_BEEF, `MEM_HALF);
        load(32'h1008); check(rd == 32'h0000_AA03, "sb at byte 1 of word 2");
        load(32'h100C); check(rd == 32'hBEEF_0004, "sh at bytes 2-3 of word 3");
        access(32'h1009, 0, 0, `MEM_BYTE_U); check(rd[7:0] == 8'hAA, "byte read is aligned to bit 0");

        $display("--- 9: dirty eviction writes the line back");
        load(32'h1800);                      // same set, other way
        bus_mark; load(32'h2000);            // evicts the LRU way: 0x1000 (M)
        check(n_flush == f0 + 1, "one BusFlush");
        check(mem[8'h80][31:0] == 32'hABCD_EF01 && mem[8'h80][95:64] == 32'h0000_AA03,
              "written-back line holds the stores");
        check(line_state(32'h1000) == `MESI_INVALID && line_state(32'h2000) == `MESI_EXCLUSIVE,
              "victim invalid, new line Exclusive");

        $display("--- 10: snoop in the same cycle as a store hit (bug 13)");
        // 0x1800 is Exclusive. The store reaches COMPARE_TAG in the same
        // cycle as a BusRdX snoop; the store must not be lost.
        fork
            store(32'h1800, 32'h5555_AAAA);
            begin @(negedge clk); snoop(32'h1800, `BUS_READX); end
        join
        check(s_resp == `SNOOP_HIT && !s_dv, "snoop saw the clean line (store waited)");
        check(line_state(32'h1800) == `MESI_MODIFIED, "store then refetched the line (M)");
        load(32'h1800); check(rd == 32'h5555_AAAA, "store not lost");

        $display("");
        $display("============================================================");
        $display(" Cache Test Complete: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("============================================================");
        #20 $finish;
    end

    initial begin #200000; $display("TIMEOUT FAILED"); $finish; end
endmodule
