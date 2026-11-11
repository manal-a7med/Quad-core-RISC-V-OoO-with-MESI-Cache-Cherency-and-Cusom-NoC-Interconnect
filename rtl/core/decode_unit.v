`timescale 1ns / 1ps
`include "common_defs.vh"

module decode_unit (
    input  wire [31:0] instr,
    input  wire        instr_valid,
    input  wire [31:0] pc,
    
    output reg  [6:0]  opcode,
    output reg  [4:0]  rd,
    output reg  [4:0]  rs1,
    output reg  [4:0]  rs2,
    output reg  [31:0] imm,
    output reg  [3:0]  alu_op,
    output reg  [1:0]  fu_type,
    output reg  [2:0]  mem_type,
    output reg         is_branch,
    output reg         is_load,
    output reg         is_store,
    output reg         is_jump,
    output reg         uses_rs1,
    output reg         uses_rs2,
    output reg         writes_rd,
    output reg         illegal_instr,
    output reg         is_csr,        // CSRRW/S/C[I]; imm[11:0] = CSR address
    output reg  [1:0]  csr_op,        // 01 write, 10 set, 11 clear
    output reg         csr_uimm,      // source is the 5-bit rs1 field, not a register
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         is_mret,
    output reg         decoded_valid
);

    always @(*) begin
        opcode = instr[6:0];
        rd = instr[11:7];
        rs1 = instr[19:15];
        rs2 = instr[24:20];
        imm = 32'd0;
        alu_op = 4'd0;
        fu_type = 2'd0;
        mem_type = instr[14:12];
        is_branch = 1'b0;
        is_load = 1'b0;
        is_store = 1'b0;
        is_jump = 1'b0;
        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;
        writes_rd = 1'b0;
        illegal_instr = 1'b0;
        is_csr = 1'b0; csr_op = 2'b00; csr_uimm = 1'b0;
        is_ecall = 1'b0; is_ebreak = 1'b0; is_mret = 1'b0;
        decoded_valid = instr_valid && (instr != 32'h00000013);

        case(opcode)
            7'b0110011: begin // R-type
                uses_rs1 = 1'b1; uses_rs2 = 1'b1; writes_rd = (rd != 5'd0);
                fu_type = `FU_ALU;
                case (instr[14:12]) // funct3
                    3'b000: alu_op = instr[30] ? `ALU_SUB : `ALU_ADD;  // ADD/SUB
                    3'b001: alu_op = `ALU_SLL;
                    3'b010: alu_op = `ALU_SLT;
                    3'b011: alu_op = `ALU_SLTU;
                    3'b100: alu_op = `ALU_XOR;
                    3'b101: alu_op = instr[30] ? `ALU_SRA : `ALU_SRL;  // SRL/SRA
                    3'b110: alu_op = `ALU_OR;
                    3'b111: alu_op = `ALU_AND;
                endcase
            end
            7'b0010011: begin // I-type ALU
                uses_rs1 = 1'b1; writes_rd = (rd != 5'd0);
                fu_type = `FU_ALU;
                imm = {{20{instr[31]}}, instr[31:20]};
                case (instr[14:12]) // funct3
                    3'b000: alu_op = `ALU_ADD;   // ADDI
                    3'b001: alu_op = `ALU_SLL;   // SLLI
                    3'b010: alu_op = `ALU_SLT;   // SLTI
                    3'b011: alu_op = `ALU_SLTU;  // SLTIU
                    3'b100: alu_op = `ALU_XOR;   // XORI
                    3'b101: alu_op = instr[30] ? `ALU_SRA : `ALU_SRL;  // SRLI/SRAI
                    3'b110: alu_op = `ALU_OR;    // ORI
                    3'b111: alu_op = `ALU_AND;   // ANDI
                endcase
            end
            7'b0100011: begin // S-type
                uses_rs1 = 1'b1; uses_rs2 = 1'b1; is_store = 1'b1;
                fu_type = `FU_STORE; alu_op = `ALU_ADD;
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            end
            7'b0000011: begin // L-type
                uses_rs1 = 1'b1; writes_rd = (rd != 5'd0); is_load = 1'b1;
                fu_type = `FU_LOAD; alu_op = `ALU_ADD;
                imm = {{20{instr[31]}}, instr[31:20]};
            end
            7'b1100011: begin // B-type
                uses_rs1 = 1'b1; uses_rs2 = 1'b1; is_branch = 1'b1;
                fu_type = `FU_BRANCH;
                imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
            end
            7'b0110111: begin // LUI
                writes_rd = (rd != 5'd0);
                fu_type = `FU_ALU; alu_op = `ALU_PASS_B;
                imm = {instr[31:12], 12'd0};
            end
            7'b0010111: begin // AUIPC
                writes_rd = (rd != 5'd0);
                // rd = pc + (U-imm). The sum is formed here, so the ALU must pass
                // operand B through; ALU_ADD would add a stale rs1 value.
                fu_type = `FU_ALU; alu_op = `ALU_PASS_B;
                imm = pc + {instr[31:12], 12'd0};
            end
            7'b1101111: begin // JAL
                writes_rd = (rd != 5'd0); is_jump = 1'b1;
                // alu_op distinguishes JAL from JALR downstream (is_jalr is
                // is_jump && alu_op == ALU_ADD), so JAL must not use ALU_ADD.
                fu_type = `FU_BRANCH; alu_op = `ALU_PASS_B;
                imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
            end
            7'b1100111: begin // JALR
                uses_rs1 = 1'b1; writes_rd = (rd != 5'd0); is_jump = 1'b1;
                fu_type = `FU_BRANCH; alu_op = `ALU_ADD;
                imm = {{20{instr[31]}}, instr[31:20]};
            end
            7'b0001111: begin // FENCE / FENCE.I: no-op on a single in-order-commit
                fu_type = `FU_ALU; alu_op = `ALU_ADD; // core (memory ordering is P3)
            end
            7'b1110011: begin // SYSTEM
                fu_type = `FU_ALU; alu_op = `ALU_PASS_B;
                if (instr[14:12] == 3'b000) begin
                    if (rd == 5'd0 && rs1 == 5'd0) begin
                        case (instr[31:20])
                            12'h000: is_ecall  = 1'b1;
                            12'h001: is_ebreak = 1'b1;
                            12'h302: is_mret   = 1'b1;
                            12'h105: ;                     // WFI: no-op
                            default: illegal_instr = 1'b1;
                        endcase
                    end else
                        illegal_instr = 1'b1;
                end else if (instr[14:12] == 3'b100) begin
                    illegal_instr = 1'b1;
                end else begin
                    is_csr   = 1'b1;
                    csr_op   = instr[13:12];
                    csr_uimm = instr[14];
                    uses_rs1 = !instr[14];
                    writes_rd = (rd != 5'd0);
                    imm      = {20'd0, instr[31:20]};
                end
            end
            default: illegal_instr = 1'b1;
        endcase
    end
endmodule
