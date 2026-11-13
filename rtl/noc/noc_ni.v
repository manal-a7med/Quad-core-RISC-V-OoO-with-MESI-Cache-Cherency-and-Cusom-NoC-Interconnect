`timescale 1ns / 1ps
// ============================================================================
// noc_ni.v - network interface between one core's L1 port and the NoC
// ============================================================================
// Turns the L1 coherence port (rtl/coherence/coh_port.vh) into messages:
//   * an L1 request becomes one REQ packet to the line's home (a PutM carries
//     the line); the matching GRANT from the home becomes l1_ack (with the
//     line and the shared bit)
//   * a probe from the home is played into the L1's snoop port; the answer
//     (and the line, if it was dirty) goes back to the home as an RSP packet
//
// Grants and probes come in on the same network in the order the home sent
// them, and are handled one at a time, so the L1 always sees a grant before
// any later probe for that line.
//
// After a grant, a probe is held back for three cycles: the L1 needs the
// acknowledge cycle, FILL_WAIT and COMPARE to finish the access the line was
// fetched for. Without this, two cores storing to the same line take it from
// each other forever (each GetM's probe arrives before the store is done).
// On the bus the arbitration and COMPLETE cycles give the same gap.
// ============================================================================

`include "mesi_defines.vh"
`include "noc_defs.vh"

module noc_ni #(
    parameter [1:0] CORE   = 2'd0,
    parameter       NBANKS = 1,             // 1: one home at HOME0; 4: home = line addr bits [6:5]
    parameter [1:0] HOME0  = 2'd0
) (
    input  wire               clk,
    input  wire               rst_n,

    // L1 port, request half
    input  wire               l1_req,
    input  wire [2:0]         l1_cmd,
    input  wire [31:0]        l1_addr,
    input  wire [255:0]       l1_wdata,
    input  wire               l1_ifetch,
    input  wire               l1_way,
    output reg                l1_ack,
    output wire [255:0]       l1_rdata,
    output wire               l1_shared,
    output wire               l1_busy,

    // L1 port, probe half
    output reg                pr_valid,
    output wire [31:0]        pr_addr,
    output reg  [2:0]         pr_cmd,
    input  wire [1:0]         pr_resp,
    input  wire [255:0]       pr_data,
    input  wire               pr_dvalid,

    // REQ network (inject)
    output wire [`LINK_W-1:0] req_flit,
    output wire               req_valid,
    input  wire               req_ready,
    // RSP network (inject)
    output wire [`LINK_W-1:0] rsp_flit,
    output wire               rsp_valid,
    input  wire               rsp_ready,
    // OUT network (eject)
    input  wire [`LINK_W-1:0] out_flit,
    input  wire               out_valid,
    output wire               out_ready,
    // RSP network (eject): lines sent straight here by their owner
    input  wire [`LINK_W-1:0] dat_flit,
    input  wire               dat_valid,
    output wire               dat_ready
);

    function [1:0] home_of;
        input [31:0] a;
        home_of = (NBANKS == 4) ? a[6:5] : HOME0;
    endfunction

    // ------------------------------------------------------------------
    // Requests
    // ------------------------------------------------------------------
    reg  sent, ack_d;
    reg  [1:0] hold;                          // cycles left before a probe may follow a grant
    wire req_idle;
    wire req_send = l1_req && !sent && req_idle;

    reg [63:0] req_hdr;
    always @(*) begin
        req_hdr               = 64'd0;
        req_hdr[`HDR_TYPE]    = l1_cmd;
        req_hdr[`HDR_DST]     = home_of(l1_addr);
        req_hdr[`HDR_SRC]     = CORE;
        req_hdr[`HDR_WAY]     = l1_way;
        req_hdr[`HDR_DATA]    = (l1_cmd == `BUS_FLUSH);
        req_hdr[`HDR_IFETCH]  = l1_ifetch;
        req_hdr[`HDR_ADDR]    = l1_addr[31:5];
    end

    noc_tx u_req_tx (
        .clk(clk), .rst_n(rst_n),
        .send(req_send), .hdr(req_hdr), .data(l1_wdata), .idle(req_idle),
        .flit(req_flit), .valid(req_valid), .ready(req_ready)
    );

    assign l1_busy = sent || ack_d;

    // ------------------------------------------------------------------
    // Grants and probes from the home
    // ------------------------------------------------------------------
    wire         op_valid;
    wire [63:0]  op_hdr;
    wire [255:0] op_data;
    reg          op_pop;

    noc_rx u_out_rx (
        .clk(clk), .rst_n(rst_n),
        .flit(out_flit), .valid(out_valid), .ready(out_ready),
        .pkt_valid(op_valid), .pkt_hdr(op_hdr), .pkt_data(op_data), .pkt_pop(op_pop)
    );

    // Lines from their owner (forwarded requests)
    wire         dv_valid;
    wire [63:0]  dv_hdr;
    wire [255:0] dv_data;
    reg          dv_pop;
    noc_rx u_dat_rx (
        .clk(clk), .rst_n(rst_n),
        .flit(dat_flit), .valid(dat_valid), .ready(dat_ready),
        .pkt_valid(dv_valid), .pkt_hdr(dv_hdr), .pkt_data(dv_data), .pkt_pop(dv_pop)
    );

    // A grant marked HDR_FWD: the line comes separately, from the owner
    // (dat_*) or from the home (MSG_DATA on OUT). Until it is here, probes
    // for that line wait: they belong to later requests of other cores.
    reg  wait_data, wd_shared;
    wire is_data  = (op_hdr[`HDR_TYPE] == `MSG_DATA);
    wire use_dv   = wait_data && dv_valid;          // the line came from the owner

    assign l1_rdata  = use_dv ? dv_data : op_data;
    assign l1_shared = wait_data ? wd_shared : op_hdr[`HDR_SHARED];
    assign pr_addr   = {op_hdr[`HDR_ADDR], 5'b0};

    localparam P_IDLE = 2'd0, P_WAIT = 2'd1, P_DATA = 2'd3, P_SEND = 2'd2;
    reg  [1:0]  pstate;
    reg  [1:0]  presp;
    reg  [255:0] pdata;
    reg          pdirty;
    reg          pfwd;                            // send the line to the requester first
    wire         rsp_idle;
    wire         is_grant = (op_hdr[`HDR_TYPE] == `MSG_GRANT);

    // Probe answer to the home; for a forwarding probe, first the line to
    // the requester (a GetS requester shares it with this core)
    wire p_rd = (op_hdr[`HDR_TYPE] == `MSG_PROBE_RD);
    reg [63:0] rsp_hdr;
    always @(*) begin
        rsp_hdr              = 64'd0;
        rsp_hdr[`HDR_SRC]    = CORE;
        rsp_hdr[`HDR_ADDR]   = op_hdr[`HDR_ADDR];
        if (pstate == P_DATA) begin
            rsp_hdr[`HDR_TYPE]   = `MSG_DATA;
            rsp_hdr[`HDR_DST]    = op_hdr[`HDR_CORE];
            rsp_hdr[`HDR_CORE]   = op_hdr[`HDR_CORE];
            rsp_hdr[`HDR_DATA]   = 1'b1;
            rsp_hdr[`HDR_SHARED] = p_rd;
        end else begin
            rsp_hdr[`HDR_TYPE]   = `MSG_PRESP;
            rsp_hdr[`HDR_DST]    = home_of(pr_addr);
            // a forwarded GetM needs no data at the home (the requester has it)
            rsp_hdr[`HDR_DATA]   = pdirty && !(pfwd && !p_rd);
            rsp_hdr[`HDR_RESP]   = presp;
            rsp_hdr[`HDR_SENT]   = pfwd;
        end
    end
    wire rsp_send = (pstate == P_SEND || pstate == P_DATA) && rsp_idle;

    noc_tx u_rsp_tx (
        .clk(clk), .rst_n(rst_n),
        .send(rsp_send), .hdr(rsp_hdr), .data(pdata), .idle(rsp_idle),
        .flit(rsp_flit), .valid(rsp_valid), .ready(rsp_ready)
    );

    wire defer = wait_data && (op_hdr[`HDR_ADDR] == l1_addr[31:5]);   // probe for the line on its way here

    always @(*) begin
        l1_ack   = 1'b0;
        pr_valid = 1'b0;
        op_pop   = 1'b0;
        dv_pop   = 1'b0;
        case (op_hdr[`HDR_TYPE])
            `MSG_PROBE_RD:  pr_cmd = `BUS_READ;
            `MSG_PROBE_RDX: pr_cmd = `BUS_READX;
            default:        pr_cmd = `BUS_UPGR;
        endcase
        if (use_dv) begin                                  // line from the owner
            l1_ack = 1'b1;
            dv_pop = 1'b1;
        end
        if (op_valid) begin
            if (is_grant) begin
                if (!use_dv) begin
                    l1_ack = !op_hdr[`HDR_FWD];                // else wait for the line
                    op_pop = 1'b1;
                end
            end else if (is_data) begin                        // line from the home
                if (!use_dv) begin
                    l1_ack = 1'b1;
                    op_pop = 1'b1;
                end
            end else begin
                pr_valid = (pstate == P_IDLE) && (hold == 2'd0) && !defer && !use_dv;
                op_pop   = rsp_send && (pstate == P_SEND);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sent   <= 1'b0;
            ack_d  <= 1'b0;
            hold   <= 2'd0;
            pstate <= P_IDLE;
            presp  <= `SNOOP_NONE;
            pdata  <= 256'd0;
            pdirty <= 1'b0;
            pfwd   <= 1'b0;
            wait_data <= 1'b0;
            wd_shared <= 1'b0;
        end else begin
            if (op_valid && is_grant && op_hdr[`HDR_FWD] && !use_dv) begin
                wait_data <= 1'b1;
                wd_shared <= op_hdr[`HDR_SHARED];
            end
            if (l1_ack) wait_data <= 1'b0;
            ack_d <= l1_ack;
            if (l1_ack)            hold <= 2'd3;
            else if (hold != 2'd0) hold <= hold - 2'd1;
            if (req_send) sent <= 1'b1;
            if (l1_ack)   sent <= 1'b0;

            case (pstate)
                P_IDLE: if (pr_valid) pstate <= P_WAIT;
                P_WAIT: begin                       // the L1 answers this cycle
                    presp  <= pr_resp;
                    pdata  <= pr_data;
                    pdirty <= (pr_resp == `SNOOP_HITM) && pr_dvalid;
                    // forwarding probe and the line is here: send it to the requester
                    pfwd   <= op_hdr[`HDR_FWD] && (pr_resp == `SNOOP_HIT || pr_resp == `SNOOP_HITM);
                    pstate <= (op_hdr[`HDR_FWD] && (pr_resp == `SNOOP_HIT || pr_resp == `SNOOP_HITM))
                              ? P_DATA : P_SEND;
                end
                P_DATA: if (rsp_idle) pstate <= P_SEND;
                P_SEND: if (rsp_idle) pstate <= P_IDLE;
                default: pstate <= P_IDLE;
            endcase
        end
    end

