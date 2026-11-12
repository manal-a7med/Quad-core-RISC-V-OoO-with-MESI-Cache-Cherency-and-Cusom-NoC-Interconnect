`timescale 1ns / 1ps
// ============================================================================
// l1_icache.v - L1 Instruction Cache (4KB, direct-mapped, 32-byte lines)
// ============================================================================
// 128 sets x 256-bit lines. The data array is line-wide with a registered
// read and no reset, so it maps to block RAM; tags have no reset (LUT RAM);
// valid bits are a reset flip-flop vector.
//
// Lookup is pipelined, one instruction per cycle on hits. Every cycle the
// cache looks up the address the core will ask for next: cpu_next_addr (the
// core's predicted next PC, which may be a branch target) when it is
// delivering an instruction this cycle, otherwise cpu_addr itself. The
// next cycle it delivers that instruction if the core is indeed asking for
// that address. After a redirect (branch, trap) the address does not match,
// nothing is delivered for one cycle, and the lookup restarts at the new PC.
// An instruction is therefore never delivered for the wrong address (review
// bug 10).
//
// A miss fetches the whole line over the coherence bus (a BusRd that snoops
// all four data caches, see quad_core_top), so the line is the newest copy
// even if a data cache holds it Modified. The line is filled even if the
// core has moved on in the meantime. Later stores to the line do not
// invalidate it here: software runs FENCE.I, which empties this cache.
// ============================================================================

`include "mesi_defines.vh"

module l1_icache (
    input  wire        clk,
    input  wire        rst_n,

    // CPU interface
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_next_addr, // the PC the core moves to if this one is delivered
    output wire [31:0] cpu_rdata,
    input  wire        cpu_req,
    output wire        cpu_ack,

    // Line fetch (bus read)
    output reg  [31:0] mem_addr,
    input  wire [255:0]mem_rdata,     // Full cache line (8 words)
    output reg         mem_req,
    input  wire        mem_ack,

    // FENCE.I: forget every line. A line fill in progress is discarded too
    // (it may have been read before the stores the fence waits for).
    input  wire        flush_all
);

    localparam NUM_SETS  = `L1I_NUM_SETS;      // 128
    localparam TAG_WIDTH = `L1I_TAG_WIDTH;     // 20
    localparam IDX_WIDTH = `L1I_SET_IDX_WIDTH; // 7
    localparam OFF_WIDTH = `L1I_LINE_OFFSET;   // 5

    (* ram_style = "block" *)
    reg [255:0]         data_array [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag_array  [0:NUM_SETS-1];
    reg [NUM_SETS-1:0]  valid;

    localparam RUN = 1'b0, FETCH = 1'b1;
    reg         state;
    reg [31:0]  la_r;        // address looked up last cycle
    reg         hit_r;       // ... and whether it was in the cache
    reg         la_ok;       // la_r/hit_r/rd_line hold a lookup
    reg [255:0] rd_line;     // registered array read
    reg         fill_kill;   // flush_all arrived during this line fill

    wire [IDX_WIDTH-1:0] la_r_index  = la_r[IDX_WIDTH+OFF_WIDTH-1:OFF_WIDTH];
    wire [TAG_WIDTH-1:0] la_r_tag    = la_r[31:IDX_WIDTH+OFF_WIDTH];

    // The core is asking for the address that was looked up
    wire want = (state == RUN) && la_ok && cpu_req && (cpu_addr == la_r);

    assign cpu_ack   = want && hit_r;
    assign cpu_rdata = rd_line[la_r[OFF_WIDTH-1:2]*32 +: 32];

    wire miss    = want && !hit_r;
    wire fill_we = (state == FETCH) && mem_ack;

    // Next lookup address
    wire [31:0]          la       = cpu_ack ? cpu_next_addr : cpu_addr;
    wire [IDX_WIDTH-1:0] la_index = la[IDX_WIDTH+OFF_WIDTH-1:OFF_WIDTH];
    wire [TAG_WIDTH-1:0] la_tag   = la[31:IDX_WIDTH+OFF_WIDTH];
    wire                 la_hit   = valid[la_index] && (tag_array[la_index] == la_tag);

    // Data RAM: one write port (fill), one registered read port
    always @(posedge clk) begin
        if (fill_we) data_array[la_r_index] <= mem_rdata;
        rd_line <= data_array[la_index];
    end

    // Tag RAM (written on fill only)
    always @(posedge clk) begin
        if (fill_we) tag_array[la_r_index] <= la_r_tag;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= RUN;
            la_r     <= 32'd0;
            hit_r    <= 1'b0;
            la_ok    <= 1'b0;
            mem_req  <= 1'b0;
            mem_addr <= 32'd0;
            valid    <= {NUM_SETS{1'b0}};
            fill_kill <= 1'b0;
        end else begin
            case (state)
                RUN: begin
                    if (miss) begin
                        mem_req  <= 1'b1;
                        mem_addr <= {la_r[31:OFF_WIDTH], {OFF_WIDTH{1'b0}}};
                        state    <= FETCH;          // la_r is kept for the fill
                    end else begin
                        la_r  <= la;
                        hit_r <= la_hit;
                        la_ok <= !flush_all;
                    end
                end

                FETCH: begin
                    if (flush_all) fill_kill <= 1'b1;
                    if (mem_ack) begin
                        mem_req           <= 1'b0;
                        valid[la_r_index] <= !fill_kill;
                        fill_kill         <= 1'b0;
                        la_ok             <= 1'b0;  // look up again from the array
                        state             <= RUN;
                    end
                end
            endcase

            if (flush_all) valid <= {NUM_SETS{1'b0}};
        end
    end

endmodule
