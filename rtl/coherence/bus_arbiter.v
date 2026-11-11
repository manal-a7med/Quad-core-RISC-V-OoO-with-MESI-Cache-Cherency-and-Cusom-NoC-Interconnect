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

`ifdef SIM
    always @(posedge clk) begin
        if (|req && !bus_busy) $display("[Bus Arbiter] Granted bus to core %0d", next_owner);
        if (bus_release && bus_busy) $display("[Bus Arbiter] Bus released by core %0d", current_owner);
    end
`endif

endmodule
