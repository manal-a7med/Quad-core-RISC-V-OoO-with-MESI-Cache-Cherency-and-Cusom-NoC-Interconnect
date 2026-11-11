`timescale 1ns / 1ps
// ============================================================================
// memory_controller.v — Memory Controller
// ============================================================================
// Interfaces the shared L2 cache with main memory.
// Handles read and write requests with proper handshaking.
// Supports one outstanding request at a time.
// ============================================================================

`include "common_defs.vh"
`include "mesi_defines.vh"

module memory_controller (
    input  wire                        clk,
    input  wire                        rst_n,

    // ========================================================================
    // L2 Cache Interface (upstream)
    // ========================================================================
    input  wire                        l2_req,
    input  wire                        l2_wr,
    input  wire [`ADDR_WIDTH-1:0]      l2_addr,
    input  wire [`BUS_DATA_WIDTH-1:0]  l2_wdata,
    output reg  [`BUS_DATA_WIDTH-1:0]  l2_rdata,
    output reg                         l2_ack,

    // ========================================================================
    // Main Memory Interface (downstream)
    // ========================================================================
    output reg  [`ADDR_WIDTH-1:0]      mem_addr,
    output reg  [`BUS_DATA_WIDTH-1:0]  mem_wdata,
    input  wire [`BUS_DATA_WIDTH-1:0]  mem_rdata,
    output reg                         mem_req,
    output reg                         mem_wr,
    input  wire                        mem_ack
);

    // ========================================================================
    // FSM States
    // ========================================================================
    localparam [1:0]
        IDLE       = 2'b00,
        REQ_SENT   = 2'b01,
        WAIT_ACK   = 2'b10,
        RESPOND    = 2'b11;

    reg [1:0] state, next_state;

    // Latched request
    reg                        req_wr_r;
    reg [`ADDR_WIDTH-1:0]      req_addr_r;
    reg [`BUS_DATA_WIDTH-1:0]  req_wdata_r;

    // ========================================================================
    // FSM — State Register
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // ========================================================================
    // FSM — Next State Logic
    // ========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (l2_req)
                    next_state = REQ_SENT;
            end

            REQ_SENT: begin
                next_state = WAIT_ACK;
            end

            WAIT_ACK: begin
                if (mem_ack)
                    next_state = RESPOND;
            end

            RESPOND: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // ========================================================================
    // FSM — Output Logic
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_req     <= 1'b0;
            mem_wr      <= 1'b0;
            mem_addr    <= {`ADDR_WIDTH{1'b0}};
            mem_wdata   <= {`BUS_DATA_WIDTH{1'b0}};
            l2_ack      <= 1'b0;
            l2_rdata    <= {`BUS_DATA_WIDTH{1'b0}};
            req_wr_r    <= 1'b0;
            req_addr_r  <= {`ADDR_WIDTH{1'b0}};
            req_wdata_r <= {`BUS_DATA_WIDTH{1'b0}};
        end else begin
            // Defaults
            l2_ack  <= 1'b0;
            mem_req <= 1'b0;

            case (state)
                IDLE: begin
                    if (l2_req) begin
                        // Latch the request
                        req_wr_r    <= l2_wr;
                        req_addr_r  <= l2_addr;
                        req_wdata_r <= l2_wdata;
                    end
                end

                REQ_SENT: begin
                    // Issue request to main memory
                    mem_req   <= 1'b1;
                    mem_wr    <= req_wr_r;
                    mem_addr  <= req_addr_r;
                    mem_wdata <= req_wdata_r;
                end

                WAIT_ACK: begin
                    mem_req <= 1'b1;  // Hold request
                    mem_wr  <= req_wr_r;
                    if (mem_ack) begin
                        mem_req <= 1'b0;
                    end
                end

                RESPOND: begin
                    // Send response back to L2
                    l2_ack   <= 1'b1;
                    l2_rdata <= mem_rdata;
                end

                default: begin
                    mem_req <= 1'b0;
                    l2_ack  <= 1'b0;
                end
            endcase
        end
    end

endmodule

