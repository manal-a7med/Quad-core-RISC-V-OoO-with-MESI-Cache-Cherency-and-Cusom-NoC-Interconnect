`timescale 1ns / 1ps
`include "mesi_defines.vh"
`include "common_defs.vh"

module bus_arbiter (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] req,
    input  wire       bus_release,
    output reg  [3:0] grant,
    output reg        bus_busy,
    output reg  [1:0] current_owner
);

    reg  [1:0] last_grant;
    reg  [1:0] next_owner;

    wire [1:0] cand1 = last_grant + 2'd1;
    wire [1:0] cand2 = last_grant + 2'd2;
    wire [1:0] cand3 = last_grant + 2'd3;

    always @(*) begin
        if      (req[cand1]) next_owner = cand1;
        else if (req[cand2]) next_owner = cand2;
        else if (req[cand3]) next_owner = cand3;
        else                 next_owner = last_grant;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant         <= 4'b0000;
            bus_busy      <= 1'b0;
            current_owner <= 2'b00;
            last_grant    <= 2'b11; // Start search at core 0 after reset
        end else begin
            if (bus_busy) begin
                if (bus_release) begin
                    bus_busy <= 1'b0;
                    grant    <= 4'b0000;
                end
            end else begin
                // Priority resolution (Round-robin)
                if (|req) begin
                    bus_busy      <= 1'b1;
                    current_owner <= next_owner;
                    last_grant    <= next_owner;
                    grant         <= (4'b0001 << next_owner);
                end else begin
                    grant         <= 4'b0000;
                end
            end
        end
    end

`ifdef BUS_DEBUG   // +define+BUS_DEBUG for a transaction log
    always @(posedge clk) begin
        if (|req && !bus_busy) $display("[Bus Arbiter] Granted bus to core %0d", next_owner);
        if (bus_release && bus_busy) $display("[Bus Arbiter] Bus released by core %0d", current_owner);
    end
`endif

`ifdef FORMAL
    // ------------------------------------------------------------------
    // Formal properties (make formal; verif/formal/run_formal.sh). They are
    // proved for every input sequence by induction, not just simulated.
    // Assumption: a cache holds its request until it is granted (as
    // l1_dcache does). Reset in the first cycle only.
    // ------------------------------------------------------------------
    reg       f_init = 1'b1;
    reg [3:0] f_req_q = 4'b0;
    reg [1:0] f_lg_q = 2'b11;
    reg       f_busy_q = 1'b0;
    reg [2:0] f_wait [0:3];          // grants to other cores while core c waits
    integer   f_c;
    initial for (f_c = 0; f_c < 4; f_c = f_c + 1) f_wait[f_c] = 3'd0;
    always @(*) assume (rst_n == !f_init);
    always @(posedge clk) begin
        f_init <= 1'b0; f_req_q <= req; f_lg_q <= last_grant; f_busy_q <= bus_busy;
        for (f_c = 0; f_c < 4; f_c = f_c + 1)
            if (f_init || grant[f_c] || !req[f_c]) f_wait[f_c] <= 3'd0;
            else if (bus_busy && !f_busy_q && f_req_q[f_c]) f_wait[f_c] <= f_wait[f_c] + 3'd1;
    end
    // first requesting core after the previous winner (the winner itself last)
    function [1:0] f_pick(input [1:0] lg, input [3:0] r);
        f_pick = r[lg + 2'd1] ? lg + 2'd1 : r[lg + 2'd2] ? lg + 2'd2 : r[lg + 2'd3] ? lg + 2'd3 : lg;
    endfunction
    always @(*) if (!f_init) begin
        assume ((f_req_q & ~grant & ~req) == 4'b0);             // requests are held
        assert ((grant & (grant - 4'd1)) == 4'b0);               // at most one grant
        assert (bus_busy ? (grant == (4'b0001 << current_owner)) : (grant == 4'b0000));
        if (bus_busy) assert (last_grant == current_owner);
        if (bus_busy && !f_busy_q) begin                          // a new grant:
            assert (f_req_q[current_owner]);                      //   to a requester,
            assert (current_owner == f_pick(f_lg_q, f_req_q));    //   in round-robin order
        end
        for (f_c = 0; f_c < 4; f_c = f_c + 1) begin
            assert (f_wait[f_c] <= 3'd3);                         // no starvation
            if (f_wait[f_c] != 3'd0) assert (f_req_q[f_c] &&      // (induction invariant)
                f_wait[f_c] + {1'b0, f_c[1:0] - last_grant} <= 3'd4);
        end
    end
`endif

endmodule
