`timescale 1ns / 1ps
// ============================================================================
// dir_home.v - directory home node for the NoC build (MESI, blocking)
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
// One transaction at a time (per home): the request packet stays in its
// receive buffer until the grant has been sent.
//
//   request         probes sent to              data from                  grant
//   GetS (BusRd)    holders in EM               dirty probe answer (also   S if another copy
//                                               written to L2) or L2       stays, else E
//   GetS (I-fetch)  same, incl. the requester   same                       line only
//   GetM (BusRdX)   all other holders           dirty probe answer or L2   M
//   Upgrade         all other holders (inval.)  none                       ack
//     (the requester no longer has the line: handled as GetM)
//   PutM (BusFlush) none                        written to L2 if the       ack
//                                               sender still owns it
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
    output reg                l2_req_valid,
    output reg  [31:0]        l2_req_addr,
    output reg  [2:0]         l2_req_cmd,
    output reg  [255:0]       l2_req_wdata,
    input  wire [255:0]       l2_resp_data,
    input  wire               l2_resp_valid
);

    localparam [1:0] D_I = 2'd0, D_S = 2'd1, D_EM = 2'd2;

    // ------------------------------------------------------------------
    // Packet buffers
    // ------------------------------------------------------------------
    wire         rq_valid;
    wire [63:0]  rq_hdr;
    wire [255:0] rq_data;
    reg          rq_pop;
    noc_rx u_req_rx (
        .clk(clk), .rst_n(rst_n), .flit(req_flit), .valid(req_valid), .ready(req_ready),
        .pkt_valid(rq_valid), .pkt_hdr(rq_hdr), .pkt_data(rq_data), .pkt_pop(rq_pop)
    );

    wire         rs_valid;
    wire [63:0]  rs_hdr;
    wire [255:0] rs_data;
    noc_rx u_rsp_rx (
        .clk(clk), .rst_n(rst_n), .flit(rsp_flit), .valid(rsp_valid), .ready(rsp_ready),
        .pkt_valid(rs_valid), .pkt_hdr(rs_hdr), .pkt_data(rs_data), .pkt_pop(rs_valid)
    );                                          // responses are always taken at once

    reg          tx_send;
    reg  [63:0]  tx_hdr;
    wire         tx_idle;
    reg  [255:0] line;                         // the line for the grant
    reg  [2:0]   state;
    wire [255:0] tx_data;
    noc_tx u_out_tx (
        .clk(clk), .rst_n(rst_n), .send(tx_send), .hdr(tx_hdr), .data(tx_data), .idle(tx_idle),
        .flit(out_flit), .valid(out_valid), .ready(out_ready)
    );

    // ------------------------------------------------------------------
    // The request being served
    // ------------------------------------------------------------------
    wire [2:0]  r_cmd    = rq_hdr[`HDR_TYPE];
    wire [1:0]  r_core   = rq_hdr[`HDR_SRC];
    wire        r_way    = rq_hdr[`HDR_WAY];
    wire        r_ifetch = rq_hdr[`HDR_IFETCH];
    wire [26:0] r_line   = rq_hdr[`HDR_ADDR];
    wire [5:0]  idx      = r_line[5:0];          // L1 set = addr[10:5]
    wire [20:0] tag      = r_line[26:6];         // L1 tag = addr[31:11]

    // ------------------------------------------------------------------
    // Duplicate tags: entry e = {core, way}, 8 LUT RAMs of 64 x {state, tag}
    // ------------------------------------------------------------------
    wire [22:0] de [0:7];
    reg  [7:0]  dt_we;
    reg  [22:0] dt_wv [0:7];
    reg  [5:0]  init_idx;
    reg         init;

    genvar ge;
    generate for (ge = 0; ge < 8; ge = ge + 1) begin : dtag
        reg [22:0] ram [0:63];
        assign de[ge] = ram[idx];
        always @(posedge clk)
            if (init)            ram[init_idx] <= 23'd0;
            else if (dt_we[ge])  ram[idx]      <= dt_wv[ge];
    end endgenerate

    // Entries that hold this line, per entry and per core
    wire [7:0] m;                                // entry matches the line
    wire [7:0] m_em;                             // ... in EM
    generate for (ge = 0; ge < 8; ge = ge + 1) begin : match
        assign m[ge]    = (de[ge][22:21] != D_I) && (de[ge][20:0] == tag);
        assign m_em[ge] = m[ge] && (de[ge][22:21] == D_EM);
    end endgenerate
    wire [3:0] hold  = {m[7] | m[6], m[5] | m[4], m[3] | m[2], m[1] | m[0]};
    wire [3:0] owner = {m_em[7] | m_em[6], m_em[5] | m_em[4], m_em[3] | m_em[2], m_em[1] | m_em[0]};
    wire [2:0] r_ent = {r_core, r_way};

    wire [3:0] self   = r_ifetch ? 4'b0000 : (4'b0001 << r_core);
    wire [3:0] others = hold & ~self;

    // Effective request
    wire is_putm  = (r_cmd == `BUS_FLUSH);
    wire is_upg   = (r_cmd == `BUS_UPGR) && m[r_ent];         // requester still has it
    wire is_getm  = (r_cmd == `BUS_READX) || ((r_cmd == `BUS_UPGR) && !m[r_ent]);
    wire is_gets  = (r_cmd == `BUS_READ);                     // includes I-fetch
    wire putm_ok  = is_putm && m_em[r_ent];                   // sender still owns the line

    wire [3:0] probe_set = is_gets ? (others & owner) : (is_getm || is_upg) ? others : 4'b0000;
    wire [2:0] probe_msg = is_gets ? `MSG_PROBE_RD : is_getm ? `MSG_PROBE_RDX : `MSG_PROBE_INV;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam [2:0] H_INIT = 3'd0, H_IDLE = 3'd1, H_PROBE = 3'd2, H_COLLECT = 3'd3,
                     H_L2 = 3'd4, H_GRANT = 3'd5;
    reg [3:0] to_probe;                          // probes still to send
    reg [3:0] probed;                            // probes sent in this transaction
    reg [3:0] answered;                          // probe answers received
    reg [7:0] presp;                             // answer per core (`SNOOP_*)
    reg       dirty;                             // a probe returned a dirty line (in `line`)

    wire [1:0] next_probe = to_probe[0] ? 2'd0 : to_probe[1] ? 2'd1 : to_probe[2] ? 2'd2 : 2'd3;
    wire       all_answered = (answered == probed);

    // Copies seen in the probe answers (clean or dirty)
    reg [3:0] kept;
    integer c;
    always @(*)
        for (c = 0; c < 4; c = c + 1)
            kept[c] = probed[c] && (presp[2*c +: 2] == `SNOOP_HIT || presp[2*c +: 2] == `SNOOP_HITM);
    // GetS: another copy stays if a probed owner kept one, or a sharer was not probed
    wire shared = |kept || |(others & ~probed);

    // L2 access needed after the probes
    wire need_l2 = is_putm ? putm_ok : is_upg ? 1'b0 : is_getm ? !dirty : 1'b1;

    always @(*) begin
        l2_req_valid = 1'b0;
        l2_req_addr  = {r_line, 5'b0};
        l2_req_cmd   = r_cmd;
        l2_req_wdata = line;
        if (state == H_L2) begin
            l2_req_valid = !l2_resp_valid;
            if (is_putm) begin
                l2_req_cmd = `BUS_FLUSH; l2_req_wdata = rq_data;
            end else if (dirty) begin                 // GetS with a dirty owner: update L2
                l2_req_cmd = `BUS_FLUSH;
            end else if (is_getm) begin
                l2_req_cmd = `BUS_READX;
            end else begin
                l2_req_cmd = `BUS_READ;
            end
        end
    end

    // Outgoing packets: probes in H_PROBE; the grant as soon as the L2
    // answers (straight from its output), else in H_GRANT
    wire grant_cyc = (state == H_GRANT) || (state == H_L2 && l2_resp_valid);
    wire grant_now = grant_cyc && tx_idle;
    assign tx_data = (state == H_L2) ? l2_resp_data : line;

    always @(*) begin
        tx_send = 1'b0;
        tx_hdr  = 64'd0;
        tx_hdr[`HDR_ADDR] = r_line;
        if (state == H_PROBE && to_probe != 4'b0000) begin
            tx_send = tx_idle;
            tx_hdr[`HDR_TYPE] = probe_msg;
            tx_hdr[`HDR_DST]  = next_probe;
            tx_hdr[`HDR_SRC]  = NODE;
        end else if (grant_cyc) begin
            tx_send = tx_idle;
            tx_hdr[`HDR_TYPE]   = `MSG_GRANT;
            tx_hdr[`HDR_DST]    = r_core;
            tx_hdr[`HDR_SRC]    = NODE;
            tx_hdr[`HDR_CORE]   = r_core;
            tx_hdr[`HDR_DATA]   = is_gets || is_getm;
            tx_hdr[`HDR_SHARED] = is_gets && shared;
        end
    end

    // Directory update, written when the grant is sent
    integer e;
    always @(*) begin
        dt_we = 8'd0;
        for (e = 0; e < 8; e = e + 1) begin
            dt_wv[e] = de[e];
            if (m[e]) begin
                if (is_gets && probed[e/2]) begin
                    dt_we[e] = 1'b1;
                    dt_wv[e] = kept[e/2] ? {D_S, tag} : 23'd0;
                end
                if ((is_getm || is_upg) && probed[e/2]) begin
                    dt_we[e] = 1'b1;
                    dt_wv[e] = 23'd0;
                end
                if (e/2 == r_core && !r_ifetch && e != r_ent) begin   // stale second copy
                    dt_we[e] = 1'b1;
                    dt_wv[e] = 23'd0;
                end
            end
            if (e == r_ent && !r_ifetch) begin
                if (is_putm && putm_ok) begin
                    dt_we[e] = 1'b1; dt_wv[e] = 23'd0;
                end else if (is_gets) begin
                    dt_we[e] = 1'b1; dt_wv[e] = {shared ? D_S : D_EM, tag};
                end else if (is_getm || is_upg) begin
                    dt_we[e] = 1'b1; dt_wv[e] = {D_EM, tag};
                end
            end
        end
        if (!grant_now) dt_we = 8'd0;
    end

    always @(*) rq_pop = grant_now;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= H_INIT;
            init     <= 1'b1;
            init_idx <= 6'd0;
            to_probe <= 4'd0;
            probed   <= 4'd0;
            answered <= 4'd0;
            presp    <= 8'd0;
            dirty    <= 1'b0;
            line     <= 256'd0;
        end else begin
            // Probe answers can arrive while later probes are still being sent
            if (rs_valid) begin
                answered[rs_hdr[`HDR_SRC]]          <= 1'b1;
                presp[2*rs_hdr[`HDR_SRC] +: 2]      <= rs_hdr[`HDR_RESP];
                if (rs_hdr[`HDR_DATA]) begin
                    line  <= rs_data;
                    dirty <= 1'b1;
                end
            end

            case (state)
                H_INIT: begin
                    init_idx <= init_idx + 6'd1;
                    if (init_idx == 6'd63) begin
                        init  <= 1'b0;
                        state <= H_IDLE;
                    end
                end

                H_IDLE: if (rq_valid) begin
                    to_probe <= probe_set;
                    probed   <= probe_set;
                    answered <= 4'd0;
                    presp    <= 8'd0;
                    dirty    <= 1'b0;
                    // Nobody to probe: go straight to the L2 (or the grant)
                    if (probe_set == 4'b0000)
                        state <= (is_putm ? putm_ok : !is_upg) ? H_L2 : H_GRANT;
                    else
                        state <= H_PROBE;
                end

                H_PROBE: begin
                    if (tx_send) to_probe[next_probe] <= 1'b0;
                    if (to_probe == 4'b0000) state <= H_COLLECT;
                end

                H_COLLECT: if (all_answered && !rs_valid)
                    state <= need_l2 ? H_L2 : H_GRANT;

                H_L2: if (l2_resp_valid) begin
                    if (!is_putm) line <= l2_resp_data;
                    state <= tx_idle ? H_IDLE : H_GRANT;     // grant sent now if the sender is free
                end

                H_GRANT: if (tx_idle) state <= H_IDLE;

                default: state <= H_IDLE;
            endcase
        end
    end

`ifdef NOC_DEBUG
    always @(posedge clk) if (rst_n) begin
        if (state == H_IDLE && rq_valid)
            $display("%0t home%0d: req cmd=%0d core=%0d way=%0d if=%0d line=%h hold=%b owner=%b m=%b probe=%b",
                     $time, NODE, r_cmd, r_core, r_way, r_ifetch, {r_line,5'b0}, hold, owner, m, probe_set);
        if (rs_valid) $display("%0t home%0d: answer core=%0d resp=%0d data=%0d", $time, NODE, rs_hdr[`HDR_SRC], rs_hdr[`HDR_RESP], rs_hdr[`HDR_DATA]);
        if (grant_now) $display("%0t home%0d: grant core=%0d shared=%0d upg=%0d getm=%0d dirty=%0d", $time, NODE, r_core, shared, is_upg, is_getm, dirty);
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
            a_new = dt_we[a] ? dt_wv[a] : de[a];
            if (a_new[22:21] != D_I && a_new[20:0] == tag) begin
                a_hold[a/2] = 1'b1;
                if (a_new[22:21] == D_EM) a_em[a/2] = 1'b1;
            end
        end
    end
    function integer ones4(input [3:0] v); ones4 = v[0] + v[1] + v[2] + v[3]; endfunction

    integer busy_cyc;
    always @(posedge clk) if (rst_n) begin
        // single writer: after a grant at most one cache owns the line (EM),
        // and an owner is the only cache that holds it
        if (grant_now)
            assert (ones4(a_em) <= 1 && (a_em == 4'd0 || a_hold == a_em))
            else begin
                $display("ERROR SVA dir_home %0d: line %h has owners %b and holders %b after a grant (t=%0t)",
                         NODE, {r_line, 5'b0}, a_em, a_hold, $time);
                $fatal(1);
            end
        // no unexpected answers: each probed core answers once
        if (rs_valid)
            assert (probed[rs_hdr[`HDR_SRC]] && !answered[rs_hdr[`HDR_SRC]])
            else begin
                $display("ERROR SVA dir_home %0d: probe answer from core %0d that was not probed or already answered (t=%0t)",
                         NODE, rs_hdr[`HDR_SRC], $time);
                $fatal(1);
            end
        // no lost answers: a grant goes out only when every probe was answered
        if (grant_now)
            assert (answered == probed)
            else begin
                $display("ERROR SVA dir_home %0d: grant with probes %b but answers %b (t=%0t)",
                         NODE, probed, answered, $time);
                $fatal(1);
            end
        // progress: a transaction ends within 5000 cycles
        busy_cyc = (state == H_IDLE || state == H_INIT) ? 0 : busy_cyc + 1;
        assert (busy_cyc < 5000)
        else begin
            $display("ERROR SVA dir_home %0d: transaction on line %h stuck in state %0d (t=%0t)",
                     NODE, {r_line, 5'b0}, state, $time);
            $fatal(1);
        end
    end
    initial busy_cyc = 0;
`endif

endmodule
