`timescale 1ns / 1ps
`include "common_defs.vh"

module fetch_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stall,
    input  wire        flush,
    input  wire [31:0] redirect_pc,
    
    input  wire [31:0] icache_data,
    input  wire        icache_valid,
    output wire        icache_ready,
    
    output reg  [31:0] pc_out,
    output reg  [31:0] instr_out,
    output reg         instr_valid,
    output reg         predicted_taken,
    output reg  [31:0] predicted_target,
    
    input  wire        btb_update_en,
    input  wire [31:0] btb_update_pc,
    input  wire [31:0] btb_update_target,
    input  wire        btb_update_taken
);

    assign icache_ready = !stall;

    always @(*) begin
        instr_out        = icache_data;
        instr_valid      = rst_n && icache_valid && !flush;
        predicted_taken  = 1'b0;
        predicted_target = pc_out + 32'd4;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_out <= 32'h00000000;
        end else if (flush) begin
            pc_out <= redirect_pc;
        end else if (!stall && icache_valid) begin
            pc_out <= pc_out + 32'd4;
        end
    end

endmodule
