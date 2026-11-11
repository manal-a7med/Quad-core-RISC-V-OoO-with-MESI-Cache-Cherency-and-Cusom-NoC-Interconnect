`timescale 1ns / 1ps
`define SIM

`include "mesi_defines.vh"
`include "common_defs.vh"

module tb_cache;
    reg         clk;
    reg         rst_n;

    // CPU Interface
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_wdata;
    wire [31:0] cpu_rdata;
    reg         cpu_req;
    reg         cpu_wr;
    wire        cpu_ack;
    reg  [2:0]  cpu_mem_type;

    // Bus Interface (simulated responses)
    wire [31:0]  bus_addr;
    wire [255:0] bus_wdata;
    reg  [255:0] bus_rdata;
    wire         bus_req;
    wire [2:0]   bus_cmd;
    reg          bus_ack;
    reg          bus_grant;
    reg          bus_shared;

    // Snoop Interface
    reg  [31:0]  snoop_addr;
    reg  [2:0]   snoop_cmd;
    reg          snoop_valid;
    wire [1:0]   snoop_resp;
    wire [255:0] snoop_data;
    wire         snoop_data_valid;

    l1_dcache dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .cpu_addr        (cpu_addr),
        .cpu_wdata       (cpu_wdata),
        .cpu_rdata       (cpu_rdata),
        .cpu_req         (cpu_req),
        .cpu_wr          (cpu_wr),
        .cpu_ack         (cpu_ack),
        .cpu_mem_type    (cpu_mem_type),
        .bus_addr        (bus_addr),
        .bus_wdata       (bus_wdata),
        .bus_rdata       (bus_rdata),
        .bus_req         (bus_req),
        .bus_cmd         (bus_cmd),
        .bus_ack         (bus_ack),
        .bus_grant       (bus_grant),
        .bus_shared      (bus_shared),
        .snoop_addr      (snoop_addr),
        .snoop_cmd       (snoop_cmd),
        .snoop_valid     (snoop_valid),
        .snoop_resp      (snoop_resp),
        .snoop_data      (snoop_data),
        .snoop_data_valid(snoop_data_valid)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    // Simulate memory/bus response
    task auto_bus_respond;
        input [255:0] line_data;
        input         shared_flag;
        begin
            bus_grant  = 1;
            bus_shared = shared_flag;
            #10;
            bus_rdata  = line_data;
            bus_ack    = 1;
            #10;
            bus_ack    = 0;
            bus_grant  = 0;
            bus_shared = 0;
        end
    endtask

    initial begin
        $dumpfile("cache_test.vcd");
        $dumpvars(0, tb_cache);

        clk = 0; rst_n = 0;
        cpu_addr = 0; cpu_wdata = 0; cpu_req = 0; cpu_wr = 0;
        cpu_mem_type = 3'b010; // Word
        bus_rdata = 0; bus_ack = 0; bus_grant = 0; bus_shared = 0;
        snoop_addr = 0; snoop_cmd = 0; snoop_valid = 0;

        #20 rst_n = 1;
        #10;

        $display("============================================================");
        $display(" L1 Data Cache — Comprehensive MESI Unit Tests");
        $display("============================================================");

        // ---- Test 1: Read Miss → Allocate (I -> E) ----
        $display("");
        $display("--- Test 1: Read Miss (I -> E Allocate) ---");
        cpu_addr = 32'h0000_1000;
        cpu_req  = 1;
        cpu_wr   = 0;
        #10;

        if (bus_req && bus_cmd == `BUS_READ) begin
            $display("  INFO: BusRd issued (cmd=%b addr=0x%08h)", bus_cmd, bus_addr);
            auto_bus_respond({32'hDEAD_BEEF, 32'h0000_0007, 32'h0000_0006,
                              32'h0000_0005, 32'h0000_0004, 32'h0000_0003,
                              32'h0000_0002, 32'h0000_0001}, 1'b0);
        end

        #10;
        if (cpu_ack && cpu_rdata == 32'h0000_0001) begin
            $display("  PASS: Read miss handled, data=0x%08h (state=E)", cpu_rdata);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Read miss ack=%b data=0x%08h", cpu_ack, cpu_rdata);
            fail_count = fail_count + 1;
        end
        cpu_req = 0;
        #20;

        // ---- Test 2: Read Hit (Word 7 of same cache line) ----
        $display("");
        $display("--- Test 2: Read Hit (Offset 0x1C) ---");
        cpu_addr = 32'h0000_101C;
        cpu_req  = 1;
        cpu_wr   = 0;
        #20;
        if (cpu_ack && cpu_rdata == 32'hDEAD_BEEF && !bus_req) begin
            $display("  PASS: Read hit, ack=%b data=0x%08h", cpu_ack, cpu_rdata);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Read hit ack=%b data=0x%08h", cpu_ack, cpu_rdata);
            fail_count = fail_count + 1;
        end
        cpu_req = 0;
        #20;

        // ---- Test 3: Write Hit on Exclusive (Silent E -> M) ----
        $display("");
        $display("--- Test 3: Write Hit on Exclusive (Silent E -> M) ---");
        cpu_addr  = 32'h0000_1000;
        cpu_wdata = 32'hCAFE_BABE;
        cpu_req   = 1;
        cpu_wr    = 1;
        #20;
        if (cpu_ack && !bus_req) begin
            $display("  PASS: Silent Write Hit E->M, ack=%b", cpu_ack);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Write hit ack=%b bus_req=%b", cpu_ack, bus_req);
            fail_count = fail_count + 1;
        end
        cpu_req = 0;
        cpu_wr  = 0;
        #20;

        // ---- Test 4: Snoop BusRd on Modified Line (M -> S + HITM data supply) ----
        $display("");
        $display("--- Test 4: Snoop BusRd on Modified Line (M -> S, HITM) ---");
        snoop_addr  = 32'h0000_1000;
        snoop_cmd   = `BUS_READ;
        snoop_valid = 1;
        #20;
        snoop_valid = 0;
        if (snoop_resp == `SNOOP_HITM && snoop_data_valid && snoop_data[31:0] == 32'hCAFE_BABE) begin
            $display("  PASS: Snoop BusRd -> HITM (resp=%b), supplied modified word 0x%08h", snoop_resp, snoop_data[31:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Snoop BusRd resp=%b dvalid=%b data=0x%08h", snoop_resp, snoop_data_valid, snoop_data[31:0]);
            fail_count = fail_count + 1;
        end
        #20;

        // ---- Test 5: Write Hit on Shared Line (S -> M via BusUpgr) ----
        $display("");
        $display("--- Test 5: Write Hit on Shared Line (S -> M via BusUpgr) ---");
        cpu_addr  = 32'h0000_1004;
        cpu_wdata = 32'h1234_5678;
        cpu_req   = 1;
        cpu_wr    = 1;
        #10;
        if (bus_req && bus_cmd == `BUS_UPGR) begin
            $display("  INFO: BusUpgr issued (cmd=%b addr=0x%08h)", bus_cmd, bus_addr);
            auto_bus_respond(256'd0, 1'b0);
        end
        #10;
        if (cpu_ack) begin
            $display("  PASS: Write Hit S->M completed after BusUpgr, ack=%b", cpu_ack);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Write Hit S->M failed, ack=%b", cpu_ack);
            fail_count = fail_count + 1;
        end
        cpu_req = 0;
        cpu_wr  = 0;
        #20;

        // ---- Test 6: Snoop BusRdX (M -> I Invalidate + HITM) ----
        $display("");
        $display("--- Test 6: Snoop BusRdX (M -> I Invalidate) ---");
        snoop_addr  = 32'h0000_1000;
        snoop_cmd   = `BUS_READX;
        snoop_valid = 1;
        #20;
        snoop_valid = 0;
        if (snoop_resp == `SNOOP_HITM && snoop_data_valid && snoop_data[63:32] == 32'h1234_5678) begin
            $display("  PASS: Snoop BusRdX -> HITM & invalidated, word1=0x%08h", snoop_data[63:32]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Snoop BusRdX resp=%b", snoop_resp);
            fail_count = fail_count + 1;
        end
        #20;

        // ---- Test 7: Write Miss on Invalidated Line (I -> M via BusRdX) ----
        $display("");
        $display("--- Test 7: Write Miss on Invalidated Line (I -> M via BusRdX) ---");
        cpu_addr  = 32'h0000_1000;
        cpu_wdata = 32'hABCD_EF01;
        cpu_req   = 1;
        cpu_wr    = 1;
        #10;
        if (bus_req && bus_cmd == `BUS_READX) begin
            $display("  INFO: BusRdX issued (cmd=%b addr=0x%08h)", bus_cmd, bus_addr);
            auto_bus_respond({224'd0, 32'h0000_0001}, 1'b0);
        end
        #10;
        if (cpu_ack) begin
            $display("  PASS: Write Miss I->M completed via BusRdX, ack=%b", cpu_ack);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Write Miss I->M ack=%b", cpu_ack);
            fail_count = fail_count + 1;
        end
        cpu_req = 0;
        cpu_wr  = 0;
        #20;

        $display("");
        $display("============================================================");
        $display(" Cache Test Complete: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("============================================================");

        #30 $finish;
    end
endmodule
