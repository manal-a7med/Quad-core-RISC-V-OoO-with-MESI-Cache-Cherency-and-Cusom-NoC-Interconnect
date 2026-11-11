`timescale 1ns / 1ps
// ============================================================================
// main_memory.v — BRAM-Based Main Memory (64KB)
// ============================================================================
// Simulated main memory using block RAM for FPGA deployment.
// Supports full cache-line reads and writes (256 bits = 32 bytes).
// Configurable access latency to model realistic memory behavior.
// ============================================================================

`include "common_defs.vh"
`include "mesi_defines.vh"

module main_memory (
    input  wire                        clk,
    input  wire                        rst_n,

    // Memory interface
    input  wire [`ADDR_WIDTH-1:0]      addr,
    input  wire [`BUS_DATA_WIDTH-1:0]  wdata,
    output reg  [`BUS_DATA_WIDTH-1:0]  rdata,
    input  wire                        req,
    input  wire                        wr,
    output reg                         ack
);

    // ========================================================================
    // Memory Array — 64KB organized as 32-bit words (16384 words)
    // For FPGA: this infers Block RAM
    // ========================================================================
    localparam MEM_DEPTH = `MEM_SIZE_BYTES / 4;  // 16384 words
    localparam MEM_ADDR_W = 14;                   // log2(16384)

    reg [31:0] mem [0:MEM_DEPTH-1];

    // ========================================================================
    // Latency Counter — Models realistic memory latency
    // ========================================================================
    localparam LATENCY = `MEM_LATENCY;

    reg [3:0] latency_cnt;
    reg       req_pending;
    reg       req_wr_r;
    reg [MEM_ADDR_W-1:0] req_addr_r;
    reg [`BUS_DATA_WIDTH-1:0] req_wdata_r;

    // Word address (strip byte offset, use word-aligned)
    wire [MEM_ADDR_W-1:0] word_addr = addr[MEM_ADDR_W+1:2];

    // ========================================================================
    // Memory Access FSM
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latency_cnt  <= 4'd0;
            req_pending  <= 1'b0;
            req_wr_r     <= 1'b0;
            req_addr_r   <= {MEM_ADDR_W{1'b0}};
            req_wdata_r  <= {`BUS_DATA_WIDTH{1'b0}};
            rdata        <= {`BUS_DATA_WIDTH{1'b0}};
            ack          <= 1'b0;
        end else begin
            ack <= 1'b0;  // Default: deassert ack

            if (!req_pending && !ack && req) begin
                // Latch new request
                req_pending  <= 1'b1;
                req_wr_r     <= wr;
                req_addr_r   <= word_addr;
                req_wdata_r  <= wdata;
                latency_cnt  <= LATENCY - 1;
            end else if (req_pending) begin
                if (latency_cnt > 0) begin
                    latency_cnt <= latency_cnt - 1;
                end else begin
                    // Latency elapsed — perform the actual access
                    req_pending <= 1'b0;
                    ack <= 1'b1;

                    if (req_wr_r) begin
                        // Write: store full cache line (8 words)
                        mem[req_addr_r]     <= req_wdata_r[31:0];
                        mem[req_addr_r + 1] <= req_wdata_r[63:32];
                        mem[req_addr_r + 2] <= req_wdata_r[95:64];
                        mem[req_addr_r + 3] <= req_wdata_r[127:96];
                        mem[req_addr_r + 4] <= req_wdata_r[159:128];
                        mem[req_addr_r + 5] <= req_wdata_r[191:160];
                        mem[req_addr_r + 6] <= req_wdata_r[223:192];
                        mem[req_addr_r + 7] <= req_wdata_r[255:224];
                    end else begin
                        // Read: return full cache line (8 words)
                        rdata[31:0]    <= mem[req_addr_r];
                        rdata[63:32]   <= mem[req_addr_r + 1];
                        rdata[95:64]   <= mem[req_addr_r + 2];
                        rdata[127:96]  <= mem[req_addr_r + 3];
                        rdata[159:128] <= mem[req_addr_r + 4];
                        rdata[191:160] <= mem[req_addr_r + 5];
                        rdata[223:192] <= mem[req_addr_r + 6];
                        rdata[255:224] <= mem[req_addr_r + 7];
                    end
                end
            end
        end
    end

    // ========================================================================
    // Memory Initialization — Load test program if available
    // ========================================================================
    integer i;
    initial begin
        for (i = 0; i < MEM_DEPTH; i = i + 1) begin
            mem[i] = 32'h00000013;  // NOP (addi x0, x0, 0)
        end
        // Attempt to load hex file for simulation
        `ifdef SIM
            `ifdef MEM_INIT_FILE
                $readmemh(`MEM_INIT_FILE, mem);
            `endif
        `endif
    end

endmodule

