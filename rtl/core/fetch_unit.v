`timescale 1ns / 1ps
// ============================================================================
// fetch_unit.v - Program counter and branch prediction
// ============================================================================
// The instruction arrives from the I-cache in the same cycle as its address,
// so the prediction is made from the instruction itself (pre-decode) and
// needs no table to find out what kind of instruction sits at a PC:
//
//   JAL             always taken; target = pc + immediate (always right)
//   conditional     direction from a table of two-bit counters indexed by the
//                   PC (bimodal predictor); target = pc + immediate
//   JALR, return    target from the return address stack (RAS)
//   JALR, other     target last seen for this PC (small untagged BTB)
//   anything else   pc + 4
//
// A wrong prediction is found when the branch executes (branch_unit compares
// the outcome with predicted_taken / predicted_target) and repaired when it
// commits, as before.
//
// Training happens at execute: counters for conditional branches, the BTB
// for JALR. The RAS is pushed and popped speculatively as calls and returns
// are fetched. Its storage is not repaired after a misprediction, only its
// stack pointer: a second pointer follows the calls and returns that commit,
// and a flush copies it back.
//
// The tables are LUT RAMs without reset, initialised by the bitstream.
// ============================================================================
`include "common_defs.vh"

module fetch_unit #(
    parameter PHT_BITS = 8,    // 256 two-bit counters
    parameter BTB_BITS = 4,    // 16 indirect-jump targets
    parameter RAS_BITS = 3     // 8 return addresses
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stall,
    input  wire        flush,
    input  wire [31:0] redirect_pc,

    input  wire [31:0] icache_data,
    input  wire        icache_valid,
    output wire        icache_ready,
    output wire [31:0] next_pc,          // PC after pc_out if this instruction is accepted

    output reg  [31:0] pc_out,
    output wire [31:0] instr_out,
    output wire        instr_valid,
    output wire        predicted_taken,
    output wire [31:0] predicted_target,

    // Training (from execute)
    input  wire        bp_update_en,     // a conditional branch or a JALR executed
    input  wire        bp_update_jalr,
    input  wire [31:0] bp_update_pc,
    input  wire [31:0] bp_update_target,
    input  wire        bp_update_taken,

    // Calls and returns that commit (RAS pointer repair)
    input  wire        commit_call,
    input  wire        commit_ret
);

    assign icache_ready = !stall;
    assign instr_out    = icache_data;
    assign instr_valid  = rst_n && icache_valid && !flush;

    wire fetch_fire = icache_valid && !stall && !flush;

    // ------------------------------------------------------------------------
    // Pre-decode
    // ------------------------------------------------------------------------
    wire [6:0] opcode  = icache_data[6:0];
    wire [4:0] rd      = icache_data[11:7];
    wire [4:0] rs1     = icache_data[19:15];
    wire       is_jal  = (opcode == 7'b1101111);
    wire       is_jalr = (opcode == 7'b1100111);
    wire       is_br   = (opcode == 7'b1100011);
    wire       rd_link  = (rd  == 5'd1) || (rd  == 5'd5);
    wire       rs1_link = (rs1 == 5'd1) || (rs1 == 5'd5);
    wire       is_call = (is_jal || is_jalr) && rd_link;
    wire       is_ret  = is_jalr && rs1_link && !rd_link;

    wire [31:0] imm_j = {{12{icache_data[31]}}, icache_data[19:12], icache_data[20],
                         icache_data[30:21], 1'b0};
    wire [31:0] imm_b = {{20{icache_data[31]}}, icache_data[7], icache_data[30:25],
                         icache_data[11:8], 1'b0};
    wire [31:0] direct_target = pc_out + (is_jal ? imm_j : imm_b);
    wire [31:0] pc_plus4      = pc_out + 32'd4;

    // ------------------------------------------------------------------------
    // Tables
    // ------------------------------------------------------------------------
    reg [1:0]  pht [0:(1<<PHT_BITS)-1];
    reg [31:0] btb [0:(1<<BTB_BITS)-1];
    reg [31:0] ras [0:(1<<RAS_BITS)-1];
    reg [RAS_BITS-1:0] sp;        // top of stack as fetched (speculative)
    reg [RAS_BITS-1:0] sp_arch;   // top of stack as committed

    integer i;
    initial begin
        for (i = 0; i < (1<<PHT_BITS); i = i + 1) pht[i] = 2'b01;   // weakly not taken
        for (i = 0; i < (1<<BTB_BITS); i = i + 1) btb[i] = 32'd0;
        for (i = 0; i < (1<<RAS_BITS); i = i + 1) ras[i] = 32'd0;
    end

    wire [1:0]  pht_rd  = pht[pc_out[PHT_BITS+1:2]];
    wire [31:0] btb_rd  = btb[pc_out[BTB_BITS+1:2]];
    wire [31:0] ras_top = ras[sp];

`ifdef CFG_NO_BP
    // Measurement build (scripts/ablation.sh): no prediction, every taken
    // branch and jump is repaired when it commits, as before P4
    assign predicted_taken  = 1'b0;
`else
    assign predicted_taken  = is_jal || is_jalr || (is_br && pht_rd[1]);
`endif
    assign predicted_target = !predicted_taken ? pc_plus4 :
                              !is_jalr         ? direct_target :
                              is_ret           ? ras_top : btb_rd;
    assign next_pc          = predicted_target;

    // ------------------------------------------------------------------------
    // Training
    // ------------------------------------------------------------------------
    wire [PHT_BITS-1:0] up_pht_idx = bp_update_pc[PHT_BITS+1:2];
    wire [1:0]          up_ctr     = pht[up_pht_idx];

    always @(posedge clk) begin
        if (bp_update_en && !bp_update_jalr)
            pht[up_pht_idx] <= bp_update_taken ? (up_ctr == 2'b11 ? 2'b11 : up_ctr + 2'b01)
                                               : (up_ctr == 2'b00 ? 2'b00 : up_ctr - 2'b01);
        if (bp_update_en && bp_update_jalr)
            btb[bp_update_pc[BTB_BITS+1:2]] <= bp_update_target;
        if (fetch_fire && is_call)
            ras[sp + 1'b1] <= pc_plus4;
    end

    // ------------------------------------------------------------------------
    // PC and RAS pointers
    // ------------------------------------------------------------------------
    wire [RAS_BITS-1:0] sp_arch_next = commit_call ? sp_arch + 1'b1 :
                                       commit_ret  ? sp_arch - 1'b1 : sp_arch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_out  <= 32'h00000000;
            sp      <= {RAS_BITS{1'b0}};
            sp_arch <= {RAS_BITS{1'b0}};
        end else begin
            sp_arch <= sp_arch_next;
            if (flush) begin
                pc_out <= redirect_pc;
                sp     <= sp_arch_next;
            end else if (fetch_fire) begin
                pc_out <= next_pc;
                if (is_call)     sp <= sp + 1'b1;
                else if (is_ret) sp <= sp - 1'b1;
            end
        end
    end

endmodule
