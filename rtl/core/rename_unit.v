`timescale 1ns / 1ps
`include "common_defs.vh"

module rename_unit (
    input  wire        clk,
    input  wire        rst_n,
    
    input  wire        rename_en,
    input  wire [4:0]  arch_rs1,
    input  wire [4:0]  arch_rs2,
    input  wire [4:0]  arch_rd,
    input  wire        writes_rd,
    
    output wire [5:0]  phys_rs1,
    output wire [5:0]  phys_rs2,
    output wire [5:0]  phys_rd_new,
    output wire [5:0]  phys_rd_old,
    output wire        rename_ready,
    
    input  wire        commit_en,
    input  wire [4:0]  commit_arch_rd,
    input  wire [5:0]  commit_phys_rd,
    input  wire [5:0]  commit_phys_old,
    
    input  wire        flush,
    input  wire        stall
);

    reg [5:0] rat       [0:31];
    reg [5:0] arch_rat  [0:31];
    reg [5:0] free_list [0:31];
    reg [4:0] head;
    reg [4:0] arch_head;
    reg [4:0] tail;
    reg [5:0] count;

    wire alloc_phys = rename_en && writes_rd && (arch_rd != 5'd0);
    wire free_phys  = commit_en && (commit_phys_old != 6'd0);

    assign phys_rs1     = rat[arch_rs1];
    assign phys_rs2     = rat[arch_rs2];
    assign phys_rd_old  = (writes_rd && (arch_rd != 5'd0)) ? rat[arch_rd] : 6'd0;
    assign phys_rd_new  = (writes_rd && (arch_rd != 5'd0)) ? free_list[head] : 6'd0;
    assign rename_ready = (count > 0);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<32; i=i+1) begin
                rat[i]       <= i[5:0];
                arch_rat[i]  <= i[5:0];
                free_list[i] <= i[5:0] + 6'd32;
            end
            head      <= 5'd0;
            arch_head <= 5'd0;
            tail      <= 5'd0;
            count     <= 6'd32;
        end else begin
            if (free_phys) begin
                free_list[tail] <= commit_phys_old;
                tail            <= tail + 5'd1;
                arch_head       <= arch_head + 5'd1;
                if (commit_arch_rd != 5'd0)
                    arch_rat[commit_arch_rd] <= commit_phys_rd;
            end

            if (flush) begin
                for (i=0; i<32; i=i+1) begin
                    if (free_phys && (commit_arch_rd == i[4:0]) && (commit_arch_rd != 5'd0))
                        rat[i] <= commit_phys_rd;
                    else
                        rat[i] <= arch_rat[i];
                end
                head  <= free_phys ? (arch_head + 5'd1) : arch_head;
                count <= 6'd32;
            end else if (!stall) begin
                if (alloc_phys) begin
                    rat[arch_rd] <= free_list[head];
                    head         <= head + 5'd1;
                end
                case ({alloc_phys, free_phys})
                    2'b10: count <= count - 6'd1;
                    2'b01: count <= count + 6'd1;
                    default: count <= count;
                endcase
            end else if (free_phys) begin
                count <= count + 6'd1;
            end
        end
    end
endmodule
