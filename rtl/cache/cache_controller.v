`timescale 1ns / 1ps
`include "common_defs.vh"
`include "mesi_defines.vh"

module cache_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  core_id,

    // CPU side
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    output reg  [31:0] cpu_rdata,
    input  wire        cpu_req,
    input  wire        cpu_wr,
    output reg         cpu_ack,
    input  wire [2:0]  cpu_mem_type,

    // Bus side
    output reg         bus_req,
    output reg  [2:0]  bus_cmd,
    output reg  [31:0] bus_addr,
    output reg  [255:0] bus_wdata,
    input  wire [255:0] bus_rdata,
    input  wire        bus_ack,
    input  wire        bus_grant,

    // Snoop side
    input  wire [31:0] snoop_addr,
    input  wire [2:0]  snoop_cmd,
    input  wire        snoop_valid,
    output reg  [1:0]  snoop_resp,
    output reg  [255:0] snoop_data,
    output reg         snoop_data_valid
);

    // FSM States
    localparam IDLE = 2'd0;
    localparam ACTIVE = 2'd1;

    reg [1:0] state, next_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else state <= next_state;
    end

    always @(*) begin
        next_state = state;
        cpu_ack = 1'b0;
        bus_req = 1'b0;
        
        case (state)
            IDLE: begin
                if (cpu_req) next_state = ACTIVE;
            end
            ACTIVE: begin
                cpu_ack = 1'b1;
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

endmodule
