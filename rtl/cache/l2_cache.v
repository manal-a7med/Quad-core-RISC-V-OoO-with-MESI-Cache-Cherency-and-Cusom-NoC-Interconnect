`timescale 1ns / 1ps
`include "common_defs.vh"
`include "mesi_defines.vh"

module l2_cache (
    input  wire         clk,
    input  wire         rst_n,
    
    // Request side (from snoop controller)
    input  wire         req_valid,
    input  wire [31:0]  req_addr,
    input  wire [255:0] req_wdata,
    input  wire [2:0]   req_cmd,
    output reg          req_ack,
    
    // Response side (to snoop controller)
    output reg  [255:0] resp_data,
    output reg          resp_valid,
    
    // Memory side (to memory controller)
    output reg  [31:0]  mem_addr,
    output reg  [255:0] mem_wdata,
    input  wire [255:0] mem_rdata,
    output reg          mem_req,
    output reg          mem_wr,
    input  wire         mem_ack
);

    // 16KB, 4-way -> 128 sets, 32 bytes/line
    localparam CACHE_SETS = 128;
    localparam WAYS       = 4;
    localparam TAG_BITS   = 20;
    localparam INDEX_BITS = 7;

    reg [255:0]        data_array  [0:WAYS-1][0:CACHE_SETS-1];
    reg [TAG_BITS-1:0] tag_array   [0:WAYS-1][0:CACHE_SETS-1];
    reg                valid_array [0:WAYS-1][0:CACHE_SETS-1];
    reg                dirty_array [0:WAYS-1][0:CACHE_SETS-1];
    reg [1:0]          lru_array   [0:CACHE_SETS-1];

    // FSM States
    localparam L2_IDLE       = 3'd0;
    localparam L2_LOOKUP     = 3'd1;
    localparam L2_WB_WAIT    = 3'd2;
    localparam L2_WB_PAUSE   = 3'd3;
    localparam L2_FETCH_WAIT = 3'd4;
    localparam L2_DONE_WAIT  = 3'd5;

    reg [2:0]   state;
    reg [31:0]  lat_addr;
    reg [255:0] lat_wdata;
    reg [2:0]   lat_cmd;
    reg [1:0]   lat_vic;

    wire [INDEX_BITS-1:0] idx = lat_addr[11:5];
    wire [TAG_BITS-1:0]   tag = lat_addr[31:12];

    // Hit detection across 4 ways
    wire w0_hit = valid_array[0][idx] && (tag_array[0][idx] == tag);
    wire w1_hit = valid_array[1][idx] && (tag_array[1][idx] == tag);
    wire w2_hit = valid_array[2][idx] && (tag_array[2][idx] == tag);
    wire w3_hit = valid_array[3][idx] && (tag_array[3][idx] == tag);
    wire cache_hit = w0_hit || w1_hit || w2_hit || w3_hit;

    wire [1:0] hit_way = w0_hit ? 2'd0 :
                         w1_hit ? 2'd1 :
                         w2_hit ? 2'd2 :
                                  2'd3;

    // Victim way selection: first invalid way, else round-robin LRU
    wire [1:0] vic_way = (!valid_array[0][idx]) ? 2'd0 :
                         (!valid_array[1][idx]) ? 2'd1 :
                         (!valid_array[2][idx]) ? 2'd2 :
                         (!valid_array[3][idx]) ? 2'd3 :
                                                  lru_array[idx];

    integer s, w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= L2_IDLE;
            req_ack    <= 1'b0;
            resp_data  <= 256'd0;
            resp_valid <= 1'b0;
            mem_addr   <= 32'd0;
            mem_wdata  <= 256'd0;
            mem_req    <= 1'b0;
            mem_wr     <= 1'b0;
            lat_addr   <= 32'd0;
            lat_wdata  <= 256'd0;
            lat_cmd    <= 3'd0;
            lat_vic    <= 2'd0;
            for (s = 0; s < CACHE_SETS; s = s + 1) begin
                lru_array[s] <= 2'd0;
                for (w = 0; w < WAYS; w = w + 1) begin
                    valid_array[w][s] <= 1'b0;
                    dirty_array[w][s] <= 1'b0;
                    tag_array[w][s]   <= {TAG_BITS{1'b0}};
                    data_array[w][s]  <= 256'd0;
                end
            end
        end else begin
            req_ack    <= 1'b0;
            resp_valid <= 1'b0;

            case (state)
                L2_IDLE: begin
                    if (req_valid) begin
                        lat_addr  <= {req_addr[31:5], 5'b0};
                        lat_wdata <= req_wdata;
                        lat_cmd   <= req_cmd;
                        state     <= L2_LOOKUP;
                    end
                end

                L2_LOOKUP: begin
                    if (cache_hit) begin
                        req_ack        <= 1'b1;
                        resp_valid     <= 1'b1;
                        lru_array[idx] <= hit_way + 2'd1;
                        if (lat_cmd == `BUS_FLUSH) begin
                            data_array[hit_way][idx]  <= lat_wdata;
                            dirty_array[hit_way][idx] <= 1'b1;
                            resp_data                 <= lat_wdata;
                        end else begin
                            resp_data <= data_array[hit_way][idx];
                        end
                        state <= L2_DONE_WAIT;
                    end else begin
                        lat_vic <= vic_way;
                        if (valid_array[vic_way][idx] && dirty_array[vic_way][idx]) begin
                            // Dirty victim: write back to main memory first
                            mem_req   <= 1'b1;
                            mem_wr    <= 1'b1;
                            mem_addr  <= {tag_array[vic_way][idx], idx, 5'b0};
                            mem_wdata <= data_array[vic_way][idx];
                            state     <= L2_WB_WAIT;
                        end else if (lat_cmd == `BUS_FLUSH) begin
                            // Allocate flushed L1 line directly into clean/invalid L2 way
                            data_array[vic_way][idx]  <= lat_wdata;
                            tag_array[vic_way][idx]   <= tag;
                            valid_array[vic_way][idx] <= 1'b1;
                            dirty_array[vic_way][idx] <= 1'b1;
                            lru_array[idx]            <= vic_way + 2'd1;
                            req_ack                   <= 1'b1;
                            resp_valid                <= 1'b1;
                            resp_data                 <= lat_wdata;
                            state                     <= L2_DONE_WAIT;
                        end else begin
                            // Read/ReadX miss: fetch from main memory
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_addr <= lat_addr;
                            state    <= L2_FETCH_WAIT;
                        end
                    end
                end

                L2_WB_WAIT: begin
                    mem_req <= 1'b1;
                    mem_wr  <= 1'b1;
                    if (mem_ack) begin
                        mem_req                   <= 1'b0;
                        mem_wr                    <= 1'b0;
                        dirty_array[lat_vic][idx] <= 1'b0;
                        if (lat_cmd == `BUS_FLUSH) begin
                            data_array[lat_vic][idx]  <= lat_wdata;
                            tag_array[lat_vic][idx]   <= tag;
                            valid_array[lat_vic][idx] <= 1'b1;
                            dirty_array[lat_vic][idx] <= 1'b1;
                            lru_array[idx]            <= lat_vic + 2'd1;
                            req_ack                   <= 1'b1;
                            resp_valid                <= 1'b1;
                            resp_data                 <= lat_wdata;
                            state                     <= L2_DONE_WAIT;
                        end else begin
                            state <= L2_WB_PAUSE;
                        end
                    end
                end

                L2_WB_PAUSE: begin
                    mem_req  <= 1'b1;
                    mem_wr   <= 1'b0;
                    mem_addr <= lat_addr;
                    state    <= L2_FETCH_WAIT;
                end

                L2_FETCH_WAIT: begin
                    mem_req <= 1'b1;
                    mem_wr  <= 1'b0;
                    if (mem_ack) begin
                        mem_req                   <= 1'b0;
                        data_array[lat_vic][idx]  <= mem_rdata;
                        tag_array[lat_vic][idx]   <= tag;
                        valid_array[lat_vic][idx] <= 1'b1;
                        dirty_array[lat_vic][idx] <= 1'b0;
                        lru_array[idx]            <= lat_vic + 2'd1;
                        req_ack                   <= 1'b1;
                        resp_valid                <= 1'b1;
                        resp_data                 <= mem_rdata;
                        state                     <= L2_DONE_WAIT;
                    end
                end

                L2_DONE_WAIT: begin
                    state <= L2_IDLE;
                end

                default: state <= L2_IDLE;
            endcase
        end
    end

endmodule
