`timescale 1ns / 1ps
// ============================================================================
// mesh_k.v - K x K mesh of mesh_router (scaling study model)
// ============================================================================
// One local inject/eject port per node. Router n's east output feeds router
// n+1's west input, and so on; ports at the mesh edge are tied off (XY
// routing never uses them).
// ============================================================================
module mesh_k #(parameter integer K = 3, parameter integer FW = 32) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire [K*K*FW-1:0] inj_flit,
    input  wire [K*K-1:0]    inj_valid,
    output wire [K*K-1:0]    inj_ready,
    output wire [K*K*FW-1:0] ej_flit,
    output wire [K*K-1:0]    ej_valid,
    input  wire [K*K-1:0]    ej_ready
);
    localparam integer N = K * K;
    wire [5*FW-1:0] i_f [0:N-1];
    wire [4:0]      i_v [0:N-1];
    wire [4:0]      i_r [0:N-1];
    wire [5*FW-1:0] o_f [0:N-1];
    wire [4:0]      o_v [0:N-1];
    wire [4:0]      o_r [0:N-1];
    genvar n;
    generate for (n = 0; n < N; n = n + 1) begin : node
        localparam integer X = n % K, Y = n / K;
        mesh_router #(.K(K), .NODE(n), .FW(FW)) u_r (
            .clk(clk), .rst_n(rst_n),
            .in_flit(i_f[n]), .in_valid(i_v[n]), .in_ready(i_r[n]),
            .out_flit(o_f[n]), .out_valid(o_v[n]), .out_ready(o_r[n]));
        // local port
        assign i_f[n][0 +: FW] = inj_flit[n*FW +: FW];
        assign i_v[n][0]       = inj_valid[n];
        assign inj_ready[n]    = i_r[n][0];
        assign ej_flit[n*FW +: FW] = o_f[n][0 +: FW];
        assign ej_valid[n]     = o_v[n][0];
        assign o_r[n][0]       = ej_ready[n];
        // west input <- east output of the node at x-1; east input <- west output of x+1
        if (X > 0) begin : w
            assign i_f[n][2*FW +: FW] = o_f[n-1][1*FW +: FW];
            assign i_v[n][2]          = o_v[n-1][1];
            assign o_r[n-1][1]        = i_r[n][2];
        end else begin : w0
            assign i_f[n][2*FW +: FW] = {FW{1'b0}}; assign i_v[n][2] = 1'b0; assign o_r[n][2] = 1'b1;
        end
        if (X < K - 1) begin : e
            assign i_f[n][1*FW +: FW] = o_f[n+1][2*FW +: FW];
            assign i_v[n][1]          = o_v[n+1][2];
            assign o_r[n+1][2]        = i_r[n][1];
        end else begin : e0
            assign i_f[n][1*FW +: FW] = {FW{1'b0}}; assign i_v[n][1] = 1'b0; assign o_r[n][1] = 1'b1;
        end
        // south input <- north output of the node at y-1; north input <- south output of y+1
        if (Y > 0) begin : s
            assign i_f[n][4*FW +: FW] = o_f[n-K][3*FW +: FW];
            assign i_v[n][4]          = o_v[n-K][3];
            assign o_r[n-K][3]        = i_r[n][4];
        end else begin : s0
            assign i_f[n][4*FW +: FW] = {FW{1'b0}}; assign i_v[n][4] = 1'b0; assign o_r[n][4] = 1'b1;
        end
        if (Y < K - 1) begin : nn
            assign i_f[n][3*FW +: FW] = o_f[n+K][4*FW +: FW];
            assign i_v[n][3]          = o_v[n+K][4];
            assign o_r[n+K][4]        = i_r[n][3];
        end else begin : n0
            assign i_f[n][3*FW +: FW] = {FW{1'b0}}; assign i_v[n][3] = 1'b0; assign o_r[n][3] = 1'b1;
        end
    end endgenerate
endmodule
