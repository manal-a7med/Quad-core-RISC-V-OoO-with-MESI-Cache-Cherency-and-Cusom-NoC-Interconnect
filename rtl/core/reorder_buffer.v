`timescale 1ns / 1ps
// ============================================================================
// reorder_buffer.v — 16-Entry Circular Reorder Buffer (ROB)
// ============================================================================
// Tracks all in-flight instructions for in-order commit.
// Supports allocation, completion marking, in-order retirement,
// and pipeline flush on branch misprediction.
// ============================================================================

`include "common_defs.vh"

module reorder_buffer (
    input  wire        clk,
    input  wire        rst_n,

    // Allocate interface (from rename stage)
    input  wire        alloc_en,
    input  wire [31:0] alloc_pc,
    input  wire [5:0]  alloc_phys_rd,
    input  wire [4:0]  alloc_arch_rd,
    input  wire [5:0]  alloc_phys_rd_old,
    input  wire        alloc_writes_rd,
    input  wire        alloc_is_branch,
    input  wire        alloc_is_store,
    input  wire        alloc_is_load,
    output wire [3:0]  alloc_idx,      // ROB index assigned
    output wire        rob_full,

    // Complete interface (from execute stage)
    input  wire        complete_en,
    input  wire [3:0]  complete_idx,
    input  wire [31:0] complete_result,
    input  wire        complete_mispredicted,
    input  wire [31:0] complete_branch_target,
    input  wire        complete_exception,

    // Commit interface (to arch state update)
    output reg         commit_valid,
    output reg  [4:0]  commit_arch_rd,
    output reg  [5:0]  commit_phys_rd,
    output reg  [5:0]  commit_phys_rd_old,
    output reg         commit_writes_rd,
    output reg         commit_is_store,
    output reg  [31:0] commit_result,
    output reg  [3:0]  commit_rob_idx,

    // Flush interface
    output reg         flush_out,
    output reg  [31:0] flush_redirect_pc,
    input  wire        flush_in        // External flush signal
);

    // ========================================================================
    // ROB Entry Fields
    // ========================================================================
    reg        rob_valid       [0:`ROB_DEPTH-1];
    reg        rob_done        [0:`ROB_DEPTH-1];
    reg [31:0] rob_pc          [0:`ROB_DEPTH-1];
    reg [5:0]  rob_phys_rd     [0:`ROB_DEPTH-1];
    reg [4:0]  rob_arch_rd     [0:`ROB_DEPTH-1];
    reg [5:0]  rob_phys_rd_old [0:`ROB_DEPTH-1];
    reg        rob_writes_rd   [0:`ROB_DEPTH-1];
    reg        rob_is_branch   [0:`ROB_DEPTH-1];
    reg        rob_is_store    [0:`ROB_DEPTH-1];
    reg        rob_is_load     [0:`ROB_DEPTH-1];
    reg        rob_mispredicted[0:`ROB_DEPTH-1];
    reg [31:0] rob_branch_tgt  [0:`ROB_DEPTH-1];
    reg        rob_exception   [0:`ROB_DEPTH-1];
    reg [31:0] rob_result      [0:`ROB_DEPTH-1];

    // ========================================================================
    // Head and Tail Pointers (circular queue)
    // ========================================================================
    reg [3:0] head, tail;
    reg [4:0] count; // Extra bit to distinguish full/empty

    assign rob_full  = (count >= `ROB_DEPTH);
    assign alloc_idx = tail;

    wire rob_empty = (count == 0);

    // ========================================================================
    // Main Logic
    // ========================================================================
    integer k;
    wire do_alloc  = alloc_en && !rob_full;
    wire do_commit = !rob_empty && rob_valid[head] && rob_done[head];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_in) begin
            head  <= 4'd0;
            tail  <= 4'd0;
            count <= 5'd0;
            commit_valid    <= 1'b0;
            flush_out       <= 1'b0;
            flush_redirect_pc <= 32'd0;
            for (k = 0; k < `ROB_DEPTH; k = k + 1) begin
                rob_valid[k]        <= 1'b0;
                rob_done[k]         <= 1'b0;
                rob_mispredicted[k] <= 1'b0;
                rob_exception[k]    <= 1'b0;
            end
        end else begin
            commit_valid <= 1'b0;
            flush_out    <= 1'b0;

            // -----------------------------------------------------------------
            // Allocate: add new entry at tail
            // -----------------------------------------------------------------
            if (do_alloc) begin
                rob_valid[tail]       <= 1'b1;
                rob_done[tail]        <= 1'b0;
                rob_pc[tail]          <= alloc_pc;
                rob_phys_rd[tail]     <= alloc_phys_rd;
                rob_arch_rd[tail]     <= alloc_arch_rd;
                rob_phys_rd_old[tail] <= alloc_phys_rd_old;
                rob_writes_rd[tail]   <= alloc_writes_rd;
                rob_is_branch[tail]   <= alloc_is_branch;
                rob_is_store[tail]    <= alloc_is_store;
                rob_is_load[tail]     <= alloc_is_load;
                rob_mispredicted[tail]<= 1'b0;
                rob_exception[tail]   <= 1'b0;
                rob_result[tail]      <= 32'd0;
                tail  <= (tail + 1) & (`ROB_DEPTH - 1);
            end

            // -----------------------------------------------------------------
            // Complete: mark entry as done
            // -----------------------------------------------------------------
            if (complete_en && rob_valid[complete_idx]) begin
                rob_done[complete_idx]         <= 1'b1;
                rob_result[complete_idx]       <= complete_result;
                rob_mispredicted[complete_idx] <= complete_mispredicted;
                rob_branch_tgt[complete_idx]   <= complete_branch_target;
                rob_exception[complete_idx]    <= complete_exception;
            end

            // -----------------------------------------------------------------
            // Commit: retire from head when done (in-order)
            // -----------------------------------------------------------------
            if (do_commit && (rob_is_branch[head] && rob_mispredicted[head])) begin
                // Trigger pipeline flush
                flush_out         <= 1'b1;
                flush_redirect_pc <= rob_branch_tgt[head];

                // Commit the branch/jump itself
                commit_valid      <= 1'b1;
                commit_arch_rd    <= rob_arch_rd[head];
                commit_phys_rd    <= rob_phys_rd[head];
                commit_phys_rd_old<= rob_phys_rd_old[head];
                commit_writes_rd  <= rob_writes_rd[head];
                commit_is_store   <= rob_is_store[head];
                commit_result     <= rob_result[head];
                commit_rob_idx    <= head;

                // Invalidate all entries (flush younger speculative instructions)
                for (k = 0; k < `ROB_DEPTH; k = k + 1) begin
                    rob_valid[k]        <= 1'b0;
                    rob_done[k]         <= 1'b0;
                    rob_mispredicted[k] <= 1'b0;
                    rob_exception[k]    <= 1'b0;
                end
                head  <= 4'd0;
                tail  <= 4'd0;
                count <= 5'd0;
            end else if (do_commit && rob_exception[head]) begin
                // Exception: flush pipeline
                flush_out         <= 1'b1;
                flush_redirect_pc <= rob_pc[head];
                for (k = 0; k < `ROB_DEPTH; k = k + 1) begin
                    rob_valid[k]        <= 1'b0;
                    rob_done[k]         <= 1'b0;
                    rob_mispredicted[k] <= 1'b0;
                    rob_exception[k]    <= 1'b0;
                end
                head  <= 4'd0;
                tail  <= 4'd0;
                count <= 5'd0;
            end else begin
                if (do_commit) begin
                    // Normal commit
                    commit_valid      <= 1'b1;
                    commit_arch_rd    <= rob_arch_rd[head];
                    commit_phys_rd    <= rob_phys_rd[head];
                    commit_phys_rd_old<= rob_phys_rd_old[head];
                    commit_writes_rd  <= rob_writes_rd[head];
                    commit_is_store   <= rob_is_store[head];
                    commit_result     <= rob_result[head];
                    commit_rob_idx    <= head;
                    rob_valid[head]   <= 1'b0;
                    head  <= (head + 1) & (`ROB_DEPTH - 1);
                end

                case ({do_alloc, do_commit})
                    2'b10: count <= count + 5'd1;
                    2'b01: count <= count - 5'd1;
                    default: count <= count;
                endcase
            end
        end
    end

endmodule
