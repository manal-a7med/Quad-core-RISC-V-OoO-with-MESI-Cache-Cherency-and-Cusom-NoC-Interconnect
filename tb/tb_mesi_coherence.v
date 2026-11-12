`timescale 1ns / 1ps
`define SIM

`include "mesi_defines.vh"

module tb_mesi_coherence;

    reg        clk;
    reg        rst_n;
    reg  [1:0] current_state;
    reg        proc_event;        // 0: PrRd, 1: PrWr
    reg        proc_event_valid;
    reg  [2:0] bus_event;
    reg        bus_event_valid;
    reg        shared_signal;

    wire [1:0] next_state;
    wire [2:0] bus_action;
    wire       need_flush;
    wire       supply_data;

    mesi_protocol dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .current_state   (current_state),
        .proc_event      (proc_event),
        .proc_event_valid(proc_event_valid),
        .bus_event       (bus_event),
        .bus_event_valid (bus_event_valid),
        .shared_signal   (shared_signal),
        .next_state      (next_state),
        .bus_action      (bus_action),
        .need_flush      (need_flush),
        .supply_data     (supply_data)
    );

    // Clock: 10ns period
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    // State names for display
    task print_state;
        input [1:0] s;
        begin
            case (s)
                2'b00: $write("I");
                2'b01: $write("S");
                2'b10: $write("E");
                2'b11: $write("M");
            endcase
        end
    endtask

    task test_proc_event;
        input [1:0]    in_state;
        input          event_type;   // 0=PrRd, 1=PrWr
        input          shared;
        input [1:0]    exp_next;
        input [2:0]    exp_bus;
        input          exp_flush;
        input [8*40:1] name;
        begin
            @(posedge clk);
            current_state    = in_state;
            proc_event       = event_type;
            proc_event_valid = 1'b1;
            bus_event_valid  = 1'b0;
            shared_signal    = shared;
            #1; // Allow combinational logic to settle

            if (next_state === exp_next && bus_action === exp_bus && need_flush === exp_flush) begin
                $display("  PASS: %0s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s | Expected state=%b bus=%b flush=%b | Got state=%b bus=%b flush=%b",
                         name, exp_next, exp_bus, exp_flush, next_state, bus_action, need_flush);
                fail_count = fail_count + 1;
            end

            @(posedge clk);
            proc_event_valid = 1'b0;
        end
    endtask

    task test_bus_event;
        input [1:0]    in_state;
        input [2:0]    event_cmd;
        input [1:0]    exp_next;
        input          exp_flush;
        input          exp_supply;
        input [8*40:1] name;
        begin
            @(posedge clk);
            current_state    = in_state;
            bus_event        = event_cmd;
            bus_event_valid  = 1'b1;
            proc_event_valid = 1'b0;
            shared_signal    = 1'b0;
            #1;

            if (next_state === exp_next && need_flush === exp_flush && supply_data === exp_supply) begin
                $display("  PASS: %0s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s | Expected state=%b flush=%b supply=%b | Got state=%b flush=%b supply=%b",
                         name, exp_next, exp_flush, exp_supply, next_state, need_flush, supply_data);
                fail_count = fail_count + 1;
            end

            @(posedge clk);
            bus_event_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("mesi_coherence.vcd");
        $dumpvars(0, tb_mesi_coherence);

        clk = 0; rst_n = 0;
        current_state = 2'b00;
        proc_event = 0; proc_event_valid = 0;
        bus_event = 3'b000; bus_event_valid = 0;
        shared_signal = 0;

        #20; rst_n = 1;
        #10;

        $display("============================================================");
        $display(" MESI Cache Coherence Protocol — State Transition Tests");
        $display("============================================================");
        $display("");

        // ===== PROCESSOR-SIDE TRANSITIONS =====
        $display("--- Processor-Side Transitions ---");

        // a) I + PrRd (shared=1) -> S, BusRd
        test_proc_event(2'b00, 1'b0, 1'b1, 2'b01, 3'b001, 1'b0, "I + PrRd (shared) -> S, BusRd");

        // b) I + PrRd (shared=0) -> E, BusRd
        test_proc_event(2'b00, 1'b0, 1'b0, 2'b10, 3'b001, 1'b0, "I + PrRd (no share) -> E, BusRd");

        // c) I + PrWr -> M, BusRdX
        test_proc_event(2'b00, 1'b1, 1'b0, 2'b11, 3'b010, 1'b0, "I + PrWr -> M, BusRdX");

        // d) S + PrRd -> S, no bus
        test_proc_event(2'b01, 1'b0, 1'b0, 2'b01, 3'b000, 1'b0, "S + PrRd -> S (hit, no bus)");

        // e) S + PrWr -> M, BusUpgr
        test_proc_event(2'b01, 1'b1, 1'b0, 2'b11, 3'b011, 1'b0, "S + PrWr -> M, BusUpgr");

        // f) E + PrRd -> E, no bus
        test_proc_event(2'b10, 1'b0, 1'b0, 2'b10, 3'b000, 1'b0, "E + PrRd -> E (hit, no bus)");

        // g) E + PrWr -> M, no bus (silent upgrade)
        test_proc_event(2'b10, 1'b1, 1'b0, 2'b11, 3'b000, 1'b0, "E + PrWr -> M (silent upgrade)");

        // h) M + PrRd -> M, no bus
        test_proc_event(2'b11, 1'b0, 1'b0, 2'b11, 3'b000, 1'b0, "M + PrRd -> M (hit, no bus)");

        // i) M + PrWr -> M, no bus
        test_proc_event(2'b11, 1'b1, 1'b0, 2'b11, 3'b000, 1'b0, "M + PrWr -> M (hit, no bus)");

        $display("");

        // ===== BUS-SIDE (SNOOP) TRANSITIONS =====
        $display("--- Bus-Side (Snoop) Transitions ---");

        // j) M + BusRd -> S, flush + supply
        test_bus_event(2'b11, 3'b001, 2'b01, 1'b1, 1'b1, "M + BusRd -> S, flush+supply");

        // k) M + BusRdX -> I, flush + supply
        test_bus_event(2'b11, 3'b010, 2'b00, 1'b1, 1'b1, "M + BusRdX -> I, flush+supply");

        // l) E + BusRd -> S, supply
        test_bus_event(2'b10, 3'b001, 2'b01, 1'b0, 1'b1, "E + BusRd -> S, supply data");

        // m) E + BusRdX -> I
        test_bus_event(2'b10, 3'b010, 2'b00, 1'b0, 1'b0, "E + BusRdX -> I, invalidate");

        // n) S + BusRd -> S (no change)
        test_bus_event(2'b01, 3'b001, 2'b01, 1'b0, 1'b0, "S + BusRd -> S (no change)");

        // o) S + BusRdX -> I
        test_bus_event(2'b01, 3'b010, 2'b00, 1'b0, 1'b0, "S + BusRdX -> I, invalidate");

        // p) S + BusUpgr -> I
        test_bus_event(2'b01, 3'b011, 2'b00, 1'b0, 1'b0, "S + BusUpgr -> I, invalidate");

        // q) I + BusRd -> I (nothing happens)
        test_bus_event(2'b00, 3'b001, 2'b00, 1'b0, 1'b0, "I + BusRd -> I (no effect)");

        // r) I + BusRdX -> I (nothing happens)
        test_bus_event(2'b00, 3'b010, 2'b00, 1'b0, 1'b0, "I + BusRdX -> I (no effect)");

        $display("");
        $display("============================================================");
        $display(" Results: %0d PASSED, %0d FAILED (of %0d total)",
                 pass_count, fail_count, pass_count + fail_count);
        if (fail_count == 0)
            $display(" >>> ALL MESI TESTS PASSED! <<<");
        else
            $display(" >>> SOME TESTS FAILED! <<<");
        $display("============================================================");

        #50 $finish;
    end

endmodule
