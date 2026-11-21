`timescale 1ns/1ps
// ============================================================================
// tb_mesh_scaling.v - bus vs mesh as the core count grows (model)
// ============================================================================
// The SoC's NoC is a 2x2 mesh, so it cannot show how the two interconnects
// compare with more cores. This testbench is a calibrated model of the
// L1-miss traffic of a K x K system (4, 9 or 16 cores):
//
//   Mesh (BUS=0): three K x K meshes of mesh_router.v, as in the SoC (REQ:
//   core to home, OUT: home to core, RSP: owner to requester). The home of a
//   line is node (line % N): a directory home and an L2 bank at every node.
//   A miss is a 1-flit request to the home; the home is busy HOME_T cycles
//   per request, then sends the line (DFLITS flits) to the requester. In the
//   shared pattern, half the misses find the line owned by another core: the
//   home sends that core a 1-flit probe and the owner sends the line
//   straight to the requester (as the SoC's NoC does).
//
//   Bus (BUS=1): one atomic snooping bus, round-robin; a miss holds the bus
//   for BUS_T cycles, whatever the pattern.
//
// Every core is a blocking L1 (one miss at a time, like the SoC): it waits a
// random 0 .. 2*GAP-1 cycles, misses, waits for the line, and repeats OPS
// times. Printed: misses per 1000 cycles (all cores) and the average miss
// latency, both including L1_T cycles of L1 lookup and fill per miss.
//
// Calibration (against results/2026-11-13/traffic.txt, private pattern, 4
// cores; L1_T is the same for both, because both use the same L1s): L1_T = 2
// and BUS_T = 6 give the bus 10.0 cycles at light load (RTL 9.4) and 166.5
// misses per 1000 cycles at saturation (RTL 171.9); with 256-bit flits
// (DFLITS = 2), HOME_T = 5 gives a 2x2 mesh 14.1 cycles at light load (RTL
// 13.8, noc4_f256). The model leaves out what both interconnects share (L2
// misses to memory, write-backs), and it gives the mesh a banked L2 (one
// bank per home), which a 3x3 or 4x4 SoC would need.
//
// Usage: iverilog -g2012 -DSIM -Ptb_mesh_scaling.K=K ...; vvp tb.vvp +bus=0|1 +pattern=0|1|2 +gap=G [+ops=N] [+home_t=T]
//        [+dflits=D] [+bus_t=T] [+l1_t=T] [+seed=S]
//   pattern 0 private (uniform homes), 1 shared (half the misses forwarded
//   by an owner), 2 hotspot (every miss to the line at node 0)
// ============================================================================
module tb_mesh_scaling;
  parameter integer K = 2;                       // mesh size, set at compile time
  localparam integer NMAX = K * K, FW = 32;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  integer k, n, bus, pattern, gap, ops, home_t, dflits, bus_t, l1_t, seed;
  initial begin
    k = K;
    if (!$value$plusargs("bus=%d", bus)) bus = 0;
    if (!$value$plusargs("pattern=%d", pattern)) pattern = 0;
    if (!$value$plusargs("gap=%d", gap)) gap = 16;
    if (!$value$plusargs("ops=%d", ops)) ops = 400;
    if (!$value$plusargs("home_t=%d", home_t)) home_t = 5;
    if (!$value$plusargs("dflits=%d", dflits)) dflits = 2;
    if (!$value$plusargs("bus_t=%d", bus_t)) bus_t = 6;
    if (!$value$plusargs("l1_t=%d", l1_t)) l1_t = 2;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    n = k * k;
  end

  // flit: [31] tail, [30:23] dst, [22:15] src (requester), [14:13] type
  localparam [1:0] T_REQ = 2'd0, T_DATA = 2'd1, T_PROBE = 2'd2;
  function [FW-1:0] flit(input tail, input [7:0] dst, input [7:0] src, input [1:0] ty);
    flit = {tail, dst, src, ty, 13'd0};
  endfunction

  // Three K x K meshes (compile once per size: iverilog -Ptb_mesh_scaling.K=3)
  wire [NMAX*FW-1:0] q_ej, o_ej, r_ej;
  wire [NMAX-1:0]    q_ejv, o_ejv, r_ejv, q_ir, o_ir, r_ir;
  reg  [NMAX*FW-1:0] q_in, o_in, r_in;
  reg  [NMAX-1:0]    q_iv, o_iv, r_iv;
  mesh_k #(.K(K), .FW(FW)) qm (clk, rst_n, q_in, q_iv, q_ir, q_ej, q_ejv, {NMAX{1'b1}});
  mesh_k #(.K(K), .FW(FW)) om (clk, rst_n, o_in, o_iv, o_ir, o_ej, o_ejv, {NMAX{1'b1}});
  mesh_k #(.K(K), .FW(FW)) rm (clk, rst_n, r_in, r_iv, r_ir, r_ej, r_ejv, {NMAX{1'b1}});

  // ------------------------------------------------------------------
  // Packet sources: per node and network, a queue of packets to inject.
  // A packet is {dst, src, type, length}; its flits go out one per cycle.
  // ------------------------------------------------------------------
  localparam integer QD = 64;
  reg [25:0] pq [0:3*NMAX-1][0:QD-1];          // {dst 8, src 8, type 2, len 8}
  integer    ph [0:3*NMAX-1], pt [0:3*NMAX-1], pf [0:3*NMAX-1];  // head, tail, flits sent of head
  task enq(input integer net, input integer node, input [7:0] dst, input [7:0] src, input [1:0] ty, input [7:0] len);
    integer q;
    begin
      q = net * NMAX + node;
      pq[q][pt[q] % QD] = {dst, src, ty, len};
      pt[q] = pt[q] + 1;
      if (pt[q] - ph[q] > QD) begin $display("ERROR packet queue overflow"); $finish; end
    end
  endtask

  // ------------------------------------------------------------------
  // Core, home and bus state
  // ------------------------------------------------------------------
  integer wait_c [0:NMAX-1];       // think cycles left (-1: waiting for a line)
  integer done_c [0:NMAX-1];       // misses completed
  integer start_t[0:NMAX-1];
  integer hq [0:NMAX-1][0:63];     // home request queue: requester
  integer hh [0:NMAX-1], ht [0:NMAX-1], hbusy [0:NMAX-1];
  integer lat_sum, n_done, cyc, rnd, i, j, q, all_done, bus_left, bus_owner, bus_rr;
  reg     want [0:NMAX-1];         // bus mode: request pending

  function integer urand(input integer m);
    begin rnd = $random(seed); urand = (rnd < 0 ? -rnd : rnd) % m; end
  endfunction

  integer ri, rnet, src, ty;
  reg [FW-1:0] f;
  always @(posedge clk) if (rst_n) begin
    cyc = cyc + 1;
    // ---- ejections (sampled before the edge) ----
    for (ri = 0; ri < n; ri = ri + 1) begin
      if (q_ejv[ri]) begin                               // request at its home
        f = q_ej[ri*FW +: FW];
        hq[ri][ht[ri] % 64] = f[22:15]; ht[ri] = ht[ri] + 1;
      end
      if (o_ejv[ri]) begin                               // data or probe at a core
        f = o_ej[ri*FW +: FW];
        if (f[14:13] == T_PROBE) begin
          if (f[31]) enq(2, ri, f[22:15], f[22:15], T_DATA, dflits);   // owner forwards the line
        end else if (f[31]) finish_miss(ri);
      end
      if (r_ejv[ri]) begin
        f = r_ej[ri*FW +: FW];
        if (f[31]) finish_miss(ri);
      end
    end
    // ---- injections: advance the head packet of each queue ----
    for (ri = 0; ri < 3 * n; ri = ri + 1) begin
      rnet = ri / n; q = rnet * NMAX + ri % n;
      if (ph[q] != pt[q] && inj_taken(rnet, ri % n)) begin
        pf[q] = pf[q] + 1;
        if (pf[q] == pq[q][ph[q] % QD][7:0]) begin ph[q] = ph[q] + 1; pf[q] = 0; end
      end
    end
    // ---- homes: serve one request at a time ----
    if (!bus) for (ri = 0; ri < n; ri = ri + 1) begin
      if (hbusy[ri] > 0) begin
        hbusy[ri] = hbusy[ri] - 1;
        if (hbusy[ri] == 0) begin
          src = hq[ri][hh[ri] % 64]; hh[ri] = hh[ri] + 1;
          if (pattern == 1 && urand(2) == 0) begin
            j = urand(n - 1); if (j >= src) j = j + 1;   // an owner other than the requester
            enq(1, ri, j, src, T_PROBE, 1);
          end else
            enq(1, ri, src, src, T_DATA, dflits);
        end
      end
      if (hbusy[ri] == 0 && hh[ri] != ht[ri]) hbusy[ri] = home_t;
    end
    // ---- bus: one transaction at a time ----
    if (bus) begin
      if (bus_left > 0) begin
        bus_left = bus_left - 1;
        if (bus_left == 0) finish_miss(bus_owner);
      end
      if (bus_left == 0)
        for (j = 1; j <= n && bus_left == 0; j = j + 1) begin
          i = (bus_rr + j) % n;
          if (want[i]) begin want[i] = 0; bus_owner = i; bus_rr = i; bus_left = bus_t; end
        end
    end
    // ---- cores: think, then miss ----
    for (ri = 0; ri < n; ri = ri + 1)
      if (wait_c[ri] > 0) wait_c[ri] = wait_c[ri] - 1;
      else if (wait_c[ri] == 0 && done_c[ri] < ops) begin
        wait_c[ri] = -1; start_t[ri] = cyc;
        if (bus) want[ri] = 1;
        else enq(0, ri, pattern == 2 ? 0 : urand(n), ri, T_REQ, 1);
      end
    drive_inj;
  end

  task finish_miss(input integer c);
    begin
      lat_sum = lat_sum + (cyc - start_t[c]) + l1_t;
      n_done = n_done + 1;
      done_c[c] = done_c[c] + 1;
      wait_c[c] = l1_t + (gap > 0 ? urand(2 * gap) : 0);
    end
  endtask

  // The flit at the head of a queue is taken if it was valid and ready at
  // this edge (inputs are registered below, after the edge)
  function inj_taken(input integer net, input integer node);
    case (net)
      0: inj_taken = q_iv[node] && q_ir[node];
      1: inj_taken = o_iv[node] && o_ir[node];
      default: inj_taken = r_iv[node] && r_ir[node];
    endcase
  endfunction

  task drive_inj;
    integer d, qq, nt;
    reg [25:0] pk;
    begin
      for (d = 0; d < n; d = d + 1)
        for (nt = 0; nt < 3; nt = nt + 1) begin
          qq = nt * NMAX + d;
          pk = pq[qq][ph[qq] % QD];
          f = flit(pf[qq] + 1 == pk[7:0], pk[25:18], pk[17:10], pk[9:8]);
          case (nt)
            0: begin q_in[d*FW +: FW] <= f; q_iv[d] <= (ph[qq] != pt[qq]); end
            1: begin o_in[d*FW +: FW] <= f; o_iv[d] <= (ph[qq] != pt[qq]); end
            default: begin r_in[d*FW +: FW] <= f; r_iv[d] <= (ph[qq] != pt[qq]); end
          endcase
        end
    end
  endtask

  initial begin
    q_in = 0; o_in = 0; r_in = 0; q_iv = 0; o_iv = 0; r_iv = 0;
    lat_sum = 0; n_done = 0; cyc = 0; bus_left = 0; bus_owner = 0; bus_rr = 0;
    for (i = 0; i < NMAX; i = i + 1) begin
      wait_c[i] = 1 + i; done_c[i] = 0; start_t[i] = 0; hh[i] = 0; ht[i] = 0; hbusy[i] = 0; want[i] = 0;
    end
    for (i = 0; i < 3 * NMAX; i = i + 1) begin ph[i] = 0; pt[i] = 0; pf[i] = 0; end
    #22 rst_n = 1;
    all_done = 0;
    while (!all_done) begin
      @(posedge clk); #1;
      all_done = 1;
      for (i = 0; i < n; i = i + 1) if (done_c[i] < ops) all_done = 0;
      if (cyc > 5000000) begin $display("RESULT TIMEOUT"); $finish; end
    end
    $display("SCALING k=%0d cores=%0d %0s pattern=%0d gap=%0d: %0d.%0d misses/kcycle, latency %0d.%0d cycles",
             k, n, bus ? "bus" : "mesh", pattern, gap,
             n_done * 1000 / cyc, (n_done * 10000 / cyc) % 10,
             lat_sum / n_done, (lat_sum * 10 / n_done) % 10);
    $finish;
  end
endmodule
