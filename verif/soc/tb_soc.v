`timescale 1ns/1ps
// Full-SoC program harness: 4 cores, L1I/L1D, MESI bus, L2, main memory.
// +hex=<file> (one 32-bit word per line) is loaded into main memory; every
// core starts at 0 and runs it. The run ends when core 0 stores to TOHOST
// (0xFFF0): 1 = pass, (n << 1) | 1 = fail at test n. With +all, the run
// waits until all four cores have written TOHOST and reports each.
`include "common_defs.vh"
`include "mesi_defines.vh"
module tb_soc;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  wire [3:0] core_active; wire mem_busy;
  quad_core_top dut(.clk(clk), .rst_n(rst_n), .core_active(core_active), .mem_busy(mem_busy));

  reg [31:0] words [0:16383];
  reg [1023:0] hexfile;
  integer k, cycles, timeout, done_mask, fails;
  reg all;
  initial begin
    for (k = 0; k < 16384; k = k + 1) words[k] = 32'h0;
    if (!$value$plusargs("hex=%s", hexfile)) begin $display("tb_soc: +hex=<file>"); $finish; end
    $readmemh(hexfile, words);
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 3000000;
    all = $test$plusargs("all");
    #1;
    for (k = 0; k < 16384; k = k + 1) dut.u_mem.mem[k >> 3][(k & 7) * 32 +: 32] = words[k];
  end

  // TOHOST detection at each core's data-cache port
  genvar g;
  generate for (g = 0; g < 4; g = g + 1) begin : mon
    always @(posedge clk) if (rst_n && dut.core_gen[g].u_core.dcache_req && dut.core_gen[g].u_core.dcache_wr &&
                              dut.core_gen[g].u_core.dcache_addr == 32'h0000FFF0 && !done_mask[g]) begin
      done_mask[g] = 1'b1;
      if (dut.core_gen[g].u_core.dcache_wdata == 32'd1)
        $display("core %0d PASS cycles=%0d", g, cycles);
      else begin
        $display("core %0d FAIL test=%0d cycles=%0d", g, dut.core_gen[g].u_core.dcache_wdata >> 1, cycles);
        fails = fails + 1;
      end
    end
  end endgenerate

  initial begin
    cycles = 0; done_mask = 0; fails = 0;
    #22 rst_n = 1;
    forever begin
      @(posedge clk); cycles = cycles + 1;
      if ((!all && done_mask[0]) || done_mask == 15) begin
        if (fails == 0) $display("RESULT PASS cycles=%0d", cycles);
        else            $display("RESULT FAIL cycles=%0d", cycles);
        $finish;
      end
      if (cycles >= timeout) begin
        $display("RESULT TIMEOUT cycles=%0d done=%b", cycles, done_mask[3:0]); $finish;
      end
    end
  end
endmodule
