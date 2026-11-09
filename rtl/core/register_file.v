`timescale 1ns / 1ps
`include "common_defs.vh"

module register_file (
    input  wire        clk,
    input  wire        rst_n,
    
    input  wire [5:0]  rd_addr1,
    output wire [31:0] rd_data1,
    output wire        ready_rd1,
    
    input  wire [5:0]  rd_addr2,
    output wire [31:0] rd_data2,
    output wire        ready_rd2,
    
    input  wire        wr_en,
    input  wire [5:0]  wr_addr,
    input  wire [31:0] wr_data,
    
    input  wire        set_ready_en,
    input  wire [5:0]  set_ready_addr,
    input  wire        clr_ready_en,
    input  wire [5:0]  clr_ready_addr,
    input  wire        flush
);

    reg [31:0] regs [0:63];
    reg [63:0] ready_bits;

    assign rd_data1 = (rd_addr1 == 6'd0) ? 32'd0 : regs[rd_addr1];
    assign rd_data2 = (rd_addr2 == 6'd0) ? 32'd0 : regs[rd_addr2];
    
    assign ready_rd1 = (rd_addr1 == 6'd0) ? 1'b1 : ready_bits[rd_addr1];
    assign ready_rd2 = (rd_addr2 == 6'd0) ? 1'b1 : ready_bits[rd_addr2];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready_bits <= {64{1'b1}};
            for (i = 0; i < 64; i = i + 1) begin
                regs[i] <= 32'd0;
            end
        end else begin
            if (wr_en && wr_addr != 6'd0) begin
                regs[wr_addr] <= wr_data;
            end
            if (flush) begin
                ready_bits <= {64{1'b1}};
            end else begin
                if (set_ready_en && set_ready_addr != 6'd0) begin
                    ready_bits[set_ready_addr] <= 1'b1;
                end
                if (clr_ready_en && clr_ready_addr != 6'd0) begin
                    ready_bits[clr_ready_addr] <= 1'b0;
                end
            end
        end
    end

endmodule
