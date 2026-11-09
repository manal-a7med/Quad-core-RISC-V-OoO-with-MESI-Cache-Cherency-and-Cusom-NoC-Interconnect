`timescale 1ns / 1ps
`include "common_defs.vh"

module branch_unit (
    input  wire [2:0]  branch_type,
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [31:0] pc,
    input  wire [31:0] imm,
    input  wire        is_branch,
    input  wire        is_jump,
    input  wire        is_jalr,
    input  wire        predicted_taken,
    input  wire [31:0] predicted_target,
    
    output reg         branch_taken,
    output reg  [31:0] branch_target,
    output reg         mispredicted,
    output reg  [31:0] link_addr
);

    always @(*) begin
        branch_taken = 1'b0;
        branch_target = pc + imm;
        link_addr = pc + 4;
        
        if (is_jump) branch_taken = 1'b1;
        if (is_jalr) branch_target = (rs1_data + imm) & ~32'd1;
        
        if (is_branch) begin
            case(branch_type)
                3'b000: branch_taken = (rs1_data == rs2_data);
                3'b001: branch_taken = (rs1_data != rs2_data);
                3'b100: branch_taken = ($signed(rs1_data) < $signed(rs2_data));
                3'b101: branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
                3'b110: branch_taken = (rs1_data < rs2_data);
                3'b111: branch_taken = (rs1_data >= rs2_data);
                default: branch_taken = 1'b0;
            endcase
        end
        
        mispredicted = (branch_taken != predicted_taken) || (branch_taken && (branch_target != predicted_target));
    end
endmodule
