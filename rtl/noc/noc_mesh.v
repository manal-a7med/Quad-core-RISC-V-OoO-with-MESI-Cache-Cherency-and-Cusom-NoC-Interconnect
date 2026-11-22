`timescale 1ns / 1ps
// ============================================================================
// noc_mesh.v - one 2x2 mesh network (four noc_routers)
// ============================================================================
//      node 2 ---- node 3        node n sits at x = n[0], y = n[1]
//        |           |           X links: 0-1, 2-3
//      node 0 ---- node 1        Y links: 0-2, 1-3
//
// Each node has one local input (inject) and one local output (eject).
// The NoC build uses three of these networks (REQ, RSP, OUT).
// ============================================================================

`include "noc_defs.vh"

module noc_mesh (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [4*`LINK_W-1:0] inj_flit,    // node n in [n*LINK_W +: LINK_W]
    input  wire [3:0]           inj_valid,
    output wire [3:0]           inj_ready,
    output wire [4*`LINK_W-1:0] ej_flit,
    output wire [3:0]           ej_valid,
    input  wire [3:0]           ej_ready
);

    // Router n port p: in/out flit, valid, ready
    wire [3*`LINK_W-1:0] r_in_flit  [0:3];
    wire [2:0]           r_in_valid [0:3];
    wire [2:0]           r_in_ready [0:3];
    wire [3*`LINK_W-1:0] r_out_flit [0:3];
    wire [2:0]           r_out_valid[0:3];
    wire [2:0]           r_out_ready[0:3];

    genvar n;
    generate for (n = 0; n < 4; n = n + 1) begin : node
        // port 0: local
        assign r_in_flit[n][0 +: `LINK_W]  = inj_flit[n*`LINK_W +: `LINK_W];
        assign r_in_valid[n][0]            = inj_valid[n];
        assign inj_ready[n]                = r_in_ready[n][0];
        assign ej_flit[n*`LINK_W +: `LINK_W] = r_out_flit[n][0 +: `LINK_W];
        assign ej_valid[n]                 = r_out_valid[n][0];
        assign r_out_ready[n][0]           = ej_ready[n];

        // port 1: X neighbour (n ^ 1), port 2: Y neighbour (n ^ 2)
        assign r_in_flit[n][1*`LINK_W +: `LINK_W] = r_out_flit[n ^ 1][1*`LINK_W +: `LINK_W];
        assign r_in_valid[n][1]                   = r_out_valid[n ^ 1][1];
        assign r_out_ready[n][1]                  = r_in_ready[n ^ 1][1];
        assign r_in_flit[n][2*`LINK_W +: `LINK_W] = r_out_flit[n ^ 2][2*`LINK_W +: `LINK_W];
        assign r_in_valid[n][2]                   = r_out_valid[n ^ 2][2];
        assign r_out_ready[n][2]                  = r_in_ready[n ^ 2][2];

        noc_router #(.NODE(n)) u_router (
            .clk      (clk),
            .rst_n    (rst_n),
            .in_flit  (r_in_flit[n]),
            .in_valid (r_in_valid[n]),
            .in_ready (r_in_ready[n]),
            .out_flit (r_out_flit[n]),
            .out_valid(r_out_valid[n]),
            .out_ready(r_out_ready[n])
        );
    end endgenerate

endmodule
