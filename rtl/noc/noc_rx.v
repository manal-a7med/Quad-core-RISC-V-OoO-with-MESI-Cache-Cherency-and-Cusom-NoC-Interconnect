`timescale 1ns / 1ps
// ============================================================================
// noc_rx.v - packet receiver for the NoC endpoints (see noc_tx.v)
// ============================================================================

`include "noc_defs.vh"

module noc_rx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [`LINK_W-1:0] flit,
    input  wire               valid,
    output wire               ready,
    output reg                pkt_valid,
    output reg  [63:0]        pkt_hdr,
    output reg  [255:0]       pkt_data,
    input  wire               pkt_pop
);
    reg [2:0] pos;
    assign ready = !pkt_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos <= 3'd0; pkt_valid <= 1'b0; pkt_hdr <= 64'd0; pkt_data <= 256'd0;
        end else begin
            if (pkt_pop) pkt_valid <= 1'b0;
            if (valid && ready) begin
                if (pos == 3'd0) pkt_hdr <= flit[63:0];
                else             pkt_data[(pos - 3'd1)*64 +: 64] <= flit[63:0];
                if (flit[`LINK_W-1]) begin
                    pos       <= 3'd0;
                    pkt_valid <= 1'b1;
                end else begin
                    pos <= pos + 3'd1;
                end
            end
        end
    end
endmodule
