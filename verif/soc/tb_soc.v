`timescale 1ns/1ps
// Full-SoC program harness: 4 cores, L1I/L1D, MESI bus, L2, main memory.
// +hex=<file> (one 32-bit word per line) is loaded into main memory; every
// core starts at 0 and runs it. The run ends when core 0 stores to TOHOST
// (0xFFF0): 1 = pass, (n << 1) | 1 = fail at test n. With +all, the run
// waits until all four cores have written TOHOST and reports each.
// A write to the EXIT register (0x8000_0008) also ends the run: 1 = pass.
// UART output is printed as it is sent; +baud_clks=<n> sets the UART bit time
// (default 4 cycles so that simulations stay short).
`include "common_defs.vh"
`include "mesi_defines.vh"
module tb_soc;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  wire [3:0] core_active; wire mem_busy;
  wire uart_txd; wire [15:0] leds; wire [31:0] hex_value, exit_value; wire exit_valid;
  quad_core_top #(.UART_CLKS_PER_BIT(4)) dut(.clk(clk), .rst_n(rst_n), .core_active(core_active), .mem_busy(mem_busy),
                    .uart_txd(uart_txd), .leds(leds), .hex_value(hex_value),
                    .exit_value(exit_value), .exit_valid(exit_valid));

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

  // +ctrace: print every instruction hart 0 retires (pc, rd, result), for
  // comparing two versions of the design
  reg ctrace;
  initial ctrace = $test$plusargs("ctrace");
  wire [3:0] ct_idx = dut.core_gen[0].u_core.rob_commit_idx;
  always @(posedge clk) if (ctrace && rst_n && dut.core_gen[0].u_core.rob_commit_valid)
    $display("C %h x%0d %h", dut.core_gen[0].u_core.u_rob.rob_pc[ct_idx],
             dut.core_gen[0].u_core.rob_commit_writes_rd ? dut.core_gen[0].u_core.rob_commit_arch_rd : 5'd0,
             dut.core_gen[0].u_core.rob_commit_result);

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
      if (exit_valid) begin
        if (exit_value == 32'd1) $display("\nRESULT PASS cycles=%0d leds=%h hex=%h", cycles, leds, hex_value);
        else                     $display("\nRESULT FAIL exit=%0d cycles=%0d", exit_value, cycles);
        $finish;
      end
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
