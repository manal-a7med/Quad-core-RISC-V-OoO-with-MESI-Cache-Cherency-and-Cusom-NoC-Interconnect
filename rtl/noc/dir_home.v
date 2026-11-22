`timescale 1ns / 1ps
// ============================================================================
// dir_home.v - directory home node for the NoC build (MESI, several lines
//              at once)
// ============================================================================
// The home is where every request for a line is ordered. Instead of
// broadcasting each request to all caches (the bus), it keeps a directory of
// which L1 holds which line, and sends probes only to those caches.
//
// Directory = duplicate L1 tags. For every core and every L1D entry
// (64 sets x 2 ways) the home keeps a copy of the tag and a state:
// I (not held), S (shared copy) or EM (only copy, clean E or dirty M; the
// L1 may turn E into M without telling anyone). A request carries the L1
// way it fills, so the copy is exact: there is no separate directory
// replacement and no need for an inclusive L2. (An inclusive L2 would have
// to hold everything the four L1Ds hold, 16 KB, which is the whole L2.)
// Size: 4 cores x 128 entries x 23 bits, about 12 kbit of LUT RAM.
//
// With NBANKS = 4 each node has a home for a quarter of the lines (line
// address bits [6:5] = node); each keeps duplicate tags only for its lines.
// The probe responses, not the directory, decide where data comes from, so
// a directory entry that is out of date (the L1 dropped a clean line) only
// costs an unneeded probe.
//
// Several lines at once. A core has at most one request outstanding, so the
// home has one request slot and one transaction engine per core. Engine k
// serves core k's requests. Engines on different lines run at the same
// time; a request for a line that another engine is working on waits until
// that engine is done (one transaction per line, so the line's directory
// entries and its L2 copy change in request order). The engines share the
// directory, the OUT sender and the L2 port; each is given round-robin.
// The directory is looked up when an engine starts (who to probe) and again
// when it grants (what to write), so a grant of another line in the same
// set in between is seen.
//
//   request         probes sent to              data from                  grant
//   GetS (BusRd)    the owner (EM), if any:     the owner, sent straight   S (owner keeps a copy)
//                   it sends the line straight  to the requester (or the
//                   to the requester            L2 if it had none)
//   GetS, no owner  -                           L2                         S if a sharer, else E
//   GetS (I-fetch)  the owner, incl. the        owner's answer (also       line only
//                   requester's own L1D         written to L2) or L2
//   GetM (BusRdX)   the owner, forwarding as    the owner, or L2           M
//                   above, or every sharer
//   Upgrade         all other holders (inval.)  none                       ack
//     (the requester no longer has the line: handled as GetM)
//   PutM (BusFlush) none                        written to L2 if the       ack
//                                               sender still owns it
//
// Engine states:
//   E_IDLE  free
//   E_PROBE sending probes
//   E_WAIT  waiting for probe answers and/or L2 data; grants when ready
//           (a forwarded request is granted at once and then waits here
//           for the owner's answer)
//   E_FDATA forwarded request whose owner had no copy: line from the L2
//   E_WB    after the grant: write the line to the L2
// ============================================================================

`include "mesi_defines.vh"
`include "noc_defs.vh"

module dir_home #(
    parameter [1:0] NODE   = 2'd0,
    parameter       NBANKS = 1
) (
    input  wire               clk,
    input  wire               rst_n,

    // REQ network (eject)
    input  wire [`LINK_W-1:0] req_flit,
    input  wire               req_valid,
    output wire               req_ready,
    // RSP network (eject)
    input  wire [`LINK_W-1:0] rsp_flit,
    input  wire               rsp_valid,
    output wire               rsp_ready,
    // OUT network (inject)
    output wire [`LINK_W-1:0] out_flit,
    output wire               out_valid,
    input  wire               out_ready,

    // L2 port (same as the snoop controller's)
    output wire               l2_req_valid,
    output wire [31:0]        l2_req_addr,
    output wire [2:0]         l2_req_cmd,
    output wire [255:0]       l2_req_wdata,
    input  wire [255:0]       l2_resp_data,
    input  wire               l2_resp_valid
);

    localparam [1:0] D_I = 2'd0, D_S = 2'd1, D_EM = 2'd2;
    localparam [2:0] E_IDLE = 3'd0, E_PROBE = 3'd1, E_WAIT = 3'd2, E_FDATA = 3'd3, E_WB = 3'd4;

    // ------------------------------------------------------------------
    // Packets in: requests into one slot per core; probe answers
    // ------------------------------------------------------------------
    wire         rq_valid;
    wire [63:0]  rq_hdr;
    wire [255:0] rq_data;
    noc_rx u_req_rx (
        .clk(clk), .rst_n(rst_n), .flit(req_flit), .valid(req_valid), .ready(req_ready),
        .pkt_valid(rq_valid), .pkt_hdr(rq_hdr), .pkt_data(rq_data), .pkt_pop(rq_valid)
    );                                          // a core's slot is always free: taken at once

    wire         rs_valid;
    wire [63:0]  rs_hdr;
    wire [255:0] rs_data;
    noc_rx u_rsp_rx (
        .clk(clk), .rst_n(rst_n), .flit(rsp_flit), .valid(rsp_valid), .ready(rsp_ready),
        .pkt_valid(rs_valid), .pkt_hdr(rs_hdr), .pkt_data(rs_data), .pkt_pop(rs_valid)
    );                                          // answers are always taken at once

    reg  [3:0]   sl_v;                          // slot k holds a request from core k
    reg  [63:0]  sl_hdr  [0:3];
    reg  [255:0] sl_data [0:3];

    // ------------------------------------------------------------------
    // Duplicate tags: entry e = {core, way}, 8 LUT RAMs of 64 x {state, tag}
    // Read port A: the engine that starts; port B: the engine that grants.
    // ------------------------------------------------------------------
    reg  [5:0]  init_idx;
    reg         init;
    reg  [5:0]  a_idx, b_idx;
    wire [22:0] da [0:7];
    wire [22:0] db [0:7];
    reg  [7:0]  dt_we;
    reg  [22:0] dt_wv [0:7];

    genvar ge;
    generate for (ge = 0; ge < 8; ge = ge + 1) begin : dtag
        reg [22:0] ram [0:63];
        assign da[ge] = ram[a_idx];
        assign db[ge] = ram[b_idx];
        always @(posedge clk)
            if (init)            ram[init_idx] <= 23'd0;
            else if (dt_we[ge])  ram[b_idx]    <= dt_wv[ge];
    end endgenerate

    // Victims. A grant that fills core j's (set, way) overwrites the entry of
    // the line j had there, but j keeps that line until the fill arrives.
    // The same for a PutM: j drops the line it wrote back only at its next fill.
    // So the old entry is kept as core j's victim until j's next request
    // reaches this home (j sends it only after the fill): until then it
    // counts as a copy, and a probe for it goes to j.
    reg  [1:0]  vic_st [0:3];
    reg  [26:0] vic_ln [0:3];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            init <= 1'b1; init_idx <= 6'd0;
        end else if (init) begin
            init_idx <= init_idx + 6'd1;
            if (init_idx == 6'd63) init <= 1'b0;
        end

    // ------------------------------------------------------------------
    // Engines: what the shared logic sees of each
    // ------------------------------------------------------------------
    wire [2:0]   e_state [0:3];
    wire [26:0]  e_line  [0:3];               // line address [31:5]
    wire [3:0]   e_busy;
    wire [3:0]   e_want;                       // wants to send a packet on OUT
    wire [63:0]  e_hdr   [0:3];
    wire [255:0] e_data  [0:3];
    wire [3:0]   e_grant;                      // ... and it is a grant
    wire [3:0]   e_gets, e_getm, e_upg, e_putok, e_fwd, e_ifetch, e_way;
    wire [3:0]   e_probed [0:3];
    wire [3:0]   e_kept   [0:3];
    wire [3:0]   e_l2v;
    wire [2:0]   e_l2cmd [0:3];
    wire [26:0]  e_l2line [0:3];
    wire [255:0] e_l2wd  [0:3];

    // ------------------------------------------------------------------
    // Start: one engine per cycle, round-robin, when its slot has a request
    // and no other engine is working on that line
    // ------------------------------------------------------------------
    reg  [3:0] can_start;
    reg  [1:0] st_rr, st_k;
    reg        st_v;
    integer si, sj;
    always @(*) begin
        for (si = 0; si < 4; si = si + 1) begin
            can_start[si] = sl_v[si] && !e_busy[si] && !init;
            for (sj = 0; sj < 4; sj = sj + 1)
                if (sj != si && e_busy[sj] && e_line[sj] == sl_hdr[si][`HDR_ADDR]) can_start[si] = 1'b0;
        end
        st_v = 1'b0; st_k = 2'd0;
        for (si = 3; si >= 0; si = si - 1)
            if (can_start[(st_rr + 1 + si) % 4]) begin
                st_v = 1'b1; st_k = (st_rr + 1 + si) % 4;
            end
    end

    // Lookup of the starting request (port A)
    wire [63:0] s_hdr    = sl_hdr[st_k];
    wire [2:0]  s_cmd    = s_hdr[`HDR_TYPE];
    wire [1:0]  s_core   = st_k;
    wire        s_way    = s_hdr[`HDR_WAY];
    wire        s_ifetch = s_hdr[`HDR_IFETCH];
    wire [26:0] s_line   = s_hdr[`HDR_ADDR];
    wire [20:0] s_tag    = s_line[26:6];
    always @(*) a_idx = s_line[5:0];

    wire [7:0] sm, sm_em;
    generate for (ge = 0; ge < 8; ge = ge + 1) begin : smatch
        assign sm[ge]    = (da[ge][22:21] != D_I) && (da[ge][20:0] == s_tag);
        assign sm_em[ge] = sm[ge] && (da[ge][22:21] == D_EM);
    end endgenerate
    wire [3:0] sv, sv_em;                                   // victims that are this line
    generate for (ge = 0; ge < 4; ge = ge + 1) begin : svmatch
        assign sv[ge]    = (vic_st[ge] != D_I) && (vic_ln[ge] == s_line);
        assign sv_em[ge] = sv[ge] && (vic_st[ge] == D_EM);
    end endgenerate
    wire [3:0] s_hold  = {sm[7] | sm[6], sm[5] | sm[4], sm[3] | sm[2], sm[1] | sm[0]} | sv;
    wire [3:0] s_owner = {sm_em[7] | sm_em[6], sm_em[5] | sm_em[4], sm_em[3] | sm_em[2], sm_em[1] | sm_em[0]} | sv_em;
    wire [2:0] s_ent   = {s_core, s_way};
    wire [3:0] s_self  = s_ifetch ? 4'b0000 : (4'b0001 << s_core);
    wire [3:0] s_oth   = s_hold & ~s_self;

    wire s_putm  = (s_cmd == `BUS_FLUSH);
    wire s_upg   = (s_cmd == `BUS_UPGR) && sm[s_ent];          // requester still has it
    wire s_getm  = (s_cmd == `BUS_READX) || ((s_cmd == `BUS_UPGR) && !sm[s_ent]);
    wire s_gets  = (s_cmd == `BUS_READ);                      // includes I-fetch
    wire s_putok = s_putm && sm_em[s_ent];                    // sender still owns the line
    wire s_own   = |(s_oth & s_owner);                        // another cache owns it (EM)
    wire s_fwd   = (s_gets || s_getm) && !s_ifetch && s_own;  // the owner sends the line
    wire [3:0] s_probe = s_gets ? (s_oth & s_owner) : (s_getm || s_upg) ? s_oth : 4'b0000;

    // ------------------------------------------------------------------
    // OUT sender: one packet at a time, engines round-robin
    // ------------------------------------------------------------------
    wire        tx_idle;
    reg  [1:0]  tx_rr, tx_k;
    reg         tx_v;
    integer ti;
    always @(*) begin
        tx_v = 1'b0; tx_k = 2'd0;
        for (ti = 3; ti >= 0; ti = ti - 1)
            if (e_want[(tx_rr + 1 + ti) % 4]) begin
                tx_v = 1'b1; tx_k = (tx_rr + 1 + ti) % 4;
            end
    end
    wire       tx_send = tx_v && tx_idle;
    wire [3:0] e_sent  = tx_send ? (4'b0001 << tx_k) : 4'b0000;     // engine's packet went out
    wire       g_now   = tx_send && e_grant[tx_k];                  // a grant goes out

    // Lookup of the granting engine's line (port B), for the grant and the directory update
    wire [26:0] g_line = e_line[tx_k];
    wire [20:0] g_tag  = g_line[26:6];
    always @(*) b_idx = init ? init_idx : g_line[5:0];
    wire [7:0] gm;
    generate for (ge = 0; ge < 8; ge = ge + 1) begin : gmatch
        assign gm[ge] = (db[ge][22:21] != D_I) && (db[ge][20:0] == g_tag);
    end endgenerate
    wire [3:0] gv;
    generate for (ge = 0; ge < 4; ge = ge + 1) begin : gvmatch
        assign gv[ge] = (vic_st[ge] != D_I) && (vic_ln[ge] == g_line);
    end endgenerate
    wire [3:0] g_hold   = {gm[7] | gm[6], gm[5] | gm[4], gm[3] | gm[2], gm[1] | gm[0]} | gv;
    wire [1:0] g_core   = tx_k;
    wire [2:0] g_ent    = {g_core, e_way[tx_k]};
    wire [3:0] g_self   = e_ifetch[tx_k] ? 4'b0000 : (4'b0001 << g_core);
    wire [3:0] g_probed = e_probed[tx_k];
    wire [3:0] g_kept   = e_kept[tx_k];
    // GetS: another copy stays if a probed owner kept one, or a sharer was not probed.
    // A forwarded GetS is granted before the owner answers: the owner keeps a copy.
    wire g_shared = e_fwd[tx_k] || |g_kept || |(g_hold & ~g_self & ~g_probed);

    reg [63:0] tx_hdr;
    always @(*) begin
        tx_hdr = e_hdr[tx_k];
        if (e_grant[tx_k] && e_gets[tx_k]) tx_hdr[`HDR_SHARED] = g_shared;
    end
    noc_tx u_out_tx (
        .clk(clk), .rst_n(rst_n), .send(tx_send), .hdr(tx_hdr), .data(e_data[tx_k]), .idle(tx_idle),
        .flit(out_flit), .valid(out_valid), .ready(out_ready)
    );

    // Victims: updated like directory entries at a grant of their line; a
    // new victim when a fill replaces another line; dropped when the core's
    // next request arrives (its fill is done)
    reg  [1:0] vic_nx [0:3];
    // (a PutM's line too: the L1 drops it only when its next fill arrives)
    wire       vic_put = g_now && e_putok[tx_k];
    wire       vic_new = vic_put || (g_now && !e_ifetch[tx_k] && (e_gets[tx_k] || e_getm[tx_k]) &&
                                     db[g_ent][22:21] != D_I && db[g_ent][20:0] != g_tag);
    integer vi;
    always @(*)
        for (vi = 0; vi < 4; vi = vi + 1) begin
            vic_nx[vi] = vic_st[vi];
            if (g_now && gv[vi]) begin
                if (e_gets[tx_k] && g_probed[vi])
                    vic_nx[vi] = (g_kept[vi] || e_fwd[tx_k]) ? D_S : D_I;
                if ((e_getm[tx_k] || e_upg[tx_k]) && g_probed[vi]) vic_nx[vi] = D_I;
                if (vi == g_core && !e_ifetch[tx_k])              vic_nx[vi] = D_I;
            end
            if (vic_new && vi == g_core) vic_nx[vi] = vic_put ? D_EM : db[g_ent][22:21];
            if (rq_valid && rq_hdr[`HDR_SRC] == vi) vic_nx[vi] = D_I;
        end

    // Directory update, written when a grant is sent
    integer e;
    always @(*) begin
        dt_we = 8'd0;
        for (e = 0; e < 8; e = e + 1) begin
            dt_wv[e] = db[e];
            if (gm[e]) begin
                if (e_gets[tx_k] && g_probed[e/2]) begin
                    dt_we[e] = 1'b1;
                    dt_wv[e] = (g_kept[e/2] || e_fwd[tx_k]) ? {D_S, g_tag} : 23'd0;
                end
                if ((e_getm[tx_k] || e_upg[tx_k]) && g_probed[e/2]) begin
                    dt_we[e] = 1'b1;
                    dt_wv[e] = 23'd0;
                end
                if (e/2 == g_core && !e_ifetch[tx_k] && e != g_ent) begin   // stale second copy
                    dt_we[e] = 1'b1;
                    dt_wv[e] = 23'd0;
                end
            end
            if (e == g_ent && !e_ifetch[tx_k]) begin
                if (e_putok[tx_k]) begin
                    dt_we[e] = 1'b1; dt_wv[e] = 23'd0;
                end else if (e_gets[tx_k]) begin
                    dt_we[e] = 1'b1; dt_wv[e] = {g_shared ? D_S : D_EM, g_tag};
                end else if (e_getm[tx_k] || e_upg[tx_k]) begin
                    dt_we[e] = 1'b1; dt_wv[e] = {D_EM, g_tag};
                end
            end
        end
        if (!g_now || init) dt_we = 8'd0;
    end

    // ------------------------------------------------------------------
    // L2 port: engines round-robin; an engine keeps its request up until
    // the L2 answers
    // ------------------------------------------------------------------
    reg        l2_busy;
    reg  [1:0] l2_sel, l2_last, l2_pick;
    integer li;
    always @(*) begin
        l2_pick = l2_last;
        for (li = 3; li >= 1; li = li - 1)
            if (e_l2v[(l2_last + li) % 4]) l2_pick = (l2_last + li) % 4;
    end
    wire [1:0] l2_cur = l2_busy ? l2_sel : l2_pick;
    assign l2_req_valid = l2_busy ? e_l2v[l2_sel] : |e_l2v;
    assign l2_req_addr  = {e_l2line[l2_cur], 5'b0};
    assign l2_req_cmd   = e_l2cmd[l2_cur];
    assign l2_req_wdata = e_l2wd[l2_cur];
    wire [3:0] e_l2r = (l2_resp_valid && l2_busy) ? (4'b0001 << l2_sel) : 4'b0000;

    // Probe answers go to the engine working on that line
    reg [3:0] e_rs;
    integer ri;
    always @(*)
        for (ri = 0; ri < 4; ri = ri + 1)
            e_rs[ri] = rs_valid && e_busy[ri] && (e_line[ri] == rs_hdr[`HDR_ADDR]);

    integer ri2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sl_v    <= 4'd0;
            st_rr   <= 2'd3;
            tx_rr   <= 2'd3;
            l2_busy <= 1'b0; l2_sel <= 2'd0; l2_last <= 2'd3;
            for (ri2 = 0; ri2 < 4; ri2 = ri2 + 1) begin
                sl_hdr[ri2] <= 64'd0; sl_data[ri2] <= 256'd0; vic_st[ri2] <= D_I; vic_ln[ri2] <= 27'd0;
            end
        end else begin
            if (st_v) begin
                sl_v[st_k] <= 1'b0;
                st_rr      <= st_k;
            end
            for (ri2 = 0; ri2 < 4; ri2 = ri2 + 1) vic_st[ri2] <= vic_nx[ri2];
            if (vic_new) vic_ln[g_core] <= vic_put ? g_line : {db[g_ent][20:0], g_line[5:0]};
            if (rq_valid) begin
                sl_v[rq_hdr[`HDR_SRC]]    <= 1'b1;
                sl_hdr[rq_hdr[`HDR_SRC]]  <= rq_hdr;
                sl_data[rq_hdr[`HDR_SRC]] <= rq_data;
            end
            if (tx_send) tx_rr <= tx_k;
            if (!l2_busy) begin
                if (|e_l2v) begin l2_busy <= 1'b1; l2_sel <= l2_pick; l2_last <= l2_pick; end
            end else if (l2_resp_valid) begin
                l2_busy <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // The engines
    // ------------------------------------------------------------------
    genvar k;
    generate for (k = 0; k < 4; k = k + 1) begin : eng
        reg  [2:0]   state;
        reg  [26:0]  line_a;                    // line address
        reg          way, ifetch, gets, getm, upg, putm, putok, fwd;
        reg  [3:0]   to_probe;                  // probes still to send
        reg  [3:0]   probed;                    // probes sent
        reg  [3:0]   answered;                  // probe answers received
        reg  [7:0]   presp;                     // answer per core (`SNOOP_*)
        reg          dirty;                     // a probe returned a dirty line (in `line`)
        reg  [255:0] line;
        reg          granted;                   // forwarded: grant sent
        reg          fsent;                     // forwarded: the owner sent the line
        reg          l2_act, l2_wr, l2_have;    // L2 request in flight / is a write / data in `line`
        reg  [2:0]   l2_cmd;

        wire start = st_v && (st_k == k);
        wire sent  = e_sent[k];
        wire l2r   = e_l2r[k];
        wire rsk   = e_rs[k];

        wire [1:0] next_probe = to_probe[0] ? 2'd0 : to_probe[1] ? 2'd1 : to_probe[2] ? 2'd2 : 2'd3;
        wire       all_ans    = (answered == probed) && !rsk;
        reg  [3:0] kept;
        integer c;
        always @(*)
            for (c = 0; c < 4; c = c + 1)
                kept[c] = probed[c] && (presp[2*c +: 2] == `SNOOP_HIT || presp[2*c +: 2] == `SNOOP_HITM);

        wire l2_rd_now = l2_act && !l2_wr && l2r;                 // read data arrives this cycle
        wire data_ok   = upg || putm || dirty || l2_have || l2_rd_now;
        wire want_grant  = (state == E_WAIT) && !fwd && all_ans && data_ok;
        wire want_fgrant = (state == E_WAIT) && fwd && !granted;
        wire want_probe  = (state == E_PROBE) && (to_probe != 4'b0000);
        wire want_fdata  = (state == E_FDATA) && l2_have;
        wire f_done      = (state == E_WAIT) && fwd && granted && all_ans;
        wire late_rd     = (state == E_WAIT) && !fwd && all_ans && (gets || getm) &&
                           !dirty && !l2_have && !l2_act;
        wire need_wb     = (gets && dirty) || putok;

        assign e_state[k]  = state;
        assign e_line[k]   = line_a;
        assign e_busy[k]   = (state != E_IDLE);
        assign e_want[k]   = want_probe || want_fgrant || want_fdata || want_grant;
        assign e_grant[k]  = !want_probe && (want_fgrant || (!want_fdata && want_grant));
        assign e_data[k]   = (l2_rd_now && !dirty) ? l2_resp_data : line;
        assign e_gets[k]   = gets;
        assign e_getm[k]   = getm;
        assign e_upg[k]    = upg;
        assign e_putok[k]  = putok;
        assign e_fwd[k]    = fwd;
        assign e_ifetch[k] = ifetch;
        assign e_way[k]    = way;
        assign e_probed[k] = probed;
        assign e_kept[k]   = kept;
        assign e_l2v[k]    = l2_act && !l2r;
        assign e_l2cmd[k]  = l2_cmd;
        assign e_l2line[k] = line_a;
        assign e_l2wd[k]   = line;

        reg [63:0] hdr;
        always @(*) begin
            hdr = 64'd0;
            hdr[`HDR_ADDR] = line_a;
            hdr[`HDR_SRC]  = NODE;
            hdr[`HDR_CORE] = k;
            if (want_probe) begin
                hdr[`HDR_TYPE] = gets ? `MSG_PROBE_RD : getm ? `MSG_PROBE_RDX : `MSG_PROBE_INV;
                hdr[`HDR_DST]  = next_probe;
                hdr[`HDR_FWD]  = fwd;
            end else if (want_fgrant) begin
                hdr[`HDR_TYPE] = `MSG_GRANT;
                hdr[`HDR_DST]  = k;
                hdr[`HDR_FWD]  = 1'b1;
            end else if (want_fdata) begin
                hdr[`HDR_TYPE] = `MSG_DATA;
                hdr[`HDR_DST]  = k;
                hdr[`HDR_DATA] = 1'b1;
            end else begin
                hdr[`HDR_TYPE] = `MSG_GRANT;
                hdr[`HDR_DST]  = k;
                hdr[`HDR_DATA] = gets || getm;
            end
        end
        assign e_hdr[k] = hdr;

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                state <= E_IDLE; line_a <= 27'd0;
                way <= 1'b0; ifetch <= 1'b0; gets <= 1'b0; getm <= 1'b0; upg <= 1'b0;
                putm <= 1'b0; putok <= 1'b0; fwd <= 1'b0;
                to_probe <= 4'd0; probed <= 4'd0; answered <= 4'd0; presp <= 8'd0;
                dirty <= 1'b0; line <= 256'd0; granted <= 1'b0; fsent <= 1'b0;
                l2_act <= 1'b0; l2_wr <= 1'b0; l2_have <= 1'b0; l2_cmd <= 3'd0;
            end else begin
                // L2 answers: read data is kept only until the grant, and
                // never over a dirty line from a probe
                if (l2r) begin
                    l2_act <= 1'b0;
                    if (!l2_wr && state != E_WB && !(sent && want_grant)) begin
                        l2_have <= 1'b1;
                        if (!dirty) line <= l2_resp_data;
                    end
                end

                // Probe answers (can arrive while later probes are being sent)
                if (rsk) begin
                    answered[rs_hdr[`HDR_SRC]]     <= 1'b1;
                    presp[2*rs_hdr[`HDR_SRC] +: 2] <= rs_hdr[`HDR_RESP];
                    if (rs_hdr[`HDR_SENT]) fsent   <= 1'b1;
                    if (rs_hdr[`HDR_DATA]) begin
                        line  <= rs_data;
                        dirty <= 1'b1;
                    end
                end

                case (state)
                    E_IDLE: if (start) begin
                        line_a   <= s_line;
                        way      <= s_way;
                        ifetch   <= s_ifetch;
                        gets     <= s_gets;
                        getm     <= s_getm;
                        upg      <= s_upg;
                        putm     <= s_putm;
                        putok    <= s_putok;
                        fwd      <= s_fwd;
                        to_probe <= s_probe;
                        probed   <= s_probe;
                        answered <= 4'd0;
                        presp    <= 8'd0;
                        dirty    <= 1'b0;
                        granted  <= 1'b0;
                        fsent    <= 1'b0;
                        l2_have  <= 1'b0;
                        line     <= sl_data[k];                 // a PutM's line
                        // Read the L2 beside the probes, unless another cache
                        // owns the line (then it most likely has it dirty)
                        l2_wr    <= 1'b0;
                        if ((s_gets || s_getm) && !s_own) begin
                            l2_act <= 1'b1;
                            l2_cmd <= s_getm ? `BUS_READX : `BUS_READ;
                        end
                        state <= (s_probe != 4'b0000) ? E_PROBE : E_WAIT;
                    end

                    E_PROBE: begin
                        if (sent) to_probe[next_probe] <= 1'b0;
                        if (to_probe == 4'b0000) state <= E_WAIT;
                    end

                    E_WAIT: if (want_fgrant) begin
                        if (sent) granted <= 1'b1;
                    end else if (f_done) begin
                        if (fsent) begin                        // the owner sent the line
                            state <= (gets && dirty) ? E_WB : E_IDLE;   // GetS: dirty line to L2 too
                        end else begin                          // the owner had no copy: L2
                            l2_act <= 1'b1;
                            l2_wr  <= 1'b0;
                            l2_cmd <= gets ? `BUS_READ : `BUS_READX;
                            state  <= E_FDATA;
                        end
                    end else if (late_rd) begin                 // the owner had no dirty copy
                        l2_act <= 1'b1;
                        l2_wr  <= 1'b0;
                        l2_cmd <= getm ? `BUS_READX : `BUS_READ;
                    end else if (want_grant && sent) begin
                        // done, unless the L2 still has work for this request
                        state <= (need_wb || (l2_act && !l2r)) ? E_WB : E_IDLE;
                    end

                    E_FDATA: if (sent) state <= E_IDLE;         // line from the L2 sent

                    E_WB: begin                                 // after the grant: L2 write
                        if (!l2_act && (need_wb && !l2_wr)) begin
                            l2_act <= 1'b1;
                            l2_wr  <= 1'b1;
                            l2_cmd <= `BUS_FLUSH;
                        end else if (l2_wr && l2r) begin
                            state <= E_IDLE;
                        end else if (!need_wb && (!l2_act || l2r)) begin
                            state <= E_IDLE;
                        end
                    end

                    default: state <= E_IDLE;
                endcase
            end
        end
    end endgenerate

`ifdef NOC_DEBUG
    always @(posedge clk) if (rst_n) begin
        if (st_v)
            $display("%0t home%0d: start core=%0d cmd=%0d way=%0d if=%0d line=%h hold=%b owner=%b probe=%b fwd=%0d",
                     $time, NODE, st_k, s_cmd, s_way, s_ifetch, {s_line,5'b0}, s_hold, s_owner, s_probe, s_fwd);
        if (rs_valid) $display("%0t home%0d: answer core=%0d line=%h resp=%0d data=%0d sent=%0d", $time, NODE,
                               rs_hdr[`HDR_SRC], {rs_hdr[`HDR_ADDR],5'b0}, rs_hdr[`HDR_RESP], rs_hdr[`HDR_DATA], rs_hdr[`HDR_SENT]);
        if (tx_send) $display("%0t home%0d: send type=%0d to %0d line=%h grant=%0d shared=%0d", $time, NODE,
                              tx_hdr[`HDR_TYPE], tx_hdr[`HDR_DST], {tx_hdr[`HDR_ADDR],5'b0}, e_grant[tx_k], tx_hdr[`HDR_SHARED]);
    end
`endif
`ifdef SIM
    // ------------------------------------------------------------------
    // Protocol assertions (simulation only; a failure stops the run)
    // ------------------------------------------------------------------
    // Directory after this grant: the entries of the line, per core
    reg [3:0] a_hold, a_em;
    reg [22:0] a_new;
    integer a;
    always @(*) begin
        a_hold = 4'd0; a_em = 4'd0;
        for (a = 0; a < 8; a = a + 1) begin
            a_new = dt_we[a] ? dt_wv[a] : db[a];
            if (a_new[22:21] != D_I && a_new[20:0] == g_tag) begin
                a_hold[a/2] = 1'b1;
                if (a_new[22:21] == D_EM) a_em[a/2] = 1'b1;
            end
        end
        // victims of this line, after the grant
        for (a = 0; a < 4; a = a + 1)
            if (gv[a] && vic_nx[a] != D_I) begin
                a_hold[a] = 1'b1;
                if (vic_nx[a] == D_EM) a_em[a] = 1'b1;
            end
    end
    function integer ones4(input [3:0] v); ones4 = v[0] + v[1] + v[2] + v[3]; endfunction

    integer busy_cyc [0:3];
    integer bk, nl;
    reg     a_ok;
    initial for (bk = 0; bk < 4; bk = bk + 1) busy_cyc[bk] = 0;
    always @(posedge clk) if (rst_n) begin
        // single writer: after a grant at most one cache owns the line (EM),
        // and an owner is the only cache that holds it
        if (g_now)
            assert (ones4(a_em) <= 1 && (a_em == 4'd0 || a_hold == a_em))
            else begin
                $display("ERROR SVA dir_home %0d: line %h has owners %b and holders %b after a grant (t=%0t)",
                         NODE, {g_line, 5'b0}, a_em, a_hold, $time);
                $fatal(1);
            end
        // one transaction per line: no two engines on the same line
        for (bk = 0; bk < 4; bk = bk + 1)
            for (nl = bk + 1; nl < 4; nl = nl + 1)
                assert (!(e_busy[bk] && e_busy[nl] && e_line[bk] == e_line[nl]))
                else begin
                    $display("ERROR SVA dir_home %0d: engines %0d and %0d both on line %h (t=%0t)",
                             NODE, bk, nl, {e_line[bk], 5'b0}, $time);
                    $fatal(1);
                end
        // a request arrives only when its core's slot is free (one per core)
        if (rq_valid)
            assert (!sl_v[rq_hdr[`HDR_SRC]] || (st_v && st_k == rq_hdr[`HDR_SRC]))
            else begin
                $display("ERROR SVA dir_home %0d: second request from core %0d (t=%0t)", NODE, rq_hdr[`HDR_SRC], $time);
                $fatal(1);
            end
        // no unexpected answers: each probed core answers once, to an engine on that line
        a_ok = 1'b0;
        for (bk = 0; bk < 4; bk = bk + 1)
            if (e_rs[bk] && e_probed[bk][rs_hdr[`HDR_SRC]]) a_ok = 1'b1;
        if (rs_valid)
            assert (a_ok)
            else begin
                $display("ERROR SVA dir_home %0d: probe answer from core %0d for line %h that was not probed (t=%0t)",
                         NODE, rs_hdr[`HDR_SRC], {rs_hdr[`HDR_ADDR], 5'b0}, $time);
                $fatal(1);
            end
        // progress: a transaction ends within 5000 cycles
        for (bk = 0; bk < 4; bk = bk + 1) begin
            busy_cyc[bk] = e_busy[bk] ? busy_cyc[bk] + 1 : 0;
            assert (busy_cyc[bk] < 5000)
            else begin
                $display("ERROR SVA dir_home %0d: engine %0d stuck on line %h in state %0d (t=%0t)",
                         NODE, bk, {e_line[bk], 5'b0}, e_state[bk], $time);
                $fatal(1);
            end
        end
    end
`endif

endmodule
