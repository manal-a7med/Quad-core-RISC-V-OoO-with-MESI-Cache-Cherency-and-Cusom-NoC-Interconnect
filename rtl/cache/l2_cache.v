`timescale 1ns / 1ps
// ============================================================================
// l2_cache.v - Shared L2 (16KB, 4-way, 128 sets, 32-byte lines, write-back)
// ============================================================================
// Storage is FPGA-friendly:
//   * data: one 128 x 256-bit RAM per way, registered read, no reset -> BRAM
//   * tags: 128 x 20-bit per way, no reset -> LUT RAM
//   * valid/dirty/LRU: reset flip-flop vectors
// The data RAMs are read in IDLE (at the incoming request's set), so the
// lines are ready in LOOKUP: the FSM and its latency are unchanged.
// ============================================================================

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

    localparam CACHE_SETS = 128;
    localparam WAYS       = 4;
    localparam TAG_BITS   = 20;
    localparam INDEX_BITS = 7;

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

    // ------------------------------------------------------------------
    // State vectors (bit {way, set})
    // ------------------------------------------------------------------
    reg [WAYS*CACHE_SETS-1:0] valid_bits, dirty_bits;
    reg [2*CACHE_SETS-1:0]    lru_bits;
    wire [1:0] lru = lru_bits[idx*2 +: 2];
    // (Plain indexing, not functions: a continuous assignment that calls a
    // function is only re-evaluated when the function's arguments change.)

    // ------------------------------------------------------------------
    // Write port shared by data and tag RAMs (one way, one set per cycle)
    // ------------------------------------------------------------------
    reg         wr_en, wr_tag;
    reg [1:0]   wr_way;
    reg [255:0] wr_data;

    // Data RAM read address: the incoming request's set in IDLE, else ours
    wire [INDEX_BITS-1:0] rd_idx = (state == L2_IDLE) ? req_addr[11:5] : idx;

    wire [255:0]        rd_line [0:WAYS-1];
    wire [TAG_BITS-1:0] tag_q   [0:WAYS-1];

    genvar g;
    generate for (g = 0; g < WAYS; g = g + 1) begin : way
        reg [255:0]        data_ram [0:CACHE_SETS-1];
        reg [TAG_BITS-1:0] tag_ram  [0:CACHE_SETS-1];
        reg [255:0]        q;
        always @(posedge clk) begin
            if (wr_en && wr_way == g) data_ram[idx] <= wr_data;
            q <= data_ram[rd_idx];
        end
        always @(posedge clk) begin
            if (wr_tag && wr_way == g) tag_ram[idx] <= tag;
        end
        assign rd_line[g] = q;
        assign tag_q[g]   = tag_ram[idx];
    end endgenerate

    wire w0_hit = valid_bits[{2'd0, idx}] && (tag_q[0] == tag);
    wire w1_hit = valid_bits[{2'd1, idx}] && (tag_q[1] == tag);
    wire w2_hit = valid_bits[{2'd2, idx}] && (tag_q[2] == tag);
    wire w3_hit = valid_bits[{2'd3, idx}] && (tag_q[3] == tag);
    wire cache_hit = w0_hit || w1_hit || w2_hit || w3_hit;
    wire [1:0] hit_way = w0_hit ? 2'd0 : w1_hit ? 2'd1 : w2_hit ? 2'd2 : 2'd3;

    wire [1:0] vic_way = !valid_bits[{2'd0, idx}] ? 2'd0 : !valid_bits[{2'd1, idx}] ? 2'd1 :
                         !valid_bits[{2'd2, idx}] ? 2'd2 : !valid_bits[{2'd3, idx}] ? 2'd3 : lru;

    // RAM write decisions (mirror the FSM below)
    always @(*) begin
        wr_en = 1'b0; wr_tag = 1'b0; wr_way = lat_vic; wr_data = mem_rdata;
        case (state)
            L2_LOOKUP:
                if (cache_hit) begin
                    if (lat_cmd == `BUS_FLUSH) begin
                        wr_en = 1'b1; wr_way = hit_way; wr_data = lat_wdata;
                    end
                end else if (!(valid_bits[{vic_way, idx}] && dirty_bits[{vic_way, idx}]) && lat_cmd == `BUS_FLUSH) begin
                    wr_en = 1'b1; wr_tag = 1'b1; wr_way = vic_way; wr_data = lat_wdata;
                end
            L2_WB_WAIT:
                if (mem_ack && lat_cmd == `BUS_FLUSH) begin
                    wr_en = 1'b1; wr_tag = 1'b1; wr_data = lat_wdata;
                end
            L2_FETCH_WAIT:
                if (mem_ack) begin
                    wr_en = 1'b1; wr_tag = 1'b1; wr_data = mem_rdata;
                end
            default: ;
        endcase
    end

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
            valid_bits <= {WAYS*CACHE_SETS{1'b0}};
            dirty_bits <= {WAYS*CACHE_SETS{1'b0}};
            lru_bits   <= {2*CACHE_SETS{1'b0}};
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
                        req_ack    <= 1'b1;
                        resp_valid <= 1'b1;
                        lru_bits[idx*2 +: 2] <= hit_way + 2'd1;
                        if (lat_cmd == `BUS_FLUSH) begin
                            dirty_bits[{hit_way, idx}] <= 1'b1;
                            resp_data <= lat_wdata;
                        end else begin
                            resp_data <= rd_line[hit_way];
                        end
                        state <= L2_DONE_WAIT;
                    end else begin
                        lat_vic <= vic_way;
                        if (valid_bits[{vic_way, idx}] && dirty_bits[{vic_way, idx}]) begin
                            // Dirty victim: write back to main memory first
                            mem_req   <= 1'b1;
                            mem_wr    <= 1'b1;
                            mem_addr  <= {tag_q[vic_way], idx, 5'b0};
                            mem_wdata <= rd_line[vic_way];
                            state     <= L2_WB_WAIT;
                        end else if (lat_cmd == `BUS_FLUSH) begin
                            // Allocate the flushed L1 line directly
                            valid_bits[{vic_way, idx}] <= 1'b1;
                            dirty_bits[{vic_way, idx}] <= 1'b1;
                            lru_bits[idx*2 +: 2]       <= vic_way + 2'd1;
                            req_ack    <= 1'b1;
                            resp_valid <= 1'b1;
                            resp_data  <= lat_wdata;
                            state      <= L2_DONE_WAIT;
                        end else begin
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
                        mem_req <= 1'b0;
                        mem_wr  <= 1'b0;
                        dirty_bits[{lat_vic, idx}] <= 1'b0;
                        if (lat_cmd == `BUS_FLUSH) begin
                            valid_bits[{lat_vic, idx}] <= 1'b1;
                            dirty_bits[{lat_vic, idx}] <= 1'b1;
                            lru_bits[idx*2 +: 2]       <= lat_vic + 2'd1;
                            req_ack    <= 1'b1;
                            resp_valid <= 1'b1;
                            resp_data  <= lat_wdata;
                            state      <= L2_DONE_WAIT;
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
                        mem_req <= 1'b0;
                        valid_bits[{lat_vic, idx}] <= 1'b1;
                        dirty_bits[{lat_vic, idx}] <= 1'b0;
                        lru_bits[idx*2 +: 2]       <= lat_vic + 2'd1;
                        req_ack    <= 1'b1;
                        resp_valid <= 1'b1;
                        resp_data  <= mem_rdata;
                        state      <= L2_DONE_WAIT;
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
