`timescale 1ns / 1ps
`include "mesi_defines.vh"
`include "common_defs.vh"

module snoop_controller (
    input  wire         clk,
    input  wire         rst_n,
    
    // Arbiter interface
    input  wire [3:0]   grant,
    input  wire         bus_busy,
    output reg          bus_release,
    
    // Requester interface
    input  wire         req_valid,
    input  wire [2:0]   req_cmd,
    input  wire [31:0]  req_addr,
    input  wire [255:0] req_wdata,
    input  wire [1:0]   req_core_id,
    
    // Snoop interface to all 4 cores
    output reg  [3:0]   snoop_valid,
    output reg  [31:0]  snoop_addr,
    output reg  [2:0]   snoop_cmd,
    input  wire [7:0]   snoop_resp,         // 4x 2-bit responses
    input  wire [255:0] snoop_data,
    input  wire [3:0]   snoop_data_valid,
    
    // L2 Cache interface
    output reg          l2_req_valid,
    output reg  [31:0]  l2_req_addr,
    output reg  [2:0]   l2_req_cmd,
    output reg  [255:0] l2_req_wdata,
    input  wire [255:0] l2_resp_data,
    input  wire         l2_resp_valid,
    
    // Response back to requester
    output reg          resp_valid,
    output reg  [255:0] resp_data,
    output reg          resp_shared
);

    localparam IDLE              = 3'b000;
    localparam BROADCAST_SNOOP   = 3'b001;
    localparam COLLECT_RESPONSES = 3'b010;
    localparam WAIT_L2           = 3'b011;
    localparam SUPPLY_DATA       = 3'b100;
    localparam COMPLETE          = 3'b101;

    reg [2:0]   state, next_state;
    reg         hit, hitm;
    reg [255:0] saved_resp_data;
    reg         saved_resp_shared;
    reg         saved_from_snoop;

    wire [3:0]  snoop_mask = ~(4'b0001 << req_core_id);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= IDLE;
            saved_resp_data   <= 256'd0;
            saved_resp_shared <= 1'b0;
            saved_from_snoop  <= 1'b0;
        end else begin
            state <= next_state;

            if (state == IDLE && req_valid && bus_busy) begin
                saved_resp_shared <= 1'b0;
                saved_from_snoop  <= 1'b0;
            end else if (state == COLLECT_RESPONSES) begin
                saved_resp_shared <= hit | hitm;
                if (hitm && |(snoop_data_valid & snoop_mask)) begin
                    saved_resp_data  <= snoop_data;
                    saved_from_snoop <= 1'b1;
                end else begin
                    saved_from_snoop <= 1'b0;
                end
            end else if (state == WAIT_L2 && l2_resp_valid) begin
                if (!saved_from_snoop) begin
                    saved_resp_data <= l2_resp_data;
                end
            end
        end
    end

    always @(*) begin
        next_state   = state;
        snoop_valid  = 4'b0000;
        snoop_addr   = req_addr;
        snoop_cmd    = req_cmd;
        l2_req_valid = 1'b0;
        l2_req_addr  = req_addr;
        l2_req_cmd   = req_cmd;
        l2_req_wdata = req_wdata;
        resp_valid   = 1'b0;
        resp_data    = saved_resp_data;
        resp_shared  = saved_resp_shared;
        bus_release  = 1'b0;
        hit          = 1'b0;
        hitm         = 1'b0;

        case (state)
            IDLE: begin
                if (req_valid && bus_busy) begin
                    if (req_cmd == `BUS_FLUSH) begin
                        l2_req_valid = 1'b1;
                        next_state   = WAIT_L2;
                    end else begin
                        next_state = BROADCAST_SNOOP;
                    end
                end
            end
            
            BROADCAST_SNOOP: begin
                snoop_valid = snoop_mask; // Snoop everyone except requester
                next_state  = COLLECT_RESPONSES;
            end
            
            COLLECT_RESPONSES: begin
                // Evaluate responses from snooped cores (01=HIT, 10=HITM)
                hit  = (snoop_mask[0] && (snoop_resp[1:0] == `SNOOP_HIT)) |
                       (snoop_mask[1] && (snoop_resp[3:2] == `SNOOP_HIT)) |
                       (snoop_mask[2] && (snoop_resp[5:4] == `SNOOP_HIT)) |
                       (snoop_mask[3] && (snoop_resp[7:6] == `SNOOP_HIT));
                hitm = (snoop_mask[0] && (snoop_resp[1:0] == `SNOOP_HITM)) |
                       (snoop_mask[1] && (snoop_resp[3:2] == `SNOOP_HITM)) |
                       (snoop_mask[2] && (snoop_resp[5:4] == `SNOOP_HITM)) |
                       (snoop_mask[3] && (snoop_resp[7:6] == `SNOOP_HITM));
                
                resp_shared = hit | hitm;
                
                if (req_cmd == `BUS_UPGR) begin
                    next_state = SUPPLY_DATA;
                end else if (hitm && |(snoop_data_valid & snoop_mask)) begin
                    if (req_cmd == `BUS_READ) begin
                        // Update L2 with dirty data as line transitions M -> S
                        l2_req_valid = 1'b1;
                        l2_req_cmd   = `BUS_FLUSH;
                        l2_req_wdata = snoop_data;
                        next_state   = WAIT_L2;
                    end else begin
                        // Direct cache-to-cache transfer on BusRdX (new owner is M)
                        next_state = SUPPLY_DATA;
                    end
                end else begin
                    l2_req_valid = 1'b1;
                    next_state   = WAIT_L2;
                end
            end
            
            WAIT_L2: begin
                l2_req_valid = !l2_resp_valid;
                if (saved_from_snoop) begin
                    l2_req_cmd   = `BUS_FLUSH;
                    l2_req_wdata = saved_resp_data;
                end
                if (l2_resp_valid) begin
                    next_state = SUPPLY_DATA;
                end
            end
            
            SUPPLY_DATA: begin
                resp_valid  = 1'b1;
                resp_data   = saved_resp_data;
                resp_shared = saved_resp_shared;
                next_state  = COMPLETE;
            end
            
            COMPLETE: begin
                bus_release = 1'b1;
                next_state  = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
`ifdef SIM
    always @(posedge clk) begin
        if (state != next_state) $display("[Snoop Controller] State: %0d -> %0d", state, next_state);
    end
`endif

endmodule
