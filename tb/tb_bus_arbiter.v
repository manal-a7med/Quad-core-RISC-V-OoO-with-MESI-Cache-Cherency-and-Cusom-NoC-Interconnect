`timescale 1ns / 1ps
`define SIM

`include "mesi_defines.vh"

module tb_bus_arbiter;
    reg        clk;
    reg        rst_n;
    reg  [3:0] req;
    reg        bus_release;
    wire [3:0] grant;
    wire       bus_busy;
    wire [1:0] current_owner;

    bus_arbiter dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .req          (req),
        .bus_release  (bus_release),
        .grant        (grant),
        .bus_busy     (bus_busy),
        .current_owner(current_owner)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    initial begin
        $dumpfile("bus_arbiter.vcd");
        $dumpvars(0, tb_bus_arbiter);

        clk = 0; rst_n = 0; req = 0; bus_release = 0;
        #20 rst_n = 1;

        $display("============================================================");
        $display(" Bus Arbiter — Round-Robin Tests");
        $display("============================================================");

        // a) No requests -> no grant
        #10;
        if (grant == 4'b0000) begin
            $display("  PASS: No requests -> no grant");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: No requests -> got grant %b", grant);
            fail_count = fail_count + 1;
        end

        // b) Single requester -> immediate grant
        req = 4'b0001;
        #10;
        $display("  INFO: Single req[0], grant=%b busy=%b owner=%d", grant, bus_busy, current_owner);
        if (grant[0]) begin
            $display("  PASS: Single requester core 0");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Single requester core 0");
            fail_count = fail_count + 1;
        end

        // Release bus
        bus_release = 1; #10; bus_release = 0; req = 4'b0000;
        #10;

        // c) Two simultaneous requesters
        req = 4'b0101; // Core 0 and Core 2
        #10;
        $display("  INFO: Dual req[0,2], grant=%b owner=%d", grant, current_owner);
        bus_release = 1; #10; bus_release = 0;
        #10;
        $display("  INFO: After release, grant=%b owner=%d", grant, current_owner);
        bus_release = 1; #10; bus_release = 0; req = 0;
        #10;

        // d) All four requesting -> round-robin cycling
        req = 4'b1111;
        $display("  --- All 4 cores requesting ---");
        repeat (8) begin
            #10;
            $display("  INFO: grant=%b owner=%d busy=%b", grant, current_owner, bus_busy);
            bus_release = 1; #10; bus_release = 0;
        end
        req = 0;
        #10;

        // e) No requests after all released
        if (grant == 4'b0000 || !bus_busy) begin
            $display("  PASS: No grant when no requests");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Still granting with no requests");
            fail_count = fail_count + 1;
        end

        $display("");
        $display("============================================================");
        $display(" Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("============================================================");

        #50 $finish;
    end
endmodule
