`timescale 1ns / 1ps
// ============================================================================
// main_memory.v - Line-wide block-RAM main memory
// ============================================================================
// One 256-bit cache line per entry (64 KB = 2048 lines by default), so every
// access is a single read or a single write: this maps onto FPGA block RAM.
// A configurable latency models a slower memory.
//
// Initial contents come from `MEM_INIT_FILE (line format: one 256-bit line
// per row, word 0 in the low bits). scripts/hex2line.py converts the usual
// one-word-per-line hex. This works in simulation and in synthesis, so the
// FPGA bitstream carries the program.
// ============================================================================

`include "common_defs.vh"
`include "mesi_defines.vh"

module main_memory (
    input  wire                        clk,
    input  wire                        rst_n,

    input  wire [`ADDR_WIDTH-1:0]      addr,
    input  wire [`BUS_DATA_WIDTH-1:0]  wdata,
    output wire [`BUS_DATA_WIDTH-1:0]  rdata,
    input  wire                        req,
    input  wire                        wr,
    output reg                         ack
);

    localparam LINES   = `MEM_SIZE_BYTES / 32;
    localparam LINE_W  = $clog2(LINES);
    localparam LATENCY = `MEM_LATENCY;

    reg [255:0] mem [0:LINES-1];
    reg [255:0] ram_q;
    assign rdata = ram_q;

    reg [3:0]        latency_cnt;
    reg              req_pending;
    reg              req_wr_r;
    reg [LINE_W-1:0] req_line_r;
    reg [255:0]      req_wdata_r;

    wire do_access = req_pending && (latency_cnt == 4'd0);

    // Control (with reset)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latency_cnt <= 4'd0;
            req_pending <= 1'b0;
            req_wr_r    <= 1'b0;
            req_line_r  <= {LINE_W{1'b0}};
            req_wdata_r <= 256'd0;
            ack         <= 1'b0;
        end else begin
            ack <= 1'b0;
            if (!req_pending && !ack && req) begin
                req_pending <= 1'b1;
                req_wr_r    <= wr;
                req_line_r  <= addr[LINE_W+4:5];
                req_wdata_r <= wdata;
                latency_cnt <= LATENCY - 1;
            end else if (req_pending) begin
                if (latency_cnt != 4'd0)
                    latency_cnt <= latency_cnt - 4'd1;
                else begin
                    req_pending <= 1'b0;
                    ack         <= 1'b1;
                end
            end
        end
    end

    // RAM (no reset, one port, registered read): infers block RAM
    always @(posedge clk) begin
        if (do_access) begin
            if (req_wr_r) mem[req_line_r] <= req_wdata_r;
            else          ram_q           <= mem[req_line_r];
        end
    end

    integer i;
    initial begin
        for (i = 0; i < LINES; i = i + 1) mem[i] = 256'd0;
        `ifdef MEM_INIT_FILE
            $readmemh(`MEM_INIT_FILE, mem);
        `endif
    end

endmodule
