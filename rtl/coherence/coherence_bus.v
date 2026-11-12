`timescale 1ns / 1ps
`include "mesi_defines.vh"
`include "common_defs.vh"

module coherence_bus (
    input  wire           clk,
    input  wire           rst_n,
    
    // Core Interfaces (Flattened)
    input  wire [3:0]     core_bus_req,
    input  wire [11:0]    core_bus_cmd,    // 4 x 3-bit
    input  wire [127:0]   core_bus_addr,   // 4 x 32-bit
    input  wire [1023:0]  core_bus_wdata,  // 4 x 256-bit
    
    output wire [3:0]     core_bus_grant,
    output wire [3:0]     core_bus_ack,
    output wire [255:0]   core_bus_rdata,  // Broadcast read data
    output wire           core_bus_shared, // Broadcast shared indicator
    
    // Snoop broadcast to cores (from snoop controller)
    input  wire [3:0]     sc_snoop_valid,
    input  wire [31:0]    sc_snoop_addr,
    input  wire [2:0]     sc_snoop_cmd,
    output wire [3:0]     snoop_valid,
    output wire [31:0]    snoop_addr,
    output wire [2:0]     snoop_cmd,
    
    // Snoop responses from cores (to snoop controller)
    input  wire [7:0]     snoop_resp,      // 4 x 2-bit
    input  wire [1023:0]  snoop_data_flat, // 4 x 256-bit
    input  wire [3:0]     snoop_data_valid,
    output wire [7:0]     sc_snoop_resp,
    output wire [255:0]   sc_snoop_data,
    output wire [3:0]     sc_snoop_data_valid,
    
    // To Arbiter
    output wire [3:0]     arb_req,
    input  wire [3:0]     arb_grant,
    input  wire           arb_busy,
    input  wire           arb_release,
    
    // To Snoop Controller
    output reg            sc_req_valid,
    output reg  [2:0]     sc_req_cmd,
    output reg  [31:0]    sc_req_addr,
    output reg  [255:0]   sc_req_wdata,
    output reg  [1:0]     sc_req_core_id,
    
    input  wire           sc_resp_valid,
    input  wire [255:0]   sc_resp_data,
    input  wire           sc_resp_shared
);

    // Arbiter connections
    assign arb_req         = core_bus_req;
    assign core_bus_grant  = arb_grant;
    
    // Broadcast sc_resp to all cores; each core masks with its own grant
    assign core_bus_ack    = {4{sc_resp_valid}} & arb_grant; 
    assign core_bus_rdata  = sc_resp_data;
    assign core_bus_shared = sc_resp_shared;

    // Forward snoop broadcast to cores
    assign snoop_valid = sc_snoop_valid;
    assign snoop_addr  = sc_snoop_addr;
    assign snoop_cmd   = sc_snoop_cmd;

    // Mux snoop response data from whichever snooped core has valid data (prefer HITM responder)
    wire [1:0] resp0 = snoop_resp[1:0];
    wire [1:0] resp1 = snoop_resp[3:2];
    wire [1:0] resp2 = snoop_resp[5:4];
    wire [1:0] resp3 = snoop_resp[7:6];

    assign sc_snoop_resp       = snoop_resp;
    assign sc_snoop_data_valid = snoop_data_valid;
    // Data from the snooped cache that answered HITM (at most one cache holds
    // a line Modified). AND-OR select: cheaper than a priority mux at 256 bits.
    wire [3:0] hitm_sel = snoop_data_valid & {resp3 == `SNOOP_HITM, resp2 == `SNOOP_HITM,
                                              resp1 == `SNOOP_HITM, resp0 == `SNOOP_HITM};
    assign sc_snoop_data = ({256{hitm_sel[0]}} & snoop_data_flat[255:0])   |
                           ({256{hitm_sel[1]}} & snoop_data_flat[511:256]) |
                           ({256{hitm_sel[2]}} & snoop_data_flat[767:512]) |
                           ({256{hitm_sel[3]}} & snoop_data_flat[1023:768]);
    
    // Mux core requests based on arb_grant
    // Granted core's request. The grant is one-hot, so encode it once and
    // use plain 4:1 muxes (one LUT per bit) for the 256-bit write data.
    wire [1:0] gnt_id = arb_grant[1] ? 2'd1 : arb_grant[2] ? 2'd2 : arb_grant[3] ? 2'd3 : 2'd0;
    always @(*) begin
        sc_req_valid   = |(arb_grant & core_bus_req);
        sc_req_cmd     = core_bus_cmd[gnt_id*3 +: 3];
        sc_req_addr    = core_bus_addr[gnt_id*32 +: 32];
        sc_req_wdata   = core_bus_wdata[gnt_id*256 +: 256];
        sc_req_core_id = gnt_id;
    end

`ifdef BUS_DEBUG   // +define+BUS_DEBUG for a transaction log
    always @(posedge clk) begin
        if (sc_req_valid) $display("[Coherence Bus] Muxed req from core %0d, addr: %h", sc_req_core_id, sc_req_addr);
    end
`endif

endmodule
