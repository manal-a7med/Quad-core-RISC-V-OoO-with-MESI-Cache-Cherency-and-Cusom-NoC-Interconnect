// ============================================================================
// coh_cov.vh - functional coverage of the coherence protocol
// ============================================================================
// Included by tb_coh_random.v (inside the module, after `genvar g`). Each
// bin counts one kind of event in the four L1 data caches, the L2 and (in
// the NoC build) the network interfaces and directory homes. Events are
// sampled from the design's own signals every clock edge, so they count what
// really happened, not what the test meant to do.
//
// At the end the test prints one "COV <bin> <count> <name>" line per bin and
// a summary. scripts/coverage_report.py merges the lines of several runs
// (seeds, bus and NoC builds) into one report (make coverage). Every legal
// bin must be hit; an illegal bin counts an event that must never happen.
// ============================================================================
localparam integer CB_L1    = 37;              // L1 and L2 bins, both builds
localparam integer CB_NOC   = 5;               // NoC-only bins
localparam integer CB_BAD   = 2;               // illegal bins
localparam integer CB_TOTAL = CB_L1 + CB_NOC + CB_BAD;
integer cov [0:CB_TOTAL-1];
integer ci;
initial for (ci = 0; ci < CB_TOTAL; ci = ci + 1) cov[ci] = 0;

function [8*44-1:0] cov_name(input integer b);
  case (b)
    0:  cov_name = "fill E (BusRd, no other copy)";
    1:  cov_name = "fill S (BusRd, other copies)";
    2:  cov_name = "fill M (BusRdX)";
    3:  cov_name = "upgrade S to M (BusUpgr)";
    4:  cov_name = "upgrade lost the line, refetch (BusRdX)";
    5:  cov_name = "store hit E (silent E to M)";
    6:  cov_name = "store hit M";
    7:  cov_name = "load hit S";
    8:  cov_name = "load hit E";
    9:  cov_name = "load hit M";
    10: cov_name = "evict M (write back)";
    11: cov_name = "evict E (silent)";
    12: cov_name = "evict S (silent)";
    13: cov_name = "snoop BusRd hit M (supply, M to S)";
    14: cov_name = "snoop BusRd hit E (E to S)";
    15: cov_name = "snoop BusRd hit S";
    16: cov_name = "snoop BusRd miss";
    17: cov_name = "snoop BusRdX hit M (supply, M to I)";
    18: cov_name = "snoop BusRdX hit E (E to I)";
    19: cov_name = "snoop BusRdX hit S (S to I)";
    20: cov_name = "snoop BusRdX miss";
    21: cov_name = "snoop BusUpgr hit S (S to I)";
    22: cov_name = "snoop BusUpgr miss";
    23: cov_name = "snoop in the cycle of a CPU lookup";
    24: cov_name = "snoop to the line of a pending miss";
    25: cov_name = "LR sets a reservation";
    26: cov_name = "SC succeeds";
    27: cov_name = "SC fails (no reservation)";
    28: cov_name = "reservation lost to a snoop";
    29: cov_name = "reservation lost to another fill";
    30: cov_name = "AMO hit M";
    31: cov_name = "AMO hit E";
    32: cov_name = "AMO on S (upgrade first)";
    33: cov_name = "AMO miss";
    34: cov_name = "L2 writes a dirty line to memory";
    35: cov_name = "L2 reads a line from memory";
    36: cov_name = "snoop takes the victim before write-back";
    37: cov_name = "NoC: owner sends line to requester";
    38: cov_name = "NoC: probe held until the line arrives";
    39: cov_name = "NoC: a home works on 2+ lines at once";
    40: cov_name = "NoC: replaced line kept as a victim";
    41: cov_name = "NoC: PutM write-back accepted";
    42: cov_name = "ILLEGAL snoop BusUpgr hit M or E";
    43: cov_name = "ILLEGAL two caches fill M at once";
    default: cov_name = "?";
  endcase
endfunction

