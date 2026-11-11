`timescale 1ns / 1ps
// ============================================================================
// l1_icache.v - L1 Instruction Cache (4KB, direct-mapped, 32-byte lines)
// ============================================================================
// 128 sets x 256-bit lines. The data array is line-wide with a registered
// read and no reset, so it maps to block RAM; tags have no reset (LUT RAM);
// valid bits are a reset flip-flop vector.
//
// A request is identified by its address. If the core moves to another PC
// while a lookup or miss is in flight (a branch redirect), the response for
// the old address is dropped instead of being delivered as the instruction
// at the new PC (review bug 10).
// ============================================================================

`include "mesi_defines.vh"

module l1_icache (
    input  wire        clk,
    input  wire        rst_n,

    // CPU interface
    input  wire [31:0] cpu_addr,
    output reg  [31:0] cpu_rdata,
    input  wire        cpu_req,
    output wire        cpu_ack,

    // Memory/L2 interface (for miss handling)
    output reg  [31:0] mem_addr,
    input  wire [255:0]mem_rdata,     // Full cache line (8 words)
    output reg         mem_req,
    input  wire        mem_ack,

    // Invalidation interface (from coherence)
    input  wire        invalidate,
    input  wire [31:0] inval_addr
);

    localparam NUM_SETS  = `L1I_NUM_SETS;      // 128
    localparam TAG_WIDTH = `L1I_TAG_WIDTH;     // 20
    localparam IDX_WIDTH = `L1I_SET_IDX_WIDTH; // 7
    localparam OFF_WIDTH = `L1I_LINE_OFFSET;   // 5

    reg [255:0]         data_array [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag_array  [0:NUM_SETS-1];
    reg [NUM_SETS-1:0]  valid;

    localparam [1:0] IDLE = 2'b00, COMPARE_TAG = 2'b01, FETCH = 2'b10, FILL = 2'b11;
    reg [1:0]  state;
    reg [31:0] req_addr_r;
    reg [255:0] rd_line;     // registered array read
    reg [255:0] fill_line;
    reg        ack_r;

    wire [IDX_WIDTH-1:0] cpu_index = cpu_addr[IDX_WIDTH+OFF_WIDTH-1:OFF_WIDTH];
    wire [IDX_WIDTH-1:0] req_index = req_addr_r[IDX_WIDTH+OFF_WIDTH-1:OFF_WIDTH];
    wire [TAG_WIDTH-1:0] req_tag   = req_addr_r[31:IDX_WIDTH+OFF_WIDTH];
    wire [2:0]           req_word  = req_addr_r[OFF_WIDTH-1:2];
    wire [TAG_WIDTH-1:0] inval_tag   = inval_addr[31:IDX_WIDTH+OFF_WIDTH];
    wire [IDX_WIDTH-1:0] inval_index = inval_addr[IDX_WIDTH+OFF_WIDTH-1:OFF_WIDTH];

    wire same_req  = cpu_req && (cpu_addr == req_addr_r);
    wire cache_hit = valid[req_index] && (tag_array[req_index] == req_tag);
    wire fill_we   = (state == FETCH) && mem_ack;

    // Deliver only while the core still wants this address
    assign cpu_ack = ack_r && same_req;

    // Data RAM: one write port (fill), one registered read port
    always @(posedge clk) begin
        if (fill_we) data_array[req_index] <= mem_rdata;
        rd_line <= data_array[cpu_index];
    end

    // Tag RAM (written on fill only)
    always @(posedge clk) begin
        if (fill_we) tag_array[req_index] <= req_tag;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            ack_r      <= 1'b0;
            cpu_rdata  <= 32'd0;
            mem_req    <= 1'b0;
            mem_addr   <= 32'd0;
            req_addr_r <= 32'd0;
            fill_line  <= 256'd0;
            valid      <= {NUM_SETS{1'b0}};
        end else begin
            ack_r <= 1'b0;

            if (invalidate && valid[inval_index] && tag_array[inval_index] == inval_tag)
                valid[inval_index] <= 1'b0;

            case (state)
                IDLE: begin
                    if (cpu_req && !cpu_ack) begin   // (not while delivering)
                        req_addr_r <= cpu_addr;      // rd_line is read this cycle
                        state      <= COMPARE_TAG;
                    end
                end

                COMPARE_TAG: begin
                    if (!same_req) begin
                        state <= IDLE;                // core moved on: drop
                    end else if (cache_hit) begin
                        cpu_rdata <= rd_line[req_word*32 +: 32];
                        ack_r     <= 1'b1;
                        state     <= IDLE;
                    end else begin
                        mem_req  <= 1'b1;
                        mem_addr <= {req_addr_r[31:OFF_WIDTH], {OFF_WIDTH{1'b0}}};
                        state    <= FETCH;
                    end
                end

                FETCH: begin
                    // The line is filled even if the core has moved on.
                    if (mem_ack) begin
                        mem_req          <= 1'b0;
                        fill_line        <= mem_rdata;
                        valid[req_index] <= 1'b1;
                        state            <= FILL;
                    end
                end

                FILL: begin
                    if (same_req) begin
                        cpu_rdata <= fill_line[req_word*32 +: 32];
                        ack_r     <= 1'b1;
                    end
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
