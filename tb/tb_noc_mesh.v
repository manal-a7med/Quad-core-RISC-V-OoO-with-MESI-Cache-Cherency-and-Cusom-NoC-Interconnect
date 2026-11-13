`timescale 1ns / 1ps
// ============================================================================
// tb_noc_mesh.v - random-traffic test of one 2x2 mesh network (noc_mesh)
// ============================================================================
// Every node sends random packets (1 or 5 flits) to random nodes, itself
// included, while every node's eject port is randomly not ready. Checked:
//   * every flit arrives at the node in its header, unchanged
//   * the flits of a packet arrive together, in order (wormhole switching)
//   * packets from one source to one destination arrive in the order sent
//   * nothing is lost or duplicated: every packet sent is received once
//   * the network does not lock up (traffic drains after injection stops)
// Plusargs: +seed=N +pkts=N (packets per source) +ready=P (eject ready %)
// Flit width from +define+NOC_FLIT_W (64, 128 or 256).
// ============================================================================

`include "noc_defs.vh"

module tb_noc_mesh;
    localparam LW = `LINK_W;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire [4*LW-1:0] inj_flit, ej_flit;
    wire [3:0] inj_valid, inj_ready, ej_valid;
    reg  [3:0] ej_ready;

    noc_mesh dut (.clk(clk), .rst_n(rst_n),
        .inj_flit(inj_flit), .inj_valid(inj_valid), .inj_ready(inj_ready),
        .ej_flit(ej_flit), .ej_valid(ej_valid), .ej_ready(ej_ready));

    integer seed, seed0, npkts, rdy_pct, errors, cyc;
    integer sent    [0:3];                 // packets sent per source
    integer got     [0:3];                 // packets received per destination
    integer nexp    [0:15];                // next expected seq, index src*4+dst
    integer nsent   [0:15];                // packets sent, index src*4+dst
    integer flits_rx;

    // ------------------------------------------------------------------
    // Senders: one noc_tx per node
    // ------------------------------------------------------------------
    reg  [3:0]  send;
    reg  [63:0] hdr  [0:3];
    reg  [255:0] data [0:3];
    wire [3:0]  idle;

    genvar n;
    generate for (n = 0; n < 4; n = n + 1) begin : src
        noc_tx u_tx (.clk(clk), .rst_n(rst_n), .send(send[n]), .hdr(hdr[n]), .data(data[n]),
                     .idle(idle[n]), .flit(inj_flit[n*LW +: LW]), .valid(inj_valid[n]),
                     .ready(inj_ready[n]));
    end endgenerate

    function [255:0] payload;              // data flits derived from the header
        input [63:0] h;
        integer w;
        begin
            for (w = 0; w < 4; w = w + 1)
                payload[w*64 +: 64] = {h[63:32] ^ 32'h5a5a0000, h[31:0] + w};
        end
    endfunction

    localparam FW = `FLIT_W;
    function [FW-1:0] word_of;
        input [63:0] h;
        input integer w;
        reg [255:0] p;
        begin
            p = payload(h);
            word_of = p[w*FW +: FW];
        end
    endfunction

    integer s, d, k;
    always @(negedge clk) begin
        for (s = 0; s < 4; s = s + 1) begin
            send[s] = 1'b0;
            if (rst_n && idle[s] && sent[s] < npkts && ($random(seed) % 4) != 0) begin
                d = {$random(seed)} % 4;
                hdr[s] = 64'd0;
                hdr[s][`HDR_TYPE] = {$random(seed)} % 8;
                hdr[s][`HDR_DST]  = d;
                hdr[s][`HDR_SRC]  = s;
                hdr[s][`HDR_DATA] = {$random(seed)} % 2;
                hdr[s][`HDR_ADDR] = $random(seed);
                hdr[s][63:48]     = nsent[s*4 + d];          // sequence number
                data[s] = payload(hdr[s]);
                nsent[s*4 + d] = nsent[s*4 + d] + 1;
                sent[s] = sent[s] + 1;
                send[s] = 1'b1;
            end
            ej_ready[s] = ({$random(seed)} % 100) < rdy_pct;
        end
    end

    // ------------------------------------------------------------------
    // Receivers: check each flit as it leaves the mesh
    // ------------------------------------------------------------------
    reg [63:0] cur_hdr [0:3];
    integer    pos     [0:3];              // flits of the current packet seen (0 = expecting a header)
    integer    plen    [0:3];
    reg [LW-1:0] f;
    integer sx;

    always @(posedge clk) if (rst_n) begin
        for (d = 0; d < 4; d = d + 1) if (ej_valid[d] && ej_ready[d]) begin
            f = ej_flit[d*LW +: LW];
            flits_rx = flits_rx + 1;
            if (pos[d] == 0) begin
                cur_hdr[d] = f[63:0];
                plen[d] = f[`HDR_DATA] ? 1 + `DATA_FLITS : 1;
                sx = f[`HDR_SRC];
                if (f[`HDR_DST] != d) begin
                    $display("ERROR node %0d got a packet for node %0d", d, f[`HDR_DST]); errors = errors + 1;
                end
                if (f[63:48] != nexp[sx*4 + d]) begin
                    $display("ERROR node %0d: packet %0d from %0d, expected %0d (order or loss)",
                             d, f[63:48], sx, nexp[sx*4 + d]); errors = errors + 1;
                end
                nexp[sx*4 + d] = f[63:48] + 1;
            end else if (f[FW-1:0] != word_of(cur_hdr[d], pos[d] - 1)) begin
                $display("ERROR node %0d: data flit %0d of packet %0d from %0d corrupted or interleaved",
                         d, pos[d], cur_hdr[d][63:48], cur_hdr[d][`HDR_SRC]); errors = errors + 1;
            end
            if (f[LW-1] != (pos[d] == plen[d] - 1)) begin
                $display("ERROR node %0d: tail bit wrong at flit %0d", d, pos[d]); errors = errors + 1;
            end
            pos[d] = pos[d] + 1;
            if (pos[d] == plen[d]) begin
                pos[d] = 0;
                got[d] = got[d] + 1;
            end
        end
    end

    integer total_sent, total_got, i;
    initial begin
        if (!$value$plusargs("seed=%d", seed))   seed = 1;
        seed0 = seed;
        if (!$value$plusargs("pkts=%d", npkts))  npkts = 2000;
        if (!$value$plusargs("ready=%d", rdy_pct)) rdy_pct = 70;
        errors = 0; flits_rx = 0; send = 0; ej_ready = 0;
        for (i = 0; i < 4; i = i + 1) begin
            sent[i] = 0; got[i] = 0; pos[i] = 0; plen[i] = 1; hdr[i] = 0; data[i] = 0;
        end
        for (i = 0; i < 16; i = i + 1) begin nexp[i] = 0; nsent[i] = 0; end

        repeat (3) @(posedge clk);
        rst_n = 1;
        cyc = 0;
        while ((sent[0] + sent[1] + sent[2] + sent[3] < 4 * npkts ||
                got[0] + got[1] + got[2] + got[3] < 4 * npkts) && cyc < 200 * npkts) begin
            @(posedge clk); cyc = cyc + 1;
        end
        repeat (20) @(posedge clk);

        total_sent = 0; total_got = 0;
        for (i = 0; i < 4; i = i + 1) begin
            total_sent = total_sent + sent[i];
            total_got  = total_got + got[i];
        end
        for (i = 0; i < 16; i = i + 1)
            if (nexp[i] != nsent[i]) begin
                $display("ERROR src %0d -> dst %0d: sent %0d, received %0d", i / 4, i % 4, nsent[i], nexp[i]);
                errors = errors + 1;
            end
        $display("noc mesh test: seed %0d, %0d packets sent, %0d received, %0d flits, %0d cycles, eject ready %0d%%",
                 seed0, total_sent, total_got, flits_rx, cyc, rdy_pct);
        if (errors == 0 && total_got == total_sent) $display("RESULT PASS");
        else                                         $display("RESULT FAIL errors=%0d", errors);
        $finish;
    end
endmodule
