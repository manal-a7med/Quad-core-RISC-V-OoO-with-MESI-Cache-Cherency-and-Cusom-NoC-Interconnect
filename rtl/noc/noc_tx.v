`timescale 1ns / 1ps
// ============================================================================
// noc_tx.v / noc_rx.v - packet send and receive helpers for the NoC endpoints
// ============================================================================
// noc_tx: takes a whole packet (header + optional 256-bit line) in one cycle
//         and sends it as 1 or 5 flits. `send` is accepted when `idle`.
// noc_rx: collects the flits of one packet and presents it whole
//         (pkt_valid until pkt_pop). Takes no new flits while it holds one.
// ============================================================================

`include "noc_defs.vh"

module noc_tx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               send,
    input  wire [63:0]        hdr,
    input  wire [255:0]       data,         // used when hdr[`HDR_DATA]
    output wire               idle,
    output wire [`LINK_W-1:0] flit,
    output wire               valid,
    input  wire               ready
);
    reg [2:0]   left;                       // flits still to send
    reg [2:0]   pos;
    reg [63:0]  h;
    reg [255:0] d;

    assign idle  = (left == 3'd0);
    assign valid = !idle;
    wire [63:0] word = (pos == 3'd0) ? h : d[(pos - 3'd1)*64 +: 64];
    assign flit  = {left == 3'd1, word};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            left <= 3'd0; pos <= 3'd0; h <= 64'd0; d <= 256'd0;
        end else if (idle) begin
            if (send) begin
                h    <= hdr;
                d    <= data;
                pos  <= 3'd0;
                left <= hdr[`HDR_DATA] ? 3'd5 : 3'd1;
            end
        end else if (ready) begin
            left <= left - 3'd1;
            pos  <= pos + 3'd1;
        end
    end
endmodule

