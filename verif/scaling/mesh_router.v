`timescale 1ns / 1ps
// ============================================================================
// mesh_router.v - 5-port wormhole router for a K x K mesh (scaling study)
// ============================================================================
// The same design rules as rtl/noc/noc_router.v (the SoC's 3-port router for
// the 2x2 mesh), generalised to any mesh size so the scaling study can run
// 3x3 and 4x4 meshes:
//   * XY (dimension-order) routing, so the mesh is deadlock free
//   * a 2-flit FIFO per input, valid/ready flow control on every link
//   * wormhole switching: an output stays with one packet until its tail
//   * free outputs given round-robin; one flit per output per cycle
// Ports: 0 local, 1 east (x+1), 2 west (x-1), 3 north (y+1), 4 south (y-1).
// Node n sits at x = n % K, y = n / K. Flit: [FW-1] tail, [FW-2 -: 8] dst
// (every flit of a packet carries the destination).
// This router is a model for the study in verif/scaling; the SoC does not
// use it.
// ============================================================================
module mesh_router #(
    parameter integer K    = 3,
    parameter integer NODE = 0,
    parameter integer FW   = 32
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [5*FW-1:0] in_flit,
    input  wire [4:0]      in_valid,
    output wire [4:0]      in_ready,
    output wire [5*FW-1:0] out_flit,
    output wire [4:0]      out_valid,
    input  wire [4:0]      out_ready
);
    localparam integer X = NODE % K, Y = NODE / K;

    wire [FW-1:0] head [0:4];
    wire [4:0]    hvalid;
    wire [4:0]    pop;
    genvar p;
    generate for (p = 0; p < 5; p = p + 1) begin : inq
        reg [FW-1:0] mem [0:1];
        reg          rd, wr;
        reg [1:0]    cnt;
        wire push = in_valid[p] && in_ready[p];
        assign in_ready[p] = (cnt != 2'd2);
        assign head[p]     = mem[rd];
        assign hvalid[p]   = (cnt != 2'd0);
        always @(posedge clk) if (push) mem[wr] <= in_flit[p*FW +: FW];
        always @(posedge clk or negedge rst_n)
            if (!rst_n) begin rd <= 1'b0; wr <= 1'b0; cnt <= 2'd0; end
            else begin
                if (push)   wr <= ~wr;
                if (pop[p]) rd <= ~rd;
                cnt <= cnt + {1'b0, push} - {1'b0, pop[p]};
            end
    end endgenerate

    function [2:0] xy_route(input [7:0] dst);
        integer dx, dy;
        begin
            dx = dst % K; dy = dst / K;
            if      (dx > X) xy_route = 3'd1;
            else if (dx < X) xy_route = 3'd2;
            else if (dy > Y) xy_route = 3'd3;
            else if (dy < Y) xy_route = 3'd4;
            else             xy_route = 3'd0;
        end
    endfunction

    reg  [4:0] in_mid;
    reg  [2:0] in_route_r [0:4];
    wire [2:0] in_route   [0:4];
    generate for (p = 0; p < 5; p = p + 1) begin : rt
        assign in_route[p] = in_mid[p] ? in_route_r[p] : xy_route(head[p][FW-2 -: 8]);
    end endgenerate

    reg  [4:0] out_lock;
    reg  [2:0] out_owner [0:4];
    reg  [2:0] rr        [0:4];
    reg  [2:0] sel       [0:4];
    reg  [4:0] sel_v;
    integer o, k;
    reg [2:0] cand;
    always @(*) begin
        cand = 3'd0;
        for (o = 0; o < 5; o = o + 1) begin
            sel[o] = out_owner[o]; sel_v[o] = 1'b0;
            if (out_lock[o])
                sel_v[o] = hvalid[out_owner[o]] && (in_route[out_owner[o]] == o);
            else
                for (k = 4; k >= 0; k = k - 1) begin
                    cand = (rr[o] + 1 + k) % 5;
                    if (hvalid[cand] && in_route[cand] == o && !in_mid[cand]) begin
                        sel[o] = cand; sel_v[o] = 1'b1;
                    end
                end
        end
    end
    reg [4:0] popr;
    always @(*) begin
        popr = 5'd0;
        for (o = 0; o < 5; o = o + 1)
            if (sel_v[o] && out_ready[o]) popr[sel[o]] = 1'b1;
    end
    assign pop = popr;
    generate for (p = 0; p < 5; p = p + 1) begin : outp
        assign out_flit[p*FW +: FW] = head[sel[p]];
        assign out_valid[p] = sel_v[p];
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_mid <= 5'd0; out_lock <= 5'd0;
            for (o = 0; o < 5; o = o + 1) begin in_route_r[o] <= 3'd0; out_owner[o] <= 3'd0; rr[o] <= 3'd4; end
        end else
            for (o = 0; o < 5; o = o + 1)
                if (sel_v[o] && out_ready[o]) begin
                    if (head[sel[o]][FW-1]) begin
                        out_lock[o] <= 1'b0; in_mid[sel[o]] <= 1'b0;
                    end else begin
                        out_lock[o] <= 1'b1; out_owner[o] <= sel[o];
                        in_mid[sel[o]] <= 1'b1; in_route_r[sel[o]] <= o[2:0];
                    end
                    if (!out_lock[o]) rr[o] <= sel[o];
                end
    end

`ifdef SIM
    // A packet leaves on the local port only at its destination
    always @(posedge clk) if (rst_n && out_valid[0] && out_ready[0])
        assert (out_flit[FW-2 -: 8] == NODE)
        else begin $display("ERROR SVA mesh_router %0d: packet for node %0d delivered here", NODE, out_flit[FW-2 -: 8]); $fatal(1); end
`endif
endmodule