`ifdef SIM
    // ------------------------------------------------------------------
    // Protocol assertions (simulation only; a failure stops the run)
    // ------------------------------------------------------------------
    integer wait_cyc;
    initial wait_cyc = 0;
    always @(posedge clk) if (rst_n) begin
        // a grant answers a request that was sent
        if (l1_ack)
            assert (sent)
            else begin
                $display("ERROR SVA noc_ni %0d: grant without a request (t=%0t)", CORE, $time);
                $fatal(1);
            end
        // a grant (or the line after it) is for the line that was requested
        if (l1_ack)
            assert ((use_dv ? dv_hdr[`HDR_ADDR] : op_hdr[`HDR_ADDR]) == l1_addr[31:5])
            else begin
                $display("ERROR SVA noc_ni %0d: grant for line %h, requested %h (t=%0t)",
                         CORE, {op_hdr[`HDR_ADDR], 5'b0}, {l1_addr[31:5], 5'b0}, $time);
                $fatal(1);
            end
        // no lost grants: a request is granted within 20000 cycles
        wait_cyc = sent ? wait_cyc + 1 : 0;
        assert (wait_cyc < 20000)
        else begin
            $display("ERROR SVA noc_ni %0d: request for line %h not granted (t=%0t)", CORE, {l1_addr[31:5], 5'b0}, $time);
            $fatal(1);
        end
    end
`endif

endmodule
