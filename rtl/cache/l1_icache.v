`timescale 1ns / 1ps
// ============================================================================
// l1_icache.v — L1 Instruction Cache (4KB, Direct-Mapped)
// ============================================================================
// 128 sets, 32-byte lines (8 words), 20-bit tags.
// Read-only from processor side. On miss, fetches full cache line from
// L2/memory. Supports external invalidation for coherence.
// ============================================================================

`include "mesi_defines.vh"

module l1_icache (
    input  wire        clk,
    input  wire        rst_n,

    // CPU interface
    input  wire [31:0] cpu_addr,
    output reg  [31:0] cpu_rdata,
    input  wire        cpu_req,
    output reg         cpu_ack,

    // Memory/L2 interface (for miss handling)
    output reg  [31:0] mem_addr,
    input  wire [255:0]mem_rdata,     // Full cache line (8 words)
    output reg         mem_req,
    input  wire        mem_ack,

    // Invalidation interface (from coherence)
    input  wire        invalidate,
    input  wire [31:0] inval_addr
);

    // ========================================================================
    // Cache Storage
    // ========================================================================
    localparam NUM_SETS   = `L1I_NUM_SETS;   // 128
    localparam TAG_WIDTH  = `L1I_TAG_WIDTH;  // 20
    localparam IDX_WIDTH  = `L1I_SET_IDX_WIDTH; // 7
    localparam OFF_WIDTH  = `L1I_LINE_OFFSET;   // 5

    // Tag array + valid bits
    reg [TAG_WIDTH-1:0] tag_array  [0:NUM_SETS-1];
    reg                 valid_array[0:NUM_SETS-1];

    // Data array: 128 sets x 8 words = 1024 words
    reg [31:0]          data_array [0:NUM_SETS*8-1];

    // ========================================================================
    // Address Decomposition
    // ========================================================================
    wire [TAG_WIDTH-1:0] addr_tag    = cpu_addr[31:IDX_WIDTH+OFF_WIDTH];
    wire [IDX_WIDTH-1:0] addr_index  = cpu_addr[IDX_WIDTH+OFF_WIDTH-1:OFF_WIDTH];
    wire [2:0]           addr_word   = cpu_addr[OFF_WIDTH-1:2]; // Word select within line

    // Invalidation address decomposition
    wire [TAG_WIDTH-1:0] inval_tag   = inval_addr[31:IDX_WIDTH+OFF_WIDTH];
    wire [IDX_WIDTH-1:0] inval_index = inval_addr[IDX_WIDTH+OFF_WIDTH-1:OFF_WIDTH];

    // ========================================================================
    // Hit Detection
    // ========================================================================
    wire cache_hit = valid_array[addr_index] &&
                     (tag_array[addr_index] == addr_tag);

    // ========================================================================
    // FSM States
    // ========================================================================
    localparam [1:0]
        IDLE        = 2'b00,
        COMPARE_TAG = 2'b01,
        FETCH       = 2'b10,
        FILL        = 2'b11;

    reg [1:0] state;
    reg [IDX_WIDTH-1:0] fill_index;
    reg [TAG_WIDTH-1:0] fill_tag;
    reg [2:0]           fill_word_sel;

    // ========================================================================
    // Main FSM
    // ========================================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            cpu_ack  <= 1'b0;
            cpu_rdata<= 32'd0;
            mem_req  <= 1'b0;
            mem_addr <= 32'd0;
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                valid_array[i] <= 1'b0;
            end
        end else begin
            cpu_ack <= 1'b0;

            // Handle external invalidation (highest priority)
            if (invalidate) begin
                if (valid_array[inval_index] && tag_array[inval_index] == inval_tag) begin
                    valid_array[inval_index] <= 1'b0;
                end
            end

            case (state)
                IDLE: begin
                    if (cpu_req) begin
                        state <= COMPARE_TAG;
                    end
                end

                COMPARE_TAG: begin
                    if (cache_hit) begin
                        // Hit: return requested word
                        cpu_rdata <= data_array[{addr_index, addr_word}];
                        cpu_ack   <= 1'b1;
                        state     <= IDLE;
                    end else begin
                        // Miss: fetch from memory
                        mem_req       <= 1'b1;
                        mem_addr      <= {cpu_addr[31:OFF_WIDTH], {OFF_WIDTH{1'b0}}}; // Line-aligned
                        fill_index    <= addr_index;
                        fill_tag      <= addr_tag;
                        fill_word_sel <= addr_word;
                        state         <= FETCH;
                    end
                end

                FETCH: begin
                    if (mem_ack) begin
                        mem_req <= 1'b0;
                        // Fill the cache line (8 words from 256-bit line)
                        data_array[{fill_index, 3'd0}] <= mem_rdata[31:0];
                        data_array[{fill_index, 3'd1}] <= mem_rdata[63:32];
                        data_array[{fill_index, 3'd2}] <= mem_rdata[95:64];
                        data_array[{fill_index, 3'd3}] <= mem_rdata[127:96];
                        data_array[{fill_index, 3'd4}] <= mem_rdata[159:128];
                        data_array[{fill_index, 3'd5}] <= mem_rdata[191:160];
                        data_array[{fill_index, 3'd6}] <= mem_rdata[223:192];
                        data_array[{fill_index, 3'd7}] <= mem_rdata[255:224];
                        tag_array[fill_index]   <= fill_tag;
                        valid_array[fill_index] <= 1'b1;
                        state <= FILL;
                    end
                end

                FILL: begin
                    // Return the requested word from the newly filled line
                    cpu_rdata <= data_array[{fill_index, fill_word_sel}];
                    cpu_ack   <= 1'b1;
                    state     <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
