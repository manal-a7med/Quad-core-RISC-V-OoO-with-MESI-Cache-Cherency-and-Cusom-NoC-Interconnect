`timescale 1ns / 1ps
// ============================================================================
// noc_router.v - 3-port wormhole router for the 2x2 mesh
// ============================================================================
// In a 2x2 mesh every node has exactly two neighbours, one in X (node ^ 1)
// and one in Y (node ^ 2), so a router has three ports:
//   port 0  local (the endpoint at this node)
//   port 1  X neighbour
//   port 2  Y neighbour
//
// Routing is XY (dimension order): correct X first, then Y, then deliver.
// XY routing cannot form a cycle of waiting packets, so the mesh itself is
// deadlock free; message classes are kept apart by using separate networks.
//
// Each input has a 2-flit FIFO. The head flit of a packet picks the output;
// the output stays locked to that input until the tail flit has passed
// (wormhole switching). Free outputs are given round-robin. One flit per
// output per cycle; a flit takes one cycle per router plus the FIFO.
// Flow control is valid/ready on every link.
// ============================================================================

`include "noc_defs.vh"

module noc_router #(
    parameter [1:0] NODE = 2'd0
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [3*`LINK_W-1:0] in_flit,     // port p in [p*LINK_W +: LINK_W]
    input  wire [2:0]           in_valid,
    output wire [2:0]           in_ready,

    output wire [3*`LINK_W-1:0] out_flit,
    output wire [2:0]           out_valid,
    input  wire [2:0]           out_ready
);

    // ------------------------------------------------------------------
    // Input FIFOs (2 entries each)
    // ------------------------------------------------------------------
    wire [`LINK_W-1:0] head  [0:2];
    wire [2:0]         hvalid;
    wire [2:0]         pop;

    genvar p;
    generate for (p = 0; p < 3; p = p + 1) begin : inq
        reg [`LINK_W-1:0] mem [0:1];
        reg               rd, wr;
        reg [1:0]         cnt;
        wire push = in_valid[p] && in_ready[p];
        assign in_ready[p] = (cnt != 2'd2);
        assign head[p]     = mem[rd];
        assign hvalid[p]   = (cnt != 2'd0);
        always @(posedge clk) if (push) mem[wr] <= in_flit[p*`LINK_W +: `LINK_W];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                rd <= 1'b0; wr <= 1'b0; cnt <= 2'd0;
            end else begin
                if (push)   wr <= ~wr;
                if (pop[p]) rd <= ~rd;
                cnt <= cnt + {1'b0, push} - {1'b0, pop[p]};
            end
        end
    end endgenerate

    // ------------------------------------------------------------------
    // Route of each input's current packet
    // ------------------------------------------------------------------
    reg  [2:0] in_mid;                       // input is inside a packet (route held)
    reg  [1:0] in_route_r [0:2];
    wire [1:0] in_route   [0:2];

    function [1:0] xy_route;
        input [1:0] dst;
        begin
            if      (dst[0] != NODE[0]) xy_route = 2'd1;   // X
            else if (dst[1] != NODE[1]) xy_route = 2'd2;   // Y
            else                        xy_route = 2'd0;   // local
        end
    endfunction

    generate for (p = 0; p < 3; p = p + 1) begin : rt
        assign in_route[p] = in_mid[p] ? in_route_r[p] : xy_route(head[p][`HDR_DST]);
    end endgenerate

    // ------------------------------------------------------------------
    // Output allocation: lock per output, round-robin among inputs
    // ------------------------------------------------------------------
    reg  [2:0] out_lock;                      // output is held by a packet
    reg  [1:0] out_owner [0:2];
    reg  [1:0] rr        [0:2];               // last input granted per output
    reg  [1:0] sel       [0:2];               // input sending on output o this cycle
    reg  [2:0] sel_v;

    integer o, k;
    reg [1:0] cand;
    always @(*) begin
        cand = 2'd0;
        for (o = 0; o < 3; o = o + 1) begin
            sel[o]   = out_owner[o];
            sel_v[o] = 1'b0;
            if (out_lock[o]) begin
                sel_v[o] = hvalid[out_owner[o]] && (in_route[out_owner[o]] == o);
            end else begin
                for (k = 2; k >= 0; k = k - 1) begin
                    cand = (rr[o] + 1 + k) % 3;
                    if (hvalid[cand] && in_route[cand] == o && !in_mid[cand]) begin
                        sel[o]   = cand;
                        sel_v[o] = 1'b1;
                    end
                end
            end
        end
    end

    // Outputs and pops
    reg [2:0] popr;
    always @(*) begin
        popr = 3'b000;
        for (o = 0; o < 3; o = o + 1)
            if (sel_v[o] && out_ready[o]) popr[sel[o]] = 1'b1;
    end
    assign pop = popr;

    generate for (p = 0; p < 3; p = p + 1) begin : outp
        assign out_flit[p*`LINK_W +: `LINK_W] = head[sel[p]];
        assign out_valid[p] = sel_v[p];
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_mid   <= 3'b000;
            out_lock <= 3'b000;
            for (o = 0; o < 3; o = o + 1) begin
                in_route_r[o] <= 2'd0;
                out_owner[o]  <= 2'd0;
                rr[o]         <= 2'd2;
            end
        end else begin
            for (o = 0; o < 3; o = o + 1) begin
                if (sel_v[o] && out_ready[o]) begin
                    if (head[sel[o]][`LINK_W-1]) begin          // tail: free the output
                        out_lock[o]     <= 1'b0;
                        in_mid[sel[o]]  <= 1'b0;
                    end else begin
                        out_lock[o]          <= 1'b1;
                        out_owner[o]         <= sel[o];
                        in_mid[sel[o]]       <= 1'b1;
                        in_route_r[sel[o]]   <= o[1:0];
                    end
                    if (!out_lock[o]) rr[o] <= sel[o];
                end
            end
        end
    end

endmodule
