`timescale 1ns / 1ps
// ============================================================================
// issue_queue.v — 8-Entry Reservation Station (Issue Queue)
// ============================================================================
// Holds decoded, renamed instructions waiting for operands.
// When both operands are ready, the instruction is issued to execution.
// Supports wakeup via Common Data Bus (CDB) broadcast.
// ============================================================================

`include "common_defs.vh"

module issue_queue (
    input  wire        clk,
    input  wire        rst_n,

    // Dispatch interface (from rename stage)
    input  wire        dispatch_en,
    input  wire [1:0]  dispatch_fu_type,
    input  wire [3:0]  dispatch_alu_op,
    input  wire [5:0]  dispatch_phys_rd,
    input  wire [5:0]  dispatch_phys_rs1,
    input  wire [5:0]  dispatch_phys_rs2,
    input  wire        dispatch_rs1_ready,
    input  wire        dispatch_rs2_ready,
    input  wire [31:0] dispatch_rs1_data,
    input  wire [31:0] dispatch_rs2_data,
    input  wire [31:0] dispatch_imm,
    input  wire [31:0] dispatch_pc,
    input  wire [3:0]  dispatch_rob_idx,
    input  wire        dispatch_is_branch,
    input  wire        dispatch_is_load,
    input  wire        dispatch_is_store,
    input  wire        dispatch_uses_rs1,
    input  wire        dispatch_uses_rs2,
    input  wire        dispatch_predicted_taken,
    input  wire [31:0] dispatch_predicted_target,
    input  wire [2:0]  dispatch_mem_type,
    input  wire        dispatch_is_jump,
    input  wire        dispatch_writes_rd,

    // CDB wakeup interface (broadcast from execute)
    input  wire        cdb_valid,
    input  wire [5:0]  cdb_phys_rd,
    input  wire [31:0] cdb_data,

    // Issue interface (to execute stage)
    output reg         issue_valid,
    output reg  [1:0]  issue_fu_type,
    output reg  [3:0]  issue_alu_op,
    output reg  [5:0]  issue_phys_rd,
    output reg  [31:0] issue_rs1_data,
    output reg  [31:0] issue_rs2_data,
    output reg  [31:0] issue_imm,
    output reg  [31:0] issue_pc,
    output reg  [3:0]  issue_rob_idx,
    output reg         issue_is_branch,
    output reg         issue_is_load,
    output reg         issue_is_store,
    output reg         issue_is_jump,
    output reg         issue_writes_rd,
    output reg         issue_uses_rs2,
    output reg         issue_predicted_taken,
    output reg  [31:0] issue_predicted_target,
    output reg  [2:0]  issue_mem_type,

    // Status
    output wire        iq_full,
    input  wire        issue_stall,
    input  wire        flush
);

    // ========================================================================
    // Issue Queue Entry Storage
    // ========================================================================
    reg        iq_valid     [0:`IQ_DEPTH-1];
    reg [1:0]  iq_fu_type   [0:`IQ_DEPTH-1];
    reg [3:0]  iq_alu_op    [0:`IQ_DEPTH-1];
    reg [5:0]  iq_phys_rd   [0:`IQ_DEPTH-1];
    reg [5:0]  iq_phys_rs1  [0:`IQ_DEPTH-1];
    reg [5:0]  iq_phys_rs2  [0:`IQ_DEPTH-1];
    reg        iq_rs1_ready [0:`IQ_DEPTH-1];
    reg        iq_rs2_ready [0:`IQ_DEPTH-1];
    reg [31:0] iq_rs1_data  [0:`IQ_DEPTH-1];
    reg [31:0] iq_rs2_data  [0:`IQ_DEPTH-1];
    reg [31:0] iq_imm       [0:`IQ_DEPTH-1];
    reg [31:0] iq_pc        [0:`IQ_DEPTH-1];
    reg [3:0]  iq_rob_idx   [0:`IQ_DEPTH-1];
    reg        iq_is_branch [0:`IQ_DEPTH-1];
    reg        iq_is_load   [0:`IQ_DEPTH-1];
    reg        iq_is_store  [0:`IQ_DEPTH-1];
    reg        iq_is_jump   [0:`IQ_DEPTH-1];
    reg        iq_writes_rd [0:`IQ_DEPTH-1];
    reg        iq_uses_rs2  [0:`IQ_DEPTH-1];
    reg        iq_pred_taken[0:`IQ_DEPTH-1];
    reg [31:0] iq_pred_tgt  [0:`IQ_DEPTH-1];
    reg [2:0]  iq_mem_type  [0:`IQ_DEPTH-1];
    reg [3:0]  iq_age       [0:`IQ_DEPTH-1]; // For oldest-first selection

    // Count valid entries
    reg [3:0] valid_count;
    assign iq_full = (valid_count >= `IQ_DEPTH);

    // ========================================================================
    // Find free slot for dispatch (first invalid entry)
    // ========================================================================
    reg [2:0] free_slot;
    reg       free_found;
    integer   fi;

    always @(*) begin
        free_slot  = 3'd0;
        free_found = 1'b0;
        for (fi = 0; fi < `IQ_DEPTH; fi = fi + 1) begin
            if (!iq_valid[fi] && !free_found) begin
                free_slot  = fi[2:0];
                free_found = 1'b1;
            end
        end
    end

    // ========================================================================
    // Find ready-to-issue entry (oldest with both operands ready)
    // Loads wait if an older store is still in the IQ
    // ========================================================================
    reg [2:0] issue_slot;
    reg       issue_found;
    reg [3:0] oldest_age;
    reg       older_store_pending;
    integer   ii, si;

    always @(*) begin
        issue_slot  = 3'd0;
        issue_found = 1'b0;
        oldest_age  = 4'd0;
        if (!issue_stall) begin
            for (ii = 0; ii < `IQ_DEPTH; ii = ii + 1) begin
                older_store_pending = 1'b0;
                if (iq_is_load[ii]) begin
                    for (si = 0; si < `IQ_DEPTH; si = si + 1) begin
                        if (iq_valid[si] && iq_is_store[si] && (iq_age[si] > iq_age[ii]))
                            older_store_pending = 1'b1;
                    end
                end
                if (iq_valid[ii] && iq_rs1_ready[ii] && iq_rs2_ready[ii] && !older_store_pending) begin
                    if (!issue_found || iq_age[ii] > oldest_age) begin
                        issue_slot  = ii[2:0];
                        issue_found = 1'b1;
                        oldest_age  = iq_age[ii];
                    end
                end
            end
        end
    end

    // ========================================================================
    // Main Logic
    // ========================================================================
    integer k;
    wire do_dispatch = dispatch_en && free_found && !iq_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            valid_count <= 4'd0;
            issue_valid <= 1'b0;
            for (k = 0; k < `IQ_DEPTH; k = k + 1) begin
                iq_valid[k]     <= 1'b0;
                iq_rs1_ready[k] <= 1'b0;
                iq_rs2_ready[k] <= 1'b0;
                iq_age[k]       <= 4'd0;
            end
        end else begin
            issue_valid <= 1'b0;

            // -----------------------------------------------------------------
            // Age increment & CDB Wakeup: update operand readiness
            // -----------------------------------------------------------------
            for (k = 0; k < `IQ_DEPTH; k = k + 1) begin
                if (iq_valid[k]) begin
                    if (iq_age[k] != 4'hF)
                        iq_age[k] <= iq_age[k] + 4'd1;
                    if (cdb_valid) begin
                        if (!iq_rs1_ready[k] && iq_phys_rs1[k] == cdb_phys_rd) begin
                            iq_rs1_ready[k] <= 1'b1;
                            iq_rs1_data[k]  <= cdb_data;
                        end
                        if (!iq_rs2_ready[k] && iq_phys_rs2[k] == cdb_phys_rd) begin
                            iq_rs2_ready[k] <= 1'b1;
                            iq_rs2_data[k]  <= cdb_data;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // Issue: send oldest ready entry to execute
            // -----------------------------------------------------------------
            if (issue_found) begin
                issue_valid           <= 1'b1;
                issue_fu_type         <= iq_fu_type[issue_slot];
                issue_alu_op          <= iq_alu_op[issue_slot];
                issue_phys_rd         <= iq_phys_rd[issue_slot];
                issue_rs1_data        <= iq_rs1_data[issue_slot];
                issue_rs2_data        <= iq_rs2_data[issue_slot];
                issue_imm             <= iq_imm[issue_slot];
                issue_pc              <= iq_pc[issue_slot];
                issue_rob_idx         <= iq_rob_idx[issue_slot];
                issue_is_branch       <= iq_is_branch[issue_slot];
                issue_is_load         <= iq_is_load[issue_slot];
                issue_is_store        <= iq_is_store[issue_slot];
                issue_is_jump         <= iq_is_jump[issue_slot];
                issue_writes_rd       <= iq_writes_rd[issue_slot];
                issue_uses_rs2        <= iq_uses_rs2[issue_slot];
                issue_predicted_taken <= iq_pred_taken[issue_slot];
                issue_predicted_target<= iq_pred_tgt[issue_slot];
                issue_mem_type        <= iq_mem_type[issue_slot];
                iq_valid[issue_slot]  <= 1'b0;
                iq_age[issue_slot]    <= 4'd0;
            end

            // -----------------------------------------------------------------
            // Dispatch: add new entry
            // -----------------------------------------------------------------
            if (do_dispatch) begin
                iq_valid[free_slot]     <= 1'b1;
                iq_fu_type[free_slot]   <= dispatch_fu_type;
                iq_alu_op[free_slot]    <= dispatch_alu_op;
                iq_phys_rd[free_slot]   <= dispatch_phys_rd;
                iq_phys_rs1[free_slot]  <= dispatch_phys_rs1;
                iq_phys_rs2[free_slot]  <= dispatch_phys_rs2;
                iq_rs1_data[free_slot]  <= dispatch_rs1_data;
                iq_rs2_data[free_slot]  <= dispatch_rs2_data;
                iq_imm[free_slot]       <= dispatch_imm;
                iq_pc[free_slot]        <= dispatch_pc;
                iq_rob_idx[free_slot]   <= dispatch_rob_idx;
                iq_is_branch[free_slot] <= dispatch_is_branch;
                iq_is_load[free_slot]   <= dispatch_is_load;
                iq_is_store[free_slot]  <= dispatch_is_store;
                iq_is_jump[free_slot]   <= dispatch_is_jump;
                iq_writes_rd[free_slot] <= dispatch_writes_rd;
                iq_uses_rs2[free_slot]  <= dispatch_uses_rs2;
                iq_pred_taken[free_slot]<= dispatch_predicted_taken;
                iq_pred_tgt[free_slot]  <= dispatch_predicted_target;
                iq_mem_type[free_slot]  <= dispatch_mem_type;
                iq_age[free_slot]       <= 4'd0;

                // Check if operands are already ready via CDB this cycle
                iq_rs1_ready[free_slot] <= dispatch_rs1_ready ||
                    (!dispatch_uses_rs1) ||
                    (cdb_valid && dispatch_phys_rs1 == cdb_phys_rd);
                iq_rs2_ready[free_slot] <= dispatch_rs2_ready ||
                    (!dispatch_uses_rs2) ||
                    (cdb_valid && dispatch_phys_rs2 == cdb_phys_rd);

                if (cdb_valid && !dispatch_rs1_ready && dispatch_phys_rs1 == cdb_phys_rd)
                    iq_rs1_data[free_slot] <= cdb_data;
                if (cdb_valid && !dispatch_rs2_ready && dispatch_phys_rs2 == cdb_phys_rd)
                    iq_rs2_data[free_slot] <= cdb_data;
            end

            case ({do_dispatch, issue_found})
                2'b10: valid_count <= valid_count + 4'd1;
                2'b01: valid_count <= valid_count - 4'd1;
                default: valid_count <= valid_count;
            endcase
        end
    end

endmodule
