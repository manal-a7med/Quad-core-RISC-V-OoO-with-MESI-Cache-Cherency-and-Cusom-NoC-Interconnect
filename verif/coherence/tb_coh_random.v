`timescale 1ns/1ps
// ============================================================================
// tb_coh_random.v - constrained-random coherence test of the memory system
// ============================================================================
// The full SoC (quad_core_top) is instantiated, but the four cores only spin
// (`j .` at address 0): this testbench drives each L1 data cache's CPU port
// itself (by force) with random loads, stores and atomics, and checks every
// result. Everything below the CPU port is the real design: four L1D
// caches, the MESI snooping bus, L2 and main memory.
//
// Traffic. 24 lines are used, chosen so that six lines share each L1 set
// (2 ways) and each L2 set (4 ways): lines are evicted and written back at
// both levels all the time. Each 32-bit word has one owner port (word i of
// a line belongs to port i % 4, so every line is falsely shared by all four
// ports). An owner writes {owner + 1, sequence number} with an increasing
// sequence number. Two more lines hold an amoadd counter and an LR/SC
// counter shared by all ports.
//
// Checks (each load, then a final sweep):
//   * the value belongs to the word (owner tag) or is still 0
//   * a port reading its own word gets exactly its last store
//   * a load never returns a value older than the newest store that had
//     completed when the load was issued (no stale copy after an
//     invalidation), nor a value the owner has not issued yet
//   * a port never sees a word go backwards (per-location coherence)
//   * every amoadd returns a distinct old value; the counter ends at the
//     number of amoadds; every successful SC wrote a distinct value and the
//     LR/SC counter ends at the number of successful SCs
//   * at the end every port reads every word and sees the owner's last store
//   * every cycle, for every line used: if one L1D holds it in M or E, no
//     other L1D holds it at all (single writer / multiple readers, SWMR)
//
// Usage: vvp tb_coh_random.vvp [+seed=N] [+ops=N]   (ops per port, default 2000)
// ============================================================================
`include "common_defs.vh"
`include "mesi_defines.vh"
module tb_coh_random;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  wire [3:0] core_active; wire mem_busy;
  wire uart_txd; wire [15:0] leds; wire [31:0] hex_value, exit_value; wire exit_valid;
  quad_core_top #(.UART_CLKS_PER_BIT(4)) dut(.clk(clk), .rst_n(rst_n), .core_active(core_active), .mem_busy(mem_busy),
                    .uart_txd(uart_txd), .leds(leds), .hex_value(hex_value),
                    .exit_value(exit_value), .exit_valid(exit_valid));

  localparam NSETS = 4, NTAGS = 6, NLINES = NSETS * NTAGS, NWORDS = NLINES * 8;
  localparam [31:0] AMO_CTR = 32'h0000_3100, LRSC_CTR = 32'h0000_3140;
  localparam MAXV = 65536;

  function [31:0] word_addr(input integer w);
    integer line;
    begin
      line = w / 8;
      word_addr = 32'h4000 + (line / NSETS) * 32'h1000 + (line % NSETS) * 32 + (w % 8) * 4;
    end
  endfunction

  // Reference state
  reg [27:0] done_seq   [0:NWORDS-1];    // owner's last completed store
  reg [27:0] issued_seq [0:NWORDS-1];    // owner's last issued store
  reg [27:0] seen       [0:4*NWORDS-1];  // newest sequence each port has seen
  reg        amo_seen   [0:MAXV-1];
  reg        sc_seen    [0:MAXV-1];
  integer    amo_done, sc_ok, sc_fail, errors, checks, ops, seed0;
  reg [3:0]  port_done;
  integer    k, cycles;

  task error(input [8*64-1:0] what, input integer p, input integer w, input [31:0] v);
    begin
      errors = errors + 1;
      if (errors <= 10)
        $display("ERROR %0s: port %0d word %0d (addr %h) value %h  [done=%0d issued=%0d seen=%0d] cycle %0d",
                 what, p, w, word_addr(w), v, done_seq[w], issued_seq[w], seen[p*NWORDS+w], cycles);
    end
  endtask

  // Check a loaded value; min_seq is the owner's completed sequence when the
  // load was issued.
  task check_load(input integer p, input integer w, input [31:0] v, input [27:0] min_seq, input final_sweep);
    integer owner;
    reg [27:0] s;
    begin
      checks = checks + 1;
      owner = w % 4;
      s = v[27:0];
      if (v != 32'd0 && v[31:28] != owner + 1)       error("wrong word", p, w, v);
      else if (v == 32'd0 && min_seq != 0)            error("stale (initial) value", p, w, v);
      else if (owner == p && s != done_seq[w])        error("own store lost", p, w, v);
      else if (final_sweep && s != done_seq[w])       error("final value", p, w, v);
      else if (s < min_seq)                           error("stale value", p, w, v);
      else if (s > issued_seq[w])                     error("value from the future", p, w, v);
      else if (s < seen[p*NWORDS+w])                  error("went backwards", p, w, v);
      else seen[p*NWORDS+w] = s;
    end
  endtask

  initial begin
    if (!$value$plusargs("seed=%d", seed0)) seed0 = 1;
    if (!$value$plusargs("ops=%d", ops)) ops = 2000;
    for (k = 0; k < NWORDS; k = k + 1) begin done_seq[k] = 0; issued_seq[k] = 0; end
    for (k = 0; k < 4 * NWORDS; k = k + 1) seen[k] = 0;
    for (k = 0; k < MAXV; k = k + 1) begin amo_seen[k] = 0; sc_seen[k] = 0; end
    amo_done = 0; sc_ok = 0; sc_fail = 0; errors = 0; checks = 0; port_done = 0;
    #1;
    dut.u_mem.mem[0] = 256'h0000006f;                // every core: j .
  end

  // Bus and memory statistics
  integer n_rd, n_rdx, n_upgr, n_flush, n_hitm, n_l2wb, n_l2rd;
  initial begin n_rd = 0; n_rdx = 0; n_upgr = 0; n_flush = 0; n_hitm = 0; n_l2wb = 0; n_l2rd = 0; end
  genvar g;
  generate for (g = 0; g < 4; g = g + 1) begin : stat
    always @(posedge clk) if (rst_n) begin
      if (dut.core_gen[g].u_l1d.bus_ack)
        case (dut.core_gen[g].u_l1d.bus_cmd)
          `BUS_READ:  n_rd    = n_rd + 1;
          `BUS_READX: n_rdx   = n_rdx + 1;
          `BUS_UPGR:  n_upgr  = n_upgr + 1;
          `BUS_FLUSH: n_flush = n_flush + 1;
          default: ;
        endcase
      if (dut.core_gen[g].u_l1d.snoop_resp == `SNOOP_HITM && dut.core_gen[g].u_l1d.snoop_data_valid)
        n_hitm = n_hitm + 1;
    end
  end endgenerate
  always @(posedge clk) if (rst_n && dut.u_l2.mem_ack) begin
    if (dut.u_l2.mem_wr) n_l2wb = n_l2wb + 1; else n_l2rd = n_l2rd + 1;
  end

  // SWMR invariant, checked every cycle on every line the test uses: the
  // MESI state of each line in each L1D is read from the cache's arrays.
  localparam NL = NLINES + 2;
  function [31:0] line_addr(input integer l);
    line_addr = (l < NLINES) ? word_addr(l * 8) : (l == NLINES ? AMO_CTR : LRSC_CTR);
  endfunction
  reg [1:0] lst [0:4*NL-1];              // state of line l in cache g: lst[g*NL + l]
  integer   swmr_checks, swmr_errors;
  initial begin swmr_checks = 0; swmr_errors = 0; end
  generate for (g = 0; g < 4; g = g + 1) begin : swmr
    integer l;
    reg [31:0] a;
    reg [1:0]  s0, s1;
    always @(negedge clk) if (rst_n) begin
      for (l = 0; l < NL; l = l + 1) begin
        a  = line_addr(l);
        s0 = dut.core_gen[g].u_l1d.state_bits[{1'b0, a[10:5]} * 2 +: 2];
        s1 = dut.core_gen[g].u_l1d.state_bits[{1'b1, a[10:5]} * 2 +: 2];
        if (s0 != `MESI_INVALID && dut.core_gen[g].u_l1d.tag0[a[10:5]] == a[31:11])      lst[g*NL + l] = s0;
        else if (s1 != `MESI_INVALID && dut.core_gen[g].u_l1d.tag1[a[10:5]] == a[31:11]) lst[g*NL + l] = s1;
        else lst[g*NL + l] = `MESI_INVALID;
      end
    end
  end endgenerate
  integer sl, sg, n_valid, n_owner;
  always @(posedge clk) if (rst_n) begin
    for (sl = 0; sl < NL; sl = sl + 1) begin
      n_valid = 0; n_owner = 0;
      for (sg = 0; sg < 4; sg = sg + 1) begin
        if (lst[sg*NL + sl] != `MESI_INVALID) n_valid = n_valid + 1;
        if (lst[sg*NL + sl] == `MESI_MODIFIED || lst[sg*NL + sl] == `MESI_EXCLUSIVE) n_owner = n_owner + 1;
      end
      swmr_checks = swmr_checks + 1;
      if (n_owner > 1 || (n_owner == 1 && n_valid > 1)) begin
        swmr_errors = swmr_errors + 1;
        errors = errors + 1;
        if (swmr_errors <= 10)
          $display("ERROR SWMR: line %h states %0d %0d %0d %0d at cycle %0d", line_addr(sl),
                   lst[sl], lst[NL + sl], lst[2*NL + sl], lst[3*NL + sl], cycles);
      end
    end
  end

  // One random traffic generator per L1D port
  generate for (g = 0; g < 4; g = g + 1) begin : port
    reg        req = 0, wr = 0;
    reg [31:0] addr = 0, wdata = 0, rdata;
    reg [3:0]  amo = 0;
    integer    seed, n, kind, w, i, idle, cyc;
    reg [27:0] s, min_s;
    reg [31:0] v;

    initial begin
      force dut.core_gen[g].u_l1d.cpu_req      = req;
      force dut.core_gen[g].u_l1d.cpu_wr       = wr;
      force dut.core_gen[g].u_l1d.cpu_addr     = addr;
      force dut.core_gen[g].u_l1d.cpu_wdata    = wdata;
      force dut.core_gen[g].u_l1d.cpu_mem_type = `MEM_WORD;
      force dut.core_gen[g].u_l1d.cpu_amo      = amo;
    end

    task access(input [31:0] a, input w_en, input [31:0] d, input [3:0] op);
      begin
        @(negedge clk);
        addr = a; wr = w_en; wdata = d; amo = op; req = 1; cyc = 0;
        @(negedge clk); #1;
        while (!dut.core_gen[g].u_l1d.cpu_ack && cyc < 5000) begin @(negedge clk); #1; cyc = cyc + 1; end
        rdata = dut.core_gen[g].u_l1d.cpu_rdata;
        if (cyc >= 5000) begin
          errors = errors + 1;
          $display("ERROR port %0d: no acknowledge for %h (op %0d)", g, a, op);
          $finish;
        end
        @(posedge clk); #1 req = 0; wr = 0; amo = 0;
      end
    endtask

    initial begin
      seed = 0;
      #2 seed = seed0 * 4 + g + 1;
      @(posedge rst_n);
      repeat (300) @(posedge clk);                // L2 clears its set records
      for (n = 0; n < ops; n = n + 1) begin
        idle = $unsigned($random(seed)) % 4;
        repeat (idle) @(posedge clk);
        kind = $unsigned($random(seed)) % 100;
        if (kind < 45) begin                       // load any word
          w = $unsigned($random(seed)) % NWORDS;
          min_s = done_seq[w];
          access(word_addr(w), 0, 0, `AMO_NONE);
          check_load(g, w, rdata, min_s, 0);
        end else if (kind < 82) begin              // store to an own word
          w = ($unsigned($random(seed)) % (NWORDS / 4)) * 4 + g;
          s = issued_seq[w] + 1;
          issued_seq[w] = s;
          access(word_addr(w), 1, {g[3:0] + 4'd1, s}, `AMO_NONE);
          done_seq[w] = s;
        end else if (kind < 92) begin              // amoadd on the shared counter
          access(AMO_CTR, 0, 1, `AMO_ADD);
          checks = checks + 1;
          if (rdata >= MAXV || amo_seen[rdata]) begin
            errors = errors + 1;
            if (errors <= 10) $display("ERROR amoadd: port %0d got old value %0d twice", g, rdata);
          end else amo_seen[rdata] = 1;
          amo_done = amo_done + 1;
        end else begin                             // LR, maybe one other access, SC
          access(LRSC_CTR, 0, 0, `AMO_LR);
          v = rdata;
          if ($unsigned($random(seed)) % 4 == 0) begin
            w = $unsigned($random(seed)) % NWORDS;
            min_s = done_seq[w];
            access(word_addr(w), 0, 0, `AMO_NONE);
            check_load(g, w, rdata, min_s, 0);
          end
          access(LRSC_CTR, 0, v + 1, `AMO_SC);
          checks = checks + 1;
          if (rdata == 0) begin
            if (v >= MAXV || sc_seen[v]) begin
              errors = errors + 1;
              if (errors <= 10) $display("ERROR sc: port %0d stored %0d+1, already stored by another SC", g, v);
            end else sc_seen[v] = 1;
            sc_ok = sc_ok + 1;
          end else sc_fail = sc_fail + 1;
        end
      end
      port_done[g] = 1'b1;
      wait (port_done == 4'hF);
      // Final sweep: every port reads every word and both counters
      for (i = 0; i < NWORDS; i = i + 1) begin
        access(word_addr(i), 0, 0, `AMO_NONE);
        check_load(g, i, rdata, done_seq[i], 1);
      end
      access(AMO_CTR, 0, 0, `AMO_NONE);
      if (rdata != amo_done) begin errors = errors + 1; $display("ERROR amoadd counter %0d, expected %0d (port %0d)", rdata, amo_done, g); end
      access(LRSC_CTR, 0, 0, `AMO_NONE);
      if (rdata != sc_ok) begin errors = errors + 1; $display("ERROR LR/SC counter %0d, expected %0d (port %0d)", rdata, sc_ok, g); end
      port_done[g] = 1'b0;
    end
  end endgenerate

  initial begin
    cycles = 0;
    #22 rst_n = 1;
    wait (port_done == 4'hF);
    wait (port_done == 4'h0);
    $display("coherence random test: seed %0d, %0d ops per port, %0d cycles", seed0, ops, cycles);
    $display("  checks %0d, amoadd %0d, SC ok %0d / failed %0d; SWMR checks %0d", checks, amo_done, sc_ok, sc_fail, swmr_checks);
    $display("  bus: BusRd %0d, BusRdX %0d, BusUpgr %0d, Flush %0d, HITM data %0d; L2->memory: writebacks %0d, reads %0d",
             n_rd, n_rdx, n_upgr, n_flush, n_hitm, n_l2wb, n_l2rd);
    if (errors == 0) $display("RESULT PASS cycles=%0d", cycles);
    else             $display("RESULT FAIL errors=%0d", errors);
    $finish;
  end
  always @(posedge clk) begin
    cycles <= cycles + 1;
    if (cycles > 20000000) begin $display("RESULT TIMEOUT"); $finish; end
  end
endmodule
