`timescale 1ns/1ps
`define ARCH(i) dut.u_regfile.regs[dut.u_rename.arch_rat[i]]
module tb_repro;
  reg clk=0, rst_n=0; always #5 clk=~clk;
  wire [31:0] ia; reg [31:0] ir; wire ireq; reg iack;
  wire [31:0] da, dw; reg [31:0] dr; wire dreq, dwr; reg dack; wire [2:0] dmt;
  riscv_ooo_core dut(.clk(clk),.rst_n(rst_n),.core_id(2'b0),.icache_addr(ia),.icache_rdata(ir),.icache_req(ireq),.icache_ack(iack),
    .dcache_addr(da),.dcache_wdata(dw),.dcache_rdata(dr),.dcache_req(dreq),.dcache_wr(dwr),.dcache_ack(dack),.dcache_mem_type(dmt));
  reg [31:0] imem[0:63]; integer k;
  initial begin for(k=0;k<64;k=k+1) imem[k]=32'h13; $readmemh("prog.hex",imem); end
  // Fetch past the program returns NOPs (no wrap-around, so the program runs once).
  always @(*) begin iack=ireq; ir = (ia < 32'h100) ? imem[ia[7:2]] : 32'h13; end
  reg [31:0] dmem[0:255];
  initial begin for(k=0;k<256;k=k+1) dmem[k]=0; dmem[8'h40]=32'h55; dmem[8'h80]=32'h11223344; end
  always @(posedge clk) begin
    dack<=0;
    if (rst_n && dreq && !dack) begin dack<=1;
      if (dwr) case(dmt) 3'd0: dmem[da[9:2]][da[1:0]*8+:8]<=dw[7:0]; 3'd1: dmem[da[9:2]][da[1]*16+:16]<=dw[15:0]; default: dmem[da[9:2]]<=dw; endcase
      else dr <= dmem[da[9:2]] >> (da[1:0]*8);
    end
  end
  `include "trace.vh"
  task chk(input [8*40:1] n, input [31:0] got, exp); $display("%0s got=%h exp=%h %0s", n, got, exp, got===exp?"PASS":"FAIL"); endtask
  initial begin #22 rst_n=1; #3000;
    chk("JAL x1 link",`ARCH(1),32'h0C);
    chk("JAL skipped x11 (should stay 0)",`ARCH(11),0);
    chk("JAL target x13",`ARCH(13),32'h44);
    chk("AUIPC x14",`ARCH(14),32'h801C);
    chk("LW older than SW x26",`ARCH(26),32'h55);
    chk("dmem[0x100] after SW",dmem[8'h40],32'hAA);
    chk("SB then LW fwd x29",`ARCH(29),32'h112233FF);
    chk("LBU x31",`ARCH(31),32'h33);
    $finish; end
endmodule