generate for (g = 0; g < 4; g = g + 1) begin : cv
  // Short names for the L1D's signals (sampled before the clock edge)
  wire [2:0]  st    = dut.core_gen[g].u_l1d.state;
  wire        snv   = dut.core_gen[g].u_l1d.snoop_valid;
  wire        snew  = dut.core_gen[g].u_l1d.snoop_new;
  wire        shit  = dut.core_gen[g].u_l1d.snoop_hit;
  wire [1:0]  sst   = dut.core_gen[g].u_l1d.snoop_st;
  wire [2:0]  scmd  = dut.core_gen[g].u_l1d.snoop_cmd;
  wire [31:0] sadr  = dut.core_gen[g].u_l1d.snoop_addr;
  wire [31:0] radr  = dut.core_gen[g].u_l1d.req_addr_r;
  wire        hit   = dut.core_gen[g].u_l1d.cache_hit;
  wire [1:0]  hst   = dut.core_gen[g].u_l1d.hit_state;
  wire [1:0]  pst   = dut.core_gen[g].u_l1d.pend_state;
  wire        wr    = dut.core_gen[g].u_l1d.wr_eff;
  wire        rmw   = dut.core_gen[g].u_l1d.is_rmw;
  wire        lr    = dut.core_gen[g].u_l1d.is_lr;
  wire        sc    = dut.core_gen[g].u_l1d.is_sc;
  wire        scf   = dut.core_gen[g].u_l1d.sc_fail;
  wire        sok   = dut.core_gen[g].u_l1d.store_hit_ok;
  wire        back  = dut.core_gen[g].u_l1d.bus_ack;
  wire        shrd  = dut.core_gen[g].u_l1d.bus_shared;
  wire        rv    = dut.core_gen[g].u_l1d.resv_valid;
  wire [26:0] rln   = dut.core_gen[g].u_l1d.resv_line;
  wire        sstwe = dut.core_gen[g].u_l1d.s_st_we;
  wire [1:0]  sstv  = dut.core_gen[g].u_l1d.s_st_val;
  // State encodings of l1_dcache.v
  localparam [2:0] IDLE = 3'd0, COMPARE = 3'd1, WB_READ = 3'd2, WRITEBACK = 3'd3,
                   WB_PAUSE = 3'd4, ALLOCATE = 3'd5, UPGRADE = 3'd6;
  wire lookup = (st == COMPARE) && !snv && !scf;     // the cycle a request is decided
  reg  wbx_r = 1'b0;
  always @(posedge clk) if (rst_n) begin
    if (st == ALLOCATE && back) begin
      if (wr)        cov[2] = cov[2] + 1;
      else if (shrd) cov[1] = cov[1] + 1;
      else           cov[0] = cov[0] + 1;
      if (pst == `MESI_EXCLUSIVE) cov[11] = cov[11] + 1;
      if (pst == `MESI_SHARED)    cov[12] = cov[12] + 1;
    end
    if (st == UPGRADE && back) begin
      if (pst == `MESI_SHARED) cov[3] = cov[3] + 1;
      else                     cov[4] = cov[4] + 1;
    end
    if (st == WRITEBACK && back) cov[10] = cov[10] + 1;
    if (st == WRITEBACK && pst != `MESI_MODIFIED && !wbx_r) cov[36] = cov[36] + 1;
    wbx_r <= (st == WRITEBACK && pst != `MESI_MODIFIED);
    if (lookup && sok && hst == `MESI_EXCLUSIVE && !rmw) cov[5] = cov[5] + 1;
    if (lookup && sok && hst == `MESI_MODIFIED  && !rmw) cov[6] = cov[6] + 1;
    if (lookup && hit && !wr) case (hst)
      `MESI_SHARED:    cov[7] = cov[7] + 1;
      `MESI_EXCLUSIVE: cov[8] = cov[8] + 1;
      `MESI_MODIFIED:  cov[9] = cov[9] + 1;
      default: ;
    endcase
    if (snew) begin
      case (scmd)
        `BUS_READ:  if (!shit) cov[16] = cov[16] + 1;
                    else case (sst)
                      `MESI_MODIFIED:  cov[13] = cov[13] + 1;
                      `MESI_EXCLUSIVE: cov[14] = cov[14] + 1;
                      default:         cov[15] = cov[15] + 1;
                    endcase
        `BUS_READX: if (!shit) cov[20] = cov[20] + 1;
                    else case (sst)
                      `MESI_MODIFIED:  cov[17] = cov[17] + 1;
                      `MESI_EXCLUSIVE: cov[18] = cov[18] + 1;
                      default:         cov[19] = cov[19] + 1;
                    endcase
        `BUS_UPGR:  if (!shit) cov[22] = cov[22] + 1;
                    else if (sst == `MESI_SHARED) cov[21] = cov[21] + 1;
                    else cov[42] = cov[42] + 1;
        default: ;
      endcase
      if ((st == ALLOCATE || st == UPGRADE || st == WRITEBACK || st == WB_READ || st == WB_PAUSE) &&
          sadr[31:5] == radr[31:5])
        cov[24] = cov[24] + 1;
    end
    if (st == COMPARE && snv) cov[23] = cov[23] + 1;
    if (lookup && lr && hit) cov[25] = cov[25] + 1;
    if (lookup && sc && sok) cov[26] = cov[26] + 1;
    if (st == COMPARE && !snv && scf) cov[27] = cov[27] + 1;
    if (rv && sstwe && sstv == `MESI_INVALID && sadr[31:5] == rln) cov[28] = cov[28] + 1;
    if (rv && st == ALLOCATE && back && radr[31:5] != rln) cov[29] = cov[29] + 1;
    if (lookup && rmw && !sc) begin
      if (sok && hst == `MESI_MODIFIED)       cov[30] = cov[30] + 1;
      else if (sok && hst == `MESI_EXCLUSIVE) cov[31] = cov[31] + 1;
      else if (hit)                           cov[32] = cov[32] + 1;
      else                                    cov[33] = cov[33] + 1;
    end
  end
end endgenerate

always @(posedge clk) if (rst_n && dut.u_l2.mem_ack) begin
  if (dut.u_l2.mem_wr) cov[34] = cov[34] + 1; else cov[35] = cov[35] + 1;
end

// Two caches finishing a BusRdX fill of the same line in one cycle
integer cg1, cg2;
always @(posedge clk) if (rst_n)
  for (cg1 = 0; cg1 < 4; cg1 = cg1 + 1)
    for (cg2 = cg1 + 1; cg2 < 4; cg2 = cg2 + 1)
      if (fillm(cg1) && fillm(cg2) && fline(cg1) == fline(cg2)) cov[43] = cov[43] + 1;
function fillm(input integer c);
  case (c)
    0: fillm = dut.core_gen[0].u_l1d.state == 3'd5 && dut.core_gen[0].u_l1d.bus_ack && dut.core_gen[0].u_l1d.wr_eff;
    1: fillm = dut.core_gen[1].u_l1d.state == 3'd5 && dut.core_gen[1].u_l1d.bus_ack && dut.core_gen[1].u_l1d.wr_eff;
    2: fillm = dut.core_gen[2].u_l1d.state == 3'd5 && dut.core_gen[2].u_l1d.bus_ack && dut.core_gen[2].u_l1d.wr_eff;
    default: fillm = dut.core_gen[3].u_l1d.state == 3'd5 && dut.core_gen[3].u_l1d.bus_ack && dut.core_gen[3].u_l1d.wr_eff;
  endcase
endfunction
function [26:0] fline(input integer c);
  case (c)
    0: fline = dut.core_gen[0].u_l1d.req_addr_r[31:5];
    1: fline = dut.core_gen[1].u_l1d.req_addr_r[31:5];
    2: fline = dut.core_gen[2].u_l1d.req_addr_r[31:5];
    default: fline = dut.core_gen[3].u_l1d.req_addr_r[31:5];
  endcase
endfunction

`ifdef NOC
// Network interfaces: a forwarded line (P_DATA) and a probe held back
generate for (g = 0; g < 4; g = g + 1) begin : cvni
  reg pd_r = 1'b0, df_r = 1'b0;
  wire pd = dut.u_ic.tile[g].u_ni.pstate == 2'd3;
  wire df = dut.u_ic.tile[g].u_ni.defer && dut.u_ic.tile[g].u_ni.op_valid &&
            !dut.u_ic.tile[g].u_ni.is_grant;
  always @(posedge clk) if (rst_n) begin
    if (pd && !pd_r) cov[37] = cov[37] + 1;
    if (df && !df_r) cov[38] = cov[38] + 1;
    pd_r <= pd; df_r <= df;
  end
end endgenerate
// Directory homes: several lines at once, victims, PutM
generate for (g = 0; g < `NOC_BANKS; g = g + 1) begin : cvhome
  reg two_r = 1'b0;
  wire [3:0] eb = dut.u_ic.tile[g].home.u_home.e_busy;
  wire two = (eb[0] + eb[1] + eb[2] + eb[3]) >= 2;
  always @(posedge clk) if (rst_n) begin
    if (two && !two_r) cov[39] = cov[39] + 1;
    if (dut.u_ic.tile[g].home.u_home.vic_new && !dut.u_ic.tile[g].home.u_home.vic_put) cov[40] = cov[40] + 1;
    if (dut.u_ic.tile[g].home.u_home.vic_put) cov[41] = cov[41] + 1;
    two_r <= two;
  end
end endgenerate
`endif

// Bins that apply to this build. The NoC build has no BusRd probe to a
// sharer (the directory knows the line is clean), so bin 15 cannot happen.
function cov_applies(input integer b);
`ifdef NOC
  cov_applies = (b != 15);
`else
  cov_applies = (b < CB_L1 || b >= CB_L1 + CB_NOC);
`endif
endfunction

// Print one line per bin that applies to this build, then the summary.
// An illegal event also fails the test.
task cov_report;
  integer b, hit_l, n_l, bad;
  begin
    hit_l = 0; n_l = 0; bad = 0;
    for (b = 0; b < CB_TOTAL; b = b + 1) begin
      if (cov_applies(b)) begin
        $display("COV %0d %0d %0s", b, cov[b], cov_name(b));
        if (b < CB_L1 + CB_NOC) begin
          n_l = n_l + 1;
          if (cov[b] > 0) hit_l = hit_l + 1;
        end else if (cov[b] > 0) bad = bad + 1;
      end
    end
    $display("coverage: %0d of %0d bins hit, %0d illegal events", hit_l, n_l, bad);
    if (bad) errors = errors + 1;
  end
endtask
