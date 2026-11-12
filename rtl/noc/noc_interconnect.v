`timescale 1ns / 1ps
// ============================================================================
// noc_interconnect.v - 2x2 mesh NoC + directory, behind the common L1 port
// ============================================================================
// Drop-in replacement for bus_interconnect (build with NOC=1 / +define+NOC).
// Same L1 ports (rtl/coherence/coh_port.vh), same L2 port.
//
//   core n's network interface (noc_ni) sits at mesh node n
//   NBANKS = 1: one directory home (dir_home) at node 0, talking to the L2
//   NBANKS = 4: a home at every node for a quarter of the lines; the four
//               homes share the one L2 through a round-robin port arbiter
//
// Three meshes: REQ (core -> home), RSP (probe answers, core -> home) and
// OUT (probes and grants, home -> core).
// ============================================================================

`include "mesi_defines.vh"
`include "noc_defs.vh"

module noc_interconnect #(
    parameter NBANKS = 1
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire [3:0]    l1_req,
    input  wire [11:0]   l1_cmd,
    input  wire [127:0]  l1_addr,
    input  wire [1023:0] l1_wdata,
    input  wire [3:0]    l1_ifetch,
    input  wire [3:0]    l1_way,
    output wire [3:0]    l1_ack,
    output wire [1023:0] l1_rdata,
    output wire [3:0]    l1_shared,
    output wire [3:0]    l1_busy,

    output wire [3:0]    pr_valid,
    output wire [127:0]  pr_addr,
    output wire [11:0]   pr_cmd,
    input  wire [7:0]    pr_resp,
    input  wire [1023:0] pr_data,
    input  wire [3:0]    pr_dvalid,

    output wire          l2_req_valid,
    output wire [31:0]   l2_req_addr,
    output wire [2:0]    l2_req_cmd,
    output wire [255:0]  l2_req_wdata,
    input  wire [255:0]  l2_resp_data,
    input  wire          l2_resp_valid
);

    localparam LW = `LINK_W;

    // Network wires: inject / eject per node for each of the three meshes
    wire [4*LW-1:0] req_inj, req_ej, rsp_inj, rsp_ej, out_inj, out_ej;
    wire [3:0] req_inj_v, req_inj_r, req_ej_v, req_ej_r;
    wire [3:0] rsp_inj_v, rsp_inj_r, rsp_ej_v, rsp_ej_r;
    wire [3:0] out_inj_v, out_inj_r, out_ej_v, out_ej_r;

    noc_mesh u_req_net (.clk(clk), .rst_n(rst_n),
        .inj_flit(req_inj), .inj_valid(req_inj_v), .inj_ready(req_inj_r),
        .ej_flit(req_ej), .ej_valid(req_ej_v), .ej_ready(req_ej_r));
    noc_mesh u_rsp_net (.clk(clk), .rst_n(rst_n),
        .inj_flit(rsp_inj), .inj_valid(rsp_inj_v), .inj_ready(rsp_inj_r),
        .ej_flit(rsp_ej), .ej_valid(rsp_ej_v), .ej_ready(rsp_ej_r));
    noc_mesh u_out_net (.clk(clk), .rst_n(rst_n),
        .inj_flit(out_inj), .inj_valid(out_inj_v), .inj_ready(out_inj_r),
        .ej_flit(out_ej), .ej_valid(out_ej_v), .ej_ready(out_ej_r));

    // Per-home L2 ports (only NBANKS of them used)
    wire [3:0]   h_l2_valid;
    wire [31:0]  h_l2_addr  [0:3];
    wire [2:0]   h_l2_cmd   [0:3];
    wire [255:0] h_l2_wdata [0:3];
    wire [3:0]   h_l2_resp;

    genvar n;
    generate for (n = 0; n < 4; n = n + 1) begin : tile
        noc_ni #(.CORE(n), .NBANKS(NBANKS), .HOME0(2'd0)) u_ni (
            .clk      (clk),
            .rst_n    (rst_n),
            .l1_req   (l1_req[n]),
            .l1_cmd   (l1_cmd[n*3 +: 3]),
            .l1_addr  (l1_addr[n*32 +: 32]),
            .l1_wdata (l1_wdata[n*256 +: 256]),
            .l1_ifetch(l1_ifetch[n]),
            .l1_way   (l1_way[n]),
            .l1_ack   (l1_ack[n]),
            .l1_rdata (l1_rdata[n*256 +: 256]),
            .l1_shared(l1_shared[n]),
            .l1_busy  (l1_busy[n]),
            .pr_valid (pr_valid[n]),
            .pr_addr  (pr_addr[n*32 +: 32]),
            .pr_cmd   (pr_cmd[n*3 +: 3]),
            .pr_resp  (pr_resp[n*2 +: 2]),
            .pr_data  (pr_data[n*256 +: 256]),
            .pr_dvalid(pr_dvalid[n]),
            .req_flit (req_inj[n*LW +: LW]), .req_valid(req_inj_v[n]), .req_ready(req_inj_r[n]),
            .rsp_flit (rsp_inj[n*LW +: LW]), .rsp_valid(rsp_inj_v[n]), .rsp_ready(rsp_inj_r[n]),
            .out_flit (out_ej[n*LW +: LW]),  .out_valid(out_ej_v[n]),  .out_ready(out_ej_r[n])
        );

        if (NBANKS == 4 || n == 0) begin : home
            dir_home #(.NODE(n), .NBANKS(NBANKS)) u_home (
                .clk          (clk),
                .rst_n        (rst_n),
                .req_flit     (req_ej[n*LW +: LW]), .req_valid(req_ej_v[n]), .req_ready(req_ej_r[n]),
                .rsp_flit     (rsp_ej[n*LW +: LW]), .rsp_valid(rsp_ej_v[n]), .rsp_ready(rsp_ej_r[n]),
                .out_flit     (out_inj[n*LW +: LW]), .out_valid(out_inj_v[n]), .out_ready(out_inj_r[n]),
                .l2_req_valid (h_l2_valid[n]),
                .l2_req_addr  (h_l2_addr[n]),
                .l2_req_cmd   (h_l2_cmd[n]),
                .l2_req_wdata (h_l2_wdata[n]),
                .l2_resp_data (l2_resp_data),
                .l2_resp_valid(h_l2_resp[n])
            );
        end else begin : nohome
            assign req_ej_r[n] = 1'b1;
            assign rsp_ej_r[n] = 1'b1;
            assign out_inj[n*LW +: LW] = {LW{1'b0}};
            assign out_inj_v[n] = 1'b0;
            assign h_l2_valid[n] = 1'b0;
            assign h_l2_addr[n]  = 32'd0;
            assign h_l2_cmd[n]   = 3'd0;
            assign h_l2_wdata[n] = 256'd0;
        end
    end endgenerate

    // ------------------------------------------------------------------
    // L2 port: one home, or round-robin among four. A home keeps its
    // request up until the L2 answers; the port then moves on.
    // ------------------------------------------------------------------
    reg       l2_busy;
    reg [1:0] l2_sel, l2_last;
    reg [1:0] pick;
    integer k;
    always @(*) begin
        pick = l2_last;
        for (k = 3; k >= 1; k = k - 1)
            if (h_l2_valid[(l2_last + k) % 4]) pick = (l2_last + k) % 4;
    end
    wire [1:0] cur = l2_busy ? l2_sel : pick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_busy <= 1'b0; l2_sel <= 2'd0; l2_last <= 2'd3;
        end else if (!l2_busy) begin
            if (|h_l2_valid) begin
                l2_busy <= 1'b1; l2_sel <= pick; l2_last <= pick;
            end
        end else if (l2_resp_valid) begin
            l2_busy <= 1'b0;
        end
    end

    assign l2_req_valid = l2_busy ? h_l2_valid[l2_sel] : 1'b0;
    assign l2_req_addr  = h_l2_addr[cur];
    assign l2_req_cmd   = h_l2_cmd[cur];
    assign l2_req_wdata = h_l2_wdata[cur];
    generate for (n = 0; n < 4; n = n + 1) begin : l2resp
        assign h_l2_resp[n] = l2_resp_valid && l2_busy && (l2_sel == n);
    end endgenerate

endmodule
