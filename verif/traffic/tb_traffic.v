`timescale 1ns/1ps
// ============================================================================
// tb_traffic.v - synthetic memory traffic for the bus vs NoC comparison (P6)
// ============================================================================
// Like tb_coh_random, the four cores only spin and this testbench drives the
// CPU port of every L1 data cache itself. There are no data checks here
// (tb_coh_random does those); this bench measures how fast the memory system
// answers as the load goes up.
//
// Each port issues OPS loads and stores (STORE_PCT % stores), waiting a
// random 0 .. 2*GAP-1 idle cycles before each one (so GAP sets the offered
// load). Every access is to a line chosen so that it misses in the L1:
//
//   +pattern=0  private   each port has its own 16 lines, 4 per L1 set (the
//                         L1 has 2 ways): most accesses miss in the L1 and
//                         hit in the L2; no sharing, so it measures the plain
//                         miss path (request -> L2 -> line back)
//   +pattern=1  shared    all ports use the same 16 lines, 4 per L1 set:
//                         misses, invalidations and cache-to-cache transfers
//   +pattern=2  hotspot   all ports use the same 2 lines in one set: heavy
//                         contention for one place
//
// Printed: accesses per 1000 cycles (all ports together), average access
// latency at the CPU port, and average L1 request latency (L1 miss raised
// to acknowledge from the interconnect).
//
// Usage: vvp tb_traffic.vvp +pattern=P +gap=G [+ops=N] [+store=S] [+seed=N]
// ============================================================================
`include "common_defs.vh"
`include "mesi_defines.vh"
module tb_traffic;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  wire [3:0] core_active; wire mem_busy, uart_txd, exit_valid;
  wire [15:0] leds; wire [31:0] hex_value, exit_value;
  quad_core_top #(.UART_CLKS_PER_BIT(4)) dut (.clk(clk), .rst_n(rst_n), .core_active(core_active),
      .mem_busy(mem_busy), .uart_txd(uart_txd), .leds(leds), .hex_value(hex_value),
      .exit_value(exit_value), .exit_valid(exit_valid));

  integer pattern, gap, ops, store_pct, seed0;
  integer cycles, t_start, t_end;
  integer acc_n, acc_lat;                   // CPU-port accesses and their latency
  integer req_n, req_lat;                   // L1 requests to the interconnect
  reg [3:0] port_done = 4'h0;

  initial begin
    if (!$value$plusargs("pattern=%d", pattern)) pattern = 0;
    if (!$value$plusargs("gap=%d", gap))         gap = 8;
    if (!$value$plusargs("ops=%d", ops))         ops = 1000;
    if (!$value$plusargs("store=%d", store_pct)) store_pct = 30;
    if (!$value$plusargs("seed=%d", seed0))      seed0 = 1;
    dut.u_mem.mem[0] = 256'h0000006f;      // every core: j .
    acc_n = 0; acc_lat = 0; req_n = 0; req_lat = 0;
  end

  always @(posedge clk) cycles <= rst_n ? cycles + 1 : 0;

  // L1 request latency (request raised to acknowledge), all four L1Ds
  genvar g;
  generate for (g = 0; g < 4; g = g + 1) begin : lat
    reg busy_r = 1'b0;
    integer t0;
    always @(posedge clk) if (rst_n && t_start > 0 && port_done != 4'hF) begin
      if (dut.core_gen[g].u_l1d.bus_req && !busy_r) begin busy_r = 1'b1; t0 = cycles; end
      if (dut.core_gen[g].u_l1d.bus_ack) begin
        busy_r = 1'b0; req_n = req_n + 1; req_lat = req_lat + cycles - t0 + 1;
      end
    end
  end endgenerate

  // Line used by port p for its k-th choice
  function [31:0] line_of(input integer p, input integer r);
    case (pattern)
      0:       line_of = 32'h0000_4000 + (16 + 4 * p + r % 4) * 32 + ((r / 4) % 4) * 2048;  // own 4 sets x 4 tags
      1:       line_of = 32'h0000_4000 + (r % 4) * 32 + ((r / 4) % 4) * 2048;                // 4 sets x 4 tags, shared
      default: line_of = 32'h0000_4000 + (r % 2) * 2048;                                     // 1 set x 2 tags, shared
    endcase
  endfunction

  generate for (g = 0; g < 4; g = g + 1) begin : port
    reg        req = 0, wr = 0;
    reg [31:0] addr = 0, wdata = 0;
    integer    seed, n, cyc, t;

    initial begin
      force dut.core_gen[g].u_l1d.cpu_req      = req;
      force dut.core_gen[g].u_l1d.cpu_wr       = wr;
      force dut.core_gen[g].u_l1d.cpu_addr     = addr;
      force dut.core_gen[g].u_l1d.cpu_wdata    = wdata;
      force dut.core_gen[g].u_l1d.cpu_mem_type = `MEM_WORD;
      force dut.core_gen[g].u_l1d.cpu_amo      = `AMO_NONE;
    end

    initial begin
      seed = 0;
      #2 seed = seed0 * 4 + g + 1;
      @(posedge rst_n);
      repeat (300) @(posedge clk);                // L2 clears its set records
      if (g == 0) t_start = cycles;
      for (n = 0; n < ops; n = n + 1) begin
        if (gap > 0) repeat ($unsigned($random(seed)) % (2 * gap)) @(posedge clk);
        @(negedge clk);
        addr  = line_of(g, $unsigned($random(seed))) + 4 * g;
        wr    = ($unsigned($random(seed)) % 100) < store_pct;
        wdata = n;
        req   = 1; cyc = 0; t = cycles;
        @(negedge clk); #1;
        while (!dut.core_gen[g].u_l1d.cpu_ack && cyc < 20000) begin @(negedge clk); #1; cyc = cyc + 1; end
        if (cyc >= 20000) begin $display("ERROR port %0d: no acknowledge", g); $finish; end
        acc_n = acc_n + 1; acc_lat = acc_lat + cycles - t + 1;
        @(posedge clk); #1 req = 0; wr = 0;
      end
      port_done[g] = 1'b1;
    end
  end endgenerate

  initial begin
    cycles = 0; t_start = 0;
    #22 rst_n = 1;
    wait (port_done == 4'hF);
    t_end = cycles;
    $display("TRAFFIC pattern=%0d gap=%0d store=%0d ops=%0d cycles=%0d throughput=%0d.%0d latency=%0d.%0d l1req=%0d l1lat=%0d.%0d",
             pattern, gap, store_pct, 4 * ops, t_end - t_start,
             acc_n * 1000 / (t_end - t_start), (acc_n * 10000 / (t_end - t_start)) % 10,
             acc_lat / acc_n, (acc_lat * 10 / acc_n) % 10,
             req_n, req_lat / (req_n ? req_n : 1), (req_lat * 10 / (req_n ? req_n : 1)) % 10);
    $display("RESULT PASS");
    $finish;
  end
  always @(posedge clk) if (cycles > 50000000) begin $display("RESULT TIMEOUT"); $finish; end
endmodule
