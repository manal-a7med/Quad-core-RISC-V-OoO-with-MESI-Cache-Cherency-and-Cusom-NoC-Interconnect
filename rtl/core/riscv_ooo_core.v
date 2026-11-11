`timescale 1ns / 1ps
// ============================================================================
// riscv_ooo_core.v — RISC-V Out-of-Order Core Top-Level Wrapper
// ============================================================================
// Instantiates and connects all pipeline stages:
//   Fetch → Decode → Rename → Issue Queue → Execute → ROB Commit
// Implements pipeline registers, stall/flush control, and CDB broadcast.
// ============================================================================

`include "common_defs.vh"

module riscv_ooo_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  core_id,

    // I-Cache interface
    output wire [31:0] icache_addr,
    input  wire [31:0] icache_rdata,
    output wire        icache_req,
    input  wire        icache_ack,

    // D-Cache interface
    output wire [31:0] dcache_addr,
    output wire [31:0] dcache_wdata,
    input  wire [31:0] dcache_rdata,
    output wire        dcache_req,
    output wire        dcache_wr,
    input  wire        dcache_ack,
    output wire [2:0]  dcache_mem_type
);

    // ========================================================================
    // Internal Wires
    // ========================================================================

    // --- Pipeline control ---
    wire pipeline_stall;
    wire pipeline_flush;
    wire [31:0] flush_redirect_pc;

    // --- Fetch outputs ---
    wire [31:0] fetch_pc, fetch_instr;
    wire        fetch_valid, fetch_predicted_taken;
    wire [31:0] fetch_predicted_target;

    // --- Decode outputs ---
    wire [6:0]  dec_opcode;
    wire [4:0]  dec_rd, dec_rs1, dec_rs2;
    wire [31:0] dec_imm;
    wire [3:0]  dec_alu_op;
    wire [1:0]  dec_fu_type;
    wire [2:0]  dec_mem_type;
    wire        dec_is_branch, dec_is_load, dec_is_store, dec_is_jump;
    wire        dec_uses_rs1, dec_uses_rs2, dec_writes_rd;
    wire        dec_illegal, dec_valid;

    // --- Rename outputs ---
    wire [5:0]  ren_phys_rs1, ren_phys_rs2, ren_phys_rd_new, ren_phys_rd_old;
    wire        ren_ready;

    // --- Register file outputs ---
    wire [31:0] rf_rs1_data, rf_rs2_data;
    wire        rf_rs1_ready, rf_rs2_ready;

    // --- Issue queue outputs ---
    wire        iq_issue_valid;
    wire [1:0]  iq_fu_type;
    wire [3:0]  iq_alu_op;
    wire [5:0]  iq_phys_rd;
    wire [31:0] iq_rs1_data, iq_rs2_data, iq_imm, iq_pc;
    wire [3:0]  iq_rob_idx;
    wire        iq_is_branch, iq_is_load, iq_is_store, iq_is_jump;
    wire        iq_writes_rd, iq_predicted_taken, iq_uses_rs2;
    wire [31:0] iq_predicted_target;
    wire [2:0]  iq_mem_type;
    wire        iq_full;

    // --- ALU outputs ---
    wire [31:0] alu_result;
    wire        alu_zero;

    // --- Branch unit outputs ---
    wire        br_taken, br_mispredicted;
    wire [31:0] br_target, br_link_addr;

    // --- ROB outputs ---
    wire [3:0]  rob_alloc_idx;
    wire        rob_full;
    wire        rob_commit_valid;
    wire [4:0]  rob_commit_arch_rd;
    wire [5:0]  rob_commit_phys_rd, rob_commit_phys_rd_old;
    wire        rob_commit_writes_rd, rob_commit_is_store;
    wire [31:0] rob_commit_result;
    wire [3:0]  rob_commit_idx;
    wire        rob_flush_out;
    wire [31:0] rob_flush_redirect_pc;

    // --- LSU outputs ---
    wire        lsu_result_valid;
    wire [31:0] lsu_result_data;
    wire [5:0]  lsu_result_phys_rd;
    wire [3:0]  lsu_result_rob_idx;
    wire        lsu_full;

    // --- CDB (Common Data Bus) ---
    wire        cdb_valid;
    wire [5:0]  cdb_phys_rd;
    wire [31:0] cdb_data;
    wire [3:0]  cdb_rob_idx;
    wire        cdb_mispredicted;
    wire [31:0] cdb_branch_target;

    // --- Pipeline control computation ---
    assign pipeline_stall = rob_full || iq_full || lsu_full || !ren_ready;
    assign pipeline_flush = rob_flush_out;
    assign flush_redirect_pc = rob_flush_redirect_pc;

    // --- Track in-flight load to prevent CDB/ROB completion collision ---
    reg load_in_flight;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || pipeline_flush)
            load_in_flight <= 1'b0;
        else if (lsu_result_valid)
            load_in_flight <= 1'b0;
        else if (iq_issue_valid && iq_is_load)
            load_in_flight <= 1'b1;
    end

    wire iq_issue_stall = load_in_flight || (iq_issue_valid && iq_is_load);

    // --- CDB mux: ALU/Jump results vs Load results ---
    wire alu_exec_valid = iq_issue_valid && !iq_is_load && !iq_is_store;
    wire alu_cdb_valid  = alu_exec_valid && iq_writes_rd;

    assign cdb_valid   = alu_cdb_valid || lsu_result_valid;
    assign cdb_phys_rd = lsu_result_valid ? lsu_result_phys_rd : iq_phys_rd;
    assign cdb_data    = lsu_result_valid ? lsu_result_data :
                         ((iq_is_branch || iq_is_jump) ? br_link_addr : alu_result);
    assign cdb_rob_idx = lsu_result_valid ? lsu_result_rob_idx : iq_rob_idx;
    assign cdb_mispredicted  = (iq_issue_valid && (iq_is_branch || iq_is_jump)) ? br_mispredicted : 1'b0;
    assign cdb_branch_target = br_target;

    // ROB completion also fires for stores, branches, and x0-dest instructions
    wire rob_complete_en = (iq_issue_valid && !iq_is_load) || lsu_result_valid;

    // --- Decode valid gated by stall ---
    wire dispatch_en = dec_valid && !pipeline_stall && !pipeline_flush;

    // ========================================================================
    // Pipeline Stage Registers (Fetch → Decode)
    // ========================================================================
    reg [31:0] fd_pc, fd_instr;
    reg        fd_valid, fd_pred_taken;
    reg [31:0] fd_pred_target;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || pipeline_flush) begin
            fd_valid <= 1'b0;
        end else if (!pipeline_stall) begin
            fd_valid       <= fetch_valid;
            fd_pc          <= fetch_pc;
            fd_instr       <= fetch_instr;
            fd_pred_taken  <= fetch_predicted_taken;
            fd_pred_target <= fetch_predicted_target;
        end
    end

    // ========================================================================
    // Module Instantiations
    // ========================================================================

    // --- Fetch Unit ---
    fetch_unit u_fetch (
        .clk              (clk),
        .rst_n            (rst_n),
        .stall            (pipeline_stall),
        .flush            (pipeline_flush),
        .redirect_pc      (flush_redirect_pc),
        .icache_data      (icache_rdata),
        .icache_valid     (icache_ack),
        .icache_ready     (icache_req),
        .pc_out           (fetch_pc),
        .instr_out        (fetch_instr),
        .instr_valid      (fetch_valid),
        .predicted_taken  (fetch_predicted_taken),
        .predicted_target (fetch_predicted_target),
        .btb_update_en    (pipeline_flush),
        .btb_update_pc    (iq_pc),
        .btb_update_target(br_target),
        .btb_update_taken (br_taken)
    );

    assign icache_addr = fetch_pc;

    // --- Decode Unit ---
    decode_unit u_decode (
        .instr       (fd_instr),
        .instr_valid (fd_valid),
        .pc          (fd_pc),
        .opcode      (dec_opcode),
        .rd          (dec_rd),
        .rs1         (dec_rs1),
        .rs2         (dec_rs2),
        .imm         (dec_imm),
        .alu_op      (dec_alu_op),
        .fu_type     (dec_fu_type),
        .mem_type    (dec_mem_type),
        .is_branch   (dec_is_branch),
        .is_load     (dec_is_load),
        .is_store    (dec_is_store),
        .is_jump     (dec_is_jump),
        .uses_rs1    (dec_uses_rs1),
        .uses_rs2    (dec_uses_rs2),
        .writes_rd   (dec_writes_rd),
        .illegal_instr(dec_illegal),
        .decoded_valid(dec_valid)
    );

    // --- Rename Unit ---
    rename_unit u_rename (
        .clk             (clk),
        .rst_n           (rst_n),
        .rename_en       (dispatch_en),
        .arch_rs1        (dec_rs1),
        .arch_rs2        (dec_rs2),
        .arch_rd         (dec_rd),
        .writes_rd       (dec_writes_rd),
        .phys_rs1        (ren_phys_rs1),
        .phys_rs2        (ren_phys_rs2),
        .phys_rd_new     (ren_phys_rd_new),
        .phys_rd_old     (ren_phys_rd_old),
        .rename_ready    (ren_ready),
        .commit_en       (rob_commit_valid && rob_commit_writes_rd),
        .commit_arch_rd  (rob_commit_arch_rd),
        .commit_phys_rd  (rob_commit_phys_rd),
        .commit_phys_old (rob_commit_phys_rd_old),
        .flush           (pipeline_flush),
        .stall           (pipeline_stall)
    );

    // --- Physical Register File ---
    register_file u_regfile (
        .clk           (clk),
        .rst_n         (rst_n),
        .rd_addr1      (ren_phys_rs1),
        .rd_data1      (rf_rs1_data),
        .rd_addr2      (ren_phys_rs2),
        .rd_data2      (rf_rs2_data),
        .wr_en         (cdb_valid),
        .wr_addr       (cdb_phys_rd),
        .wr_data       (cdb_data),
        .ready_rd1     (rf_rs1_ready),
        .ready_rd2     (rf_rs2_ready),
        .set_ready_en  (cdb_valid),
        .set_ready_addr(cdb_phys_rd),
        .clr_ready_en  (dispatch_en && dec_writes_rd),
        .clr_ready_addr(ren_phys_rd_new),
        .flush         (pipeline_flush)
    );

    // --- Issue Queue ---
    issue_queue u_iq (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .dispatch_en            (dispatch_en),
        .dispatch_fu_type       (dec_fu_type),
        .dispatch_alu_op        (dec_alu_op),
        .dispatch_phys_rd       (ren_phys_rd_new),
        .dispatch_phys_rs1      (ren_phys_rs1),
        .dispatch_phys_rs2      (ren_phys_rs2),
        .dispatch_rs1_ready     (rf_rs1_ready),
        .dispatch_rs2_ready     (rf_rs2_ready),
        .dispatch_rs1_data      (rf_rs1_data),
        .dispatch_rs2_data      (rf_rs2_data),
        .dispatch_imm           (dec_imm),
        .dispatch_pc            (fd_pc),
        .dispatch_rob_idx       (rob_alloc_idx),
        .dispatch_is_branch     (dec_is_branch),
        .dispatch_is_load       (dec_is_load),
        .dispatch_is_store      (dec_is_store),
        .dispatch_uses_rs1      (dec_uses_rs1),
        .dispatch_uses_rs2      (dec_uses_rs2),
        .dispatch_predicted_taken(fd_pred_taken),
        .dispatch_predicted_target(fd_pred_target),
        .dispatch_mem_type      (dec_mem_type),
        .dispatch_is_jump       (dec_is_jump),
        .dispatch_writes_rd     (dec_writes_rd),
        .cdb_valid              (cdb_valid),
        .cdb_phys_rd            (cdb_phys_rd),
        .cdb_data               (cdb_data),
        .issue_valid            (iq_issue_valid),
        .issue_fu_type          (iq_fu_type),
        .issue_alu_op           (iq_alu_op),
        .issue_phys_rd          (iq_phys_rd),
        .issue_rs1_data         (iq_rs1_data),
        .issue_rs2_data         (iq_rs2_data),
        .issue_imm              (iq_imm),
        .issue_pc               (iq_pc),
        .issue_rob_idx          (iq_rob_idx),
        .issue_is_branch        (iq_is_branch),
        .issue_is_load          (iq_is_load),
        .issue_is_store         (iq_is_store),
        .issue_is_jump          (iq_is_jump),
        .issue_writes_rd        (iq_writes_rd),
        .issue_uses_rs2         (iq_uses_rs2),
        .issue_predicted_taken  (iq_predicted_taken),
        .issue_predicted_target (iq_predicted_target),
        .issue_mem_type         (iq_mem_type),
        .iq_full                (iq_full),
        .issue_stall            (iq_issue_stall),
        .flush                  (pipeline_flush)
    );

    // --- ALU ---
    alu u_alu (
        .alu_op    (iq_alu_op),
        .operand_a (iq_rs1_data),
        .operand_b ((iq_uses_rs2 && !iq_is_store && !iq_is_branch) ? iq_rs2_data : iq_imm),
        .result    (alu_result),
        .zero_flag (alu_zero)
    );

    // --- Branch Unit ---
    branch_unit u_branch (
        .branch_type      (iq_mem_type),  // funct3 reused
        .rs1_data         (iq_rs1_data),
        .rs2_data         (iq_rs2_data),
        .pc               (iq_pc),
        .imm              (iq_imm),
        .is_branch        (iq_is_branch),
        .is_jump          (iq_is_jump),
        .is_jalr          (iq_is_jump && (iq_alu_op == `ALU_ADD)),
        .predicted_taken  (iq_predicted_taken),
        .predicted_target (iq_predicted_target),
        .branch_taken     (br_taken),
        .branch_target    (br_target),
        .mispredicted     (br_mispredicted),
        .link_addr        (br_link_addr)
    );

    // --- Reorder Buffer ---
    reorder_buffer u_rob (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .alloc_en              (dispatch_en),
        .alloc_pc              (fd_pc),
        .alloc_phys_rd         (ren_phys_rd_new),
        .alloc_arch_rd         (dec_rd),
        .alloc_phys_rd_old     (ren_phys_rd_old),
        .alloc_writes_rd       (dec_writes_rd),
        .alloc_is_branch       (dec_is_branch || dec_is_jump),
        .alloc_is_store        (dec_is_store),
        .alloc_is_load         (dec_is_load),
        .alloc_idx             (rob_alloc_idx),
        .rob_full              (rob_full),
        .complete_en           (rob_complete_en),
        .complete_idx          (cdb_rob_idx),
        .complete_result       (cdb_data),
        .complete_mispredicted (cdb_mispredicted),
        .complete_branch_target(cdb_branch_target),
        .complete_exception    (1'b0),
        .commit_valid          (rob_commit_valid),
        .commit_arch_rd        (rob_commit_arch_rd),
        .commit_phys_rd        (rob_commit_phys_rd),
        .commit_phys_rd_old    (rob_commit_phys_rd_old),
        .commit_writes_rd      (rob_commit_writes_rd),
        .commit_is_store       (rob_commit_is_store),
        .commit_result         (rob_commit_result),
        .commit_rob_idx        (rob_commit_idx),
        .flush_out             (rob_flush_out),
        .flush_redirect_pc     (rob_flush_redirect_pc),
        .flush_in              (1'b0)  // External flush not used
    );

    // --- Load/Store Unit ---
    load_store_unit u_lsu (
        .clk            (clk),
        .rst_n          (rst_n),
        .enqueue_en     (iq_issue_valid && (iq_is_load || iq_is_store)),
        .is_load        (iq_is_load),
        .is_store       (iq_is_store),
        .addr           (alu_result),   // Address computed by ALU (base + offset)
        .store_data     (iq_rs2_data),
        .mem_type       (iq_mem_type),
        .rob_idx        (iq_rob_idx),
        .phys_rd        (iq_phys_rd),
        .dcache_addr    (dcache_addr),
        .dcache_wdata   (dcache_wdata),
        .dcache_rdata   (dcache_rdata),
        .dcache_req     (dcache_req),
        .dcache_wr      (dcache_wr),
        .dcache_ack     (dcache_ack),
        .dcache_mem_type(dcache_mem_type),
        .result_valid   (lsu_result_valid),
        .result_data    (lsu_result_data),
        .result_phys_rd (lsu_result_phys_rd),
        .result_rob_idx (lsu_result_rob_idx),
        .lsq_full       (lsu_full),
        .commit_store_en(rob_commit_valid && rob_commit_is_store),
        .flush          (pipeline_flush)
    );

endmodule
