`timescale 1ns / 1ps
// ============================================================================
// bus_interconnect.v - snooping-bus interconnect behind the common L1 port
// ============================================================================
// The four L1 data caches reach the rest of the memory system through one
// "L1 coherence port" each (see coh_port.vh for the full contract). The same
// port is served by two interconnects, chosen when the SoC is built:
//
//   bus_interconnect  (default)  coherence bus + round-robin arbiter + snoop
//                                controller; every request is broadcast to
//                                the other caches
//   noc_interconnect  (NOC=1)    2x2 mesh network + directory; requests go
//                                only to the caches that hold the line
//
// Both send their L2 traffic through the same L2 port, so the L2, memory
// controller and main memory are shared by the two builds.
//
// This module is only a wrapper: the bus logic is the original
// coherence_bus, bus_arbiter and snoop_controller, unchanged.
// ============================================================================

`include "mesi_defines.vh"
`include "common_defs.vh"

module bus_interconnect (
    input  wire          clk,
    input  wire          rst_n,

    // L1 coherence ports, core n in bits [n*W +: W]
    input  wire [3:0]    l1_req,          // request held until l1_ack
    input  wire [11:0]   l1_cmd,          // `BUS_READ / READX / UPGR / FLUSH
    input  wire [127:0]  l1_addr,         // line address
    input  wire [1023:0] l1_wdata,        // line data (BUS_FLUSH)
    input  wire [3:0]    l1_ifetch,       // I-cache line fetch: also probe the requester
    input  wire [3:0]    l1_way,          // L1 way of the fill / write-back (unused by the bus)
    output wire [3:0]    l1_ack,          // one-cycle completion
    output wire [1023:0] l1_rdata,        // line data, valid with l1_ack
    output wire [3:0]    l1_shared,       // another cache keeps a copy (valid with l1_ack)
    output wire [3:0]    l1_busy,         // port still finishing a transaction

    // Probe side of the same ports (snoops into the L1s)
    output wire [3:0]    pr_valid,
    output wire [127:0]  pr_addr,
    output wire [11:0]   pr_cmd,
    input  wire [7:0]    pr_resp,         // `SNOOP_*, cycle after pr_valid
    input  wire [1023:0] pr_data,
    input  wire [3:0]    pr_dvalid,

    // L2 port
    output wire          l2_req_valid,
    output wire [31:0]   l2_req_addr,
    output wire [2:0]    l2_req_cmd,
    output wire [255:0]  l2_req_wdata,
    input  wire [255:0]  l2_resp_data,
    input  wire          l2_resp_valid
);

    wire [3:0]   arb_req, arb_grant;
    wire         arb_busy, arb_release;
    wire [1:0]   arb_owner;

    wire         sc_req_valid;
    wire [2:0]   sc_req_cmd;
    wire [31:0]  sc_req_addr;
    wire [255:0] sc_req_wdata;
    wire [1:0]   sc_req_core_id;
    wire         sc_resp_valid;
    wire [255:0] sc_resp_data;
    wire         sc_resp_shared;

    wire [3:0]   sc_snoop_valid;
    wire [31:0]  sc_snoop_addr;
    wire [2:0]   sc_snoop_cmd;
    wire [7:0]   sc_snoop_resp;
    wire [255:0] sc_snoop_data;
    wire [3:0]   sc_snoop_dvalid;

    wire [255:0] rdata_bc;
    wire         shared_bc;
    wire [31:0]  snoop_addr_bc;
    wire [2:0]   snoop_cmd_bc;

    coherence_bus u_coh_bus (
        .clk                (clk),
        .rst_n              (rst_n),
        .core_bus_req       (l1_req),
        .core_bus_cmd       (l1_cmd),
        .core_bus_addr      (l1_addr),
        .core_bus_wdata     (l1_wdata),
        .core_bus_grant     (l1_busy),
        .core_bus_ack       (l1_ack),
        .core_bus_rdata     (rdata_bc),
        .core_bus_shared    (shared_bc),
        .sc_snoop_valid     (sc_snoop_valid),
        .sc_snoop_addr      (sc_snoop_addr),
        .sc_snoop_cmd       (sc_snoop_cmd),
        .snoop_valid        (pr_valid),
        .snoop_addr         (snoop_addr_bc),
        .snoop_cmd          (snoop_cmd_bc),
        .snoop_resp         (pr_resp),
        .snoop_data_flat    (pr_data),
        .snoop_data_valid   (pr_dvalid),
        .sc_snoop_resp      (sc_snoop_resp),
        .sc_snoop_data      (sc_snoop_data),
        .sc_snoop_data_valid(sc_snoop_dvalid),
        .arb_req            (arb_req),
        .arb_grant          (arb_grant),
        .arb_busy           (arb_busy),
        .arb_release        (arb_release),
        .sc_req_valid       (sc_req_valid),
        .sc_req_cmd         (sc_req_cmd),
        .sc_req_addr        (sc_req_addr),
        .sc_req_wdata       (sc_req_wdata),
        .sc_req_core_id     (sc_req_core_id),
        .sc_resp_valid      (sc_resp_valid),
        .sc_resp_data       (sc_resp_data),
        .sc_resp_shared     (sc_resp_shared)
    );

    // The bus broadcasts one data word, one shared bit and one snoop address
    assign l1_rdata  = {4{rdata_bc}};
    assign l1_shared = {4{shared_bc}};
    assign pr_addr   = {4{snoop_addr_bc}};
    assign pr_cmd    = {4{snoop_cmd_bc}};

    bus_arbiter u_arbiter (
        .clk          (clk),
        .rst_n        (rst_n),
        .req          (arb_req),
        .grant        (arb_grant),
        .bus_busy     (arb_busy),
        .bus_release  (arb_release),
        .current_owner(arb_owner)
    );

    snoop_controller u_snoop (
        .clk             (clk),
        .rst_n           (rst_n),
        .grant           (arb_grant),
        .bus_busy        (arb_busy),
        .req_valid       (sc_req_valid),
        .req_cmd         (sc_req_cmd),
        .req_addr        (sc_req_addr),
        .req_wdata       (sc_req_wdata),
        .req_core_id     (sc_req_core_id),
        .req_snoop_all   (l1_ifetch[sc_req_core_id]),
        .snoop_valid     (sc_snoop_valid),
        .snoop_addr      (sc_snoop_addr),
        .snoop_cmd       (sc_snoop_cmd),
        .snoop_resp      (sc_snoop_resp),
        .snoop_data      (sc_snoop_data),
        .snoop_data_valid(sc_snoop_dvalid),
        .l2_req_valid    (l2_req_valid),
        .l2_req_addr     (l2_req_addr),
        .l2_req_cmd      (l2_req_cmd),
        .l2_req_wdata    (l2_req_wdata),
        .l2_resp_data    (l2_resp_data),
        .l2_resp_valid   (l2_resp_valid),
        .resp_valid      (sc_resp_valid),
        .resp_data       (sc_resp_data),
        .resp_shared     (sc_resp_shared),
        .bus_release     (arb_release)
    );

endmodule
