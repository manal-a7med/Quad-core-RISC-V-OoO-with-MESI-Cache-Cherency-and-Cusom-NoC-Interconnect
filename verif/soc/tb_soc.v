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
  reg [8*1024-1:0] hexfile;   // up to 1024 characters (CI checkouts have long paths)
  integer k, cycles, timeout, done_mask, fails;
  reg all;
  initial begin
    for (k = 0; k < 16384; k = k + 1) words[k] = 32'h0;
    if (!$value$plusargs("hex=%s", hexfile)) begin $display("tb_soc: +hex=<file>"); $finish; end
    if (hexfile[8*1024-1 -: 8] != 0) begin $display("tb_soc: +hex path longer than 1024 characters"); $finish; end
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

  // +perf: hart 0 event counts and bus transaction counts, printed at the end of the run
  //   branches / mispredicts  committed branches and jumps, and how many flushed
  //   rob_full, iq_full       cycles dispatch was stalled by a full ROB / issue queue
  //   fetch_wait              cycles the core asked for an instruction and got none
  //   issue_idle              cycles nothing was issued although the issue queue was not empty
  reg perf;
  initial perf = $test$plusargs("perf");
  integer pf_commit, pf_br, pf_misp, pf_rob_full, pf_iq_full, pf_fetch_wait, pf_issue_idle, pf_serial;
  initial begin
    pf_commit = 0; pf_br = 0; pf_misp = 0; pf_rob_full = 0; pf_iq_full = 0; pf_fetch_wait = 0;
    pf_issue_idle = 0; pf_serial = 0;
  end
  always @(posedge clk) if (rst_n) begin
    if (dut.core_gen[0].u_core.u_rob.do_commit) begin
      pf_commit = pf_commit + 1;
      if (dut.core_gen[0].u_core.u_rob.rob_is_branch[dut.core_gen[0].u_core.u_rob.head]) begin
        pf_br = pf_br + 1;
        if (dut.core_gen[0].u_core.u_rob.rob_mispredicted[dut.core_gen[0].u_core.u_rob.head]) pf_misp = pf_misp + 1;
      end
    end
    if (dut.core_gen[0].u_core.rob_full)     pf_rob_full = pf_rob_full + 1;
    else if (dut.core_gen[0].u_core.iq_full) pf_iq_full  = pf_iq_full + 1;
    else if (dut.core_gen[0].u_core.serial_stall) pf_serial = pf_serial + 1;
    if (dut.core_gen[0].u_core.icache_req && !dut.core_gen[0].u_core.icache_ack) pf_fetch_wait = pf_fetch_wait + 1;
    if (!dut.core_gen[0].u_core.iq_issue_valid && dut.core_gen[0].u_core.u_iq.valid_count != 0) pf_issue_idle = pf_issue_idle + 1;
  end
  // Bus transactions of all four data caches
  integer pf_rd, pf_rdx, pf_upgr, pf_flush;
  initial begin pf_rd = 0; pf_rdx = 0; pf_upgr = 0; pf_flush = 0; end
  genvar pg;
  generate for (pg = 0; pg < 4; pg = pg + 1) begin : pstat
    always @(posedge clk) if (rst_n && dut.core_gen[pg].u_l1d.bus_ack)
      case (dut.core_gen[pg].u_l1d.bus_cmd)
        `BUS_READ:  pf_rd    = pf_rd + 1;
        `BUS_READX: pf_rdx   = pf_rdx + 1;
        `BUS_UPGR:  pf_upgr  = pf_upgr + 1;
        `BUS_FLUSH: pf_flush = pf_flush + 1;
        default: ;
      endcase
  end endgenerate
  task perf_report;
    if (perf) $display("PERF bus busrd=%0d busrdx=%0d busupgr=%0d flush=%0d", pf_rd, pf_rdx, pf_upgr, pf_flush);
    if (perf) $display("PERF hart0 cycles=%0d commits=%0d branches=%0d mispredicts=%0d rob_full=%0d iq_full=%0d serial=%0d fetch_wait=%0d issue_idle=%0d",
                       cycles, pf_commit, pf_br, pf_misp, pf_rob_full, pf_iq_full, pf_serial, pf_fetch_wait, pf_issue_idle);
  endtask

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
        perf_report;
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
