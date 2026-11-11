`timescale 1ns / 1ps
`include "common_defs.vh"

module alu (
    input  wire [3:0]  alu_op,
    input  wire [31:0] operand_a,
    input  wire [31:0] operand_b,
    output reg  [31:0] result,
    output wire        zero_flag
);

    assign zero_flag = (result == 32'd0);

    always @(*) begin
        case (alu_op)
            4'd0:    result = operand_a + operand_b; // ADD / ADD_PC
            4'd1:    result = operand_a - operand_b; // SUB
            4'd2:    result = operand_a & operand_b; // AND
            4'd3:    result = operand_a | operand_b; // OR
            4'd4:    result = operand_a ^ operand_b; // XOR
            4'd5:    result = operand_a << operand_b[4:0]; // SLL
            4'd6:    result = operand_a >> operand_b[4:0]; // SRL
            4'd7:    result = $signed(operand_a) >>> operand_b[4:0]; // SRA
            4'd8:    result = ($signed(operand_a) < $signed(operand_b)) ? 32'd1 : 32'd0; // SLT
            4'd9:    result = (operand_a < operand_b) ? 32'd1 : 32'd0; // SLTU
            4'd10:   result = operand_b; // PASS_B
            default: result = 32'd0;
        endcase
    end

endmodule
