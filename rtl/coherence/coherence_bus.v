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
    assign sc_snoop_data       = (snoop_data_valid[0] && resp0 == `SNOOP_HITM) ? snoop_data_flat[255:0]    :
                                 (snoop_data_valid[1] && resp1 == `SNOOP_HITM) ? snoop_data_flat[511:256]  :
                                 (snoop_data_valid[2] && resp2 == `SNOOP_HITM) ? snoop_data_flat[767:512]  :
                                 (snoop_data_valid[3] && resp3 == `SNOOP_HITM) ? snoop_data_flat[1023:768] :
                                 snoop_data_valid[0]                           ? snoop_data_flat[255:0]    :
                                 snoop_data_valid[1]                           ? snoop_data_flat[511:256]  :
                                 snoop_data_valid[2]                           ? snoop_data_flat[767:512]  :
                                 snoop_data_valid[3]                           ? snoop_data_flat[1023:768] :
                                                                                 256'd0;
    
    // Mux core requests based on arb_grant
    always @(*) begin
        sc_req_valid   = 1'b0;
        sc_req_cmd     = 3'b000;
        sc_req_addr    = 32'b0;
        sc_req_wdata   = 256'b0;
        sc_req_core_id = 2'b00;
        
        if (arb_grant[0]) begin
            sc_req_valid   = core_bus_req[0];
            sc_req_cmd     = core_bus_cmd[2:0];
            sc_req_addr    = core_bus_addr[31:0];
            sc_req_wdata   = core_bus_wdata[255:0];
            sc_req_core_id = 2'd0;
        end else if (arb_grant[1]) begin
            sc_req_valid   = core_bus_req[1];
            sc_req_cmd     = core_bus_cmd[5:3];
            sc_req_addr    = core_bus_addr[63:32];
            sc_req_wdata   = core_bus_wdata[511:256];
            sc_req_core_id = 2'd1;
        end else if (arb_grant[2]) begin
            sc_req_valid   = core_bus_req[2];
            sc_req_cmd     = core_bus_cmd[8:6];
            sc_req_addr    = core_bus_addr[95:64];
            sc_req_wdata   = core_bus_wdata[767:512];
            sc_req_core_id = 2'd2;
        end else if (arb_grant[3]) begin
            sc_req_valid   = core_bus_req[3];
            sc_req_cmd     = core_bus_cmd[11:9];
            sc_req_addr    = core_bus_addr[127:96];
            sc_req_wdata   = core_bus_wdata[1023:768];
            sc_req_core_id = 2'd3;
        end
    end

`ifdef SIM
    always @(posedge clk) begin
        if (sc_req_valid) $display("[Coherence Bus] Muxed req from core %0d, addr: %h", sc_req_core_id, sc_req_addr);
    end
`endif

endmodule
