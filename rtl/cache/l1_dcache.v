`timescale 1ns / 1ps
// ============================================================================
// l1_dcache.v - L1 data cache (4 KB, 2-way, 64 sets, 32-byte lines, MESI)
// ============================================================================
// Storage is FPGA-friendly:
//   * data: one 128 x 256-bit RAM (entry {way, set}) with byte write enables
//     and two registered read ports, CPU and snoop -> true dual-port BRAM.
//     The CPU port shares its address with the write port.
//   * tags: one 64 x 21-bit RAM per way, no reset, asynchronous read -> LUT RAM
//   * MESI state and LRU: reset flip-flop vectors
//
// The CPU port reads the line of the hitting way one cycle ahead (in IDLE,
// from the incoming address), so a hit is still answered in COMPARE_TAG,
// two cycles after the request. After a line fill or upgrade the FSM waits
// one cycle (FILL_WAIT) and looks the request up again; a store is written
// only as a hit on an M or E line, using byte enables, so there is no
// read-modify-write of whole lines.
//
// Snoops take priority: in a cycle with snoop_valid the CPU side does
// nothing, so a store can never race a snoop on the same line (review bug
// 13). A snoop's response (snoop_resp, snoop_data_valid, snoop_data) is
// valid in the cycle after snoop_valid and is cleared afterwards, so a stale
// response can never be mistaken for a new one.
//
// Atomics (cpu_amo, RV32A): LR is a load that also sets a reservation on the
// line. SC and the AMOs need the line in M or E, like a store; the AMO is
// then done in one cycle in COMPARE_TAG (old word from the RAM output, new
// word written back, old word returned). SC succeeds (returns 0) only if the
// reservation is still held; it is lost when a snoop invalidates the line or
// another line is filled.
// ============================================================================

`include "common_defs.vh"
`include "mesi_defines.vh"

module l1_dcache (
    input  wire         clk,
    input  wire         rst_n,

    // CPU side
    input  wire [31:0]  cpu_addr,
    input  wire [31:0]  cpu_wdata,
    output reg  [31:0]  cpu_rdata,
    input  wire         cpu_req,
    input  wire         cpu_wr,
    output reg          cpu_ack,
    input  wire [2:0]   cpu_mem_type,
    input  wire [3:0]   cpu_amo,         // `AMO_* code, 0 for plain loads/stores

    // Bus/coherence side
    output reg  [31:0]  bus_addr,
    output reg  [255:0] bus_wdata,
    input  wire [255:0] bus_rdata,
    output reg          bus_req,
    output reg  [2:0]   bus_cmd,
    input  wire         bus_ack,
    input  wire         bus_grant,
    input  wire         bus_shared,

    // Snoop side
    input  wire [31:0]  snoop_addr,
    input  wire [2:0]   snoop_cmd,
    input  wire         snoop_valid,
    output reg  [1:0]   snoop_resp,
    output wire [255:0] snoop_data,
    output reg          snoop_data_valid
);

    localparam SETS     = 64;
    localparam TAG_BITS = 21;
    localparam IDX_BITS = 6;

    localparam [1:0] I = `MESI_INVALID, S = `MESI_SHARED,
                     E = `MESI_EXCLUSIVE, M = `MESI_MODIFIED;

    localparam [2:0] ST_IDLE      = 3'd0,
                     ST_COMPARE   = 3'd1,   // look up the latched request
                     ST_WB_READ   = 3'd2,   // read the dirty victim line
                     ST_WRITEBACK = 3'd3,   // BusFlush of the victim
                     ST_WB_PAUSE  = 3'd4,   // drop bus_req for a cycle
                     ST_ALLOCATE  = 3'd5,   // BusRd / BusRdX and line fill
                     ST_UPGRADE   = 3'd6,   // BusUpgr (S -> M)
                     ST_FILL_WAIT = 3'd7;   // let the RAM output catch up

    reg [2:0] state, next_state;

    // ------------------------------------------------------------------
    // Latched request
    // ------------------------------------------------------------------
    reg [31:0] req_addr_r, req_wdata_r;
    reg        req_wr_r;
    reg [3:0]  req_amo_r;
    reg [2:0]  req_mtype_r;
    reg        pend_way;                 // way being filled / upgraded / evicted

    wire [IDX_BITS-1:0] idx       = req_addr_r[10:5];
    wire [TAG_BITS-1:0] tag       = req_addr_r[31:11];
    wire [2:0]          word_sel  = req_addr_r[4:2];
    wire [1:0]          byte_off  = req_addr_r[1:0];
    wire [31:0]         line_addr = {req_addr_r[31:5], 5'b0};

    // Lookup address: the incoming request in IDLE, the latched one after
    wire [IDX_BITS-1:0] lk_idx = (state == ST_IDLE) ? cpu_addr[10:5]  : idx;
    wire [TAG_BITS-1:0] lk_tag = (state == ST_IDLE) ? cpu_addr[31:11] : tag;

    // ------------------------------------------------------------------
    // Tags (LUT RAM) and state (flip-flops)
    // ------------------------------------------------------------------
    reg [TAG_BITS-1:0] tag0 [0:SETS-1];
    reg [TAG_BITS-1:0] tag1 [0:SETS-1];
    reg [4*SETS-1:0]   state_bits;      // {way, set} -> [2*{way, set} +: 2]
    reg [SETS-1:0]     lru_bits;        // way to replace next

    wire [TAG_BITS-1:0] t0  = tag0[lk_idx];
    wire [TAG_BITS-1:0] t1  = tag1[lk_idx];
    wire [1:0]          st0 = state_bits[{1'b0, lk_idx}*2 +: 2];
    wire [1:0]          st1 = state_bits[{1'b1, lk_idx}*2 +: 2];

    wire way0_hit  = (st0 != I) && (t0 == lk_tag);
    wire way1_hit  = (st1 != I) && (t1 == lk_tag);
    wire cache_hit = way0_hit || way1_hit;
    wire hit_way   = way1_hit;
    wire [1:0] hit_state = hit_way ? st1 : st0;

    wire vic_way   = (st0 == I) ? 1'b0 : (st1 == I) ? 1'b1 : lru_bits[lk_idx];
    wire vic_dirty = ((vic_way ? st1 : st0) == M);

    wire [1:0]          pend_state = pend_way ? st1 : st0;
    wire [TAG_BITS-1:0] pend_tag   = pend_way ? t1  : t0;

    // Snoop lookup
    wire [IDX_BITS-1:0] s_idx = snoop_addr[10:5];
    wire [TAG_BITS-1:0] s_tag = snoop_addr[31:11];
    wire [1:0] sst0 = state_bits[{1'b0, s_idx}*2 +: 2];
    wire [1:0] sst1 = state_bits[{1'b1, s_idx}*2 +: 2];
    wire snoop_w0_hit = (sst0 != I) && (tag0[s_idx] == s_tag);
    wire snoop_w1_hit = (sst1 != I) && (tag1[s_idx] == s_tag);
    wire snoop_hit    = snoop_w0_hit || snoop_w1_hit;
    wire snoop_way    = snoop_w1_hit;
    wire [1:0] snoop_st = snoop_way ? sst1 : sst0;

    // ------------------------------------------------------------------
    // Data RAM: port A = CPU read/write, port B = snoop read
    // ------------------------------------------------------------------
    (* ram_style = "block" *)            // shallow and wide: tools would pick LUT RAM
    reg [255:0] data_ram [0:2*SETS-1];
    reg [255:0] q, qs;

    reg         d_we;
    reg         d_way;
    reg [31:0]  d_be;                    // byte enables
    reg [255:0] d_wdata;

    // CPU read way: the hitting way, or the victim while writing it back
    wire rd_way = (state == ST_WB_READ || state == ST_WRITEBACK) ? pend_way : hit_way;
    wire [IDX_BITS:0] a_addr = d_we ? {d_way, idx} : {rd_way, lk_idx};
    wire [IDX_BITS:0] b_addr = {snoop_way, s_idx};

    integer bb;
    always @(posedge clk) begin
        for (bb = 0; bb < 32; bb = bb + 1)
            if (d_we && d_be[bb]) data_ram[a_addr][bb*8 +: 8] <= d_wdata[bb*8 +: 8];
        q  <= data_ram[a_addr];
        qs <= data_ram[b_addr];
    end

    assign snoop_data = qs;

    wire [31:0] hit_word = q[word_sel*32 +: 32] >> {byte_off, 3'b000};

    // Atomics
    `include "amo.vh"
    wire        is_lr   = (req_amo_r == `AMO_LR);
    wire        is_sc   = (req_amo_r == `AMO_SC);
    wire        is_rmw  = (req_amo_r >= `AMO_SC);         // SC and AMOs
    wire        wr_eff  = req_wr_r || is_rmw;              // needs the line in M
    reg         resv_valid;
    reg  [26:0] resv_line;
    wire        resv_ok = resv_valid && (resv_line == req_addr_r[31:5]);
    wire [31:0] old_word = q[word_sel*32 +: 32];
    wire [31:0] amo_new  = amo_apply(req_amo_r, old_word, req_wdata_r);
    wire [31:0] word_be  = 32'h0000_000F << {word_sel, 2'b00};

    // Store: byte lanes within the word, then the word within the line
    reg [3:0] st_mask;
    always @(*) begin
        case (req_mtype_r[1:0])
            2'b00:   st_mask = 4'b0001 << byte_off;
            2'b01:   st_mask = 4'b0011 << {byte_off[1], 1'b0};
            default: st_mask = 4'b1111;
        endcase
    end
    wire [31:0] st_lane = req_wdata_r << {byte_off, 3'b000};
    wire [31:0] st_be   = {28'd0, st_mask} << {word_sel, 2'b00};

    wire store_hit_ok = cache_hit && wr_eff && (hit_state == M || hit_state == E);
    wire sc_fail      = is_sc && !resv_ok;               // fails without bus traffic

    // ------------------------------------------------------------------
    // Next state, outputs and RAM write port
    // ------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        cpu_ack    = 1'b0;
        cpu_rdata  = 32'd0;
        bus_req    = 1'b0;
        bus_cmd    = `BUS_NONE;
        bus_addr   = 32'd0;
        bus_wdata  = q;                  // only used with BusFlush (the victim line)
        d_we = 1'b0; d_way = pend_way; d_be = 32'hFFFF_FFFF; d_wdata = bus_rdata;

        case (state)
            ST_IDLE:
                if (cpu_req) next_state = ST_COMPARE;

            ST_COMPARE:
                if (snoop_valid) begin
                    // A snoop is handled this cycle: look up again next cycle
                end else if (sc_fail) begin
                    cpu_ack    = 1'b1;
                    cpu_rdata  = 32'd1;
                    next_state = ST_IDLE;
                end else if (cache_hit && !wr_eff) begin
                    cpu_ack    = 1'b1;
                    cpu_rdata  = hit_word;
                    next_state = ST_IDLE;
                end else if (store_hit_ok) begin
                    cpu_ack    = 1'b1;
                    d_we       = 1'b1;
                    d_way      = hit_way;
                    if (is_rmw) begin
                        cpu_rdata = is_sc ? 32'd0 : old_word;
                        d_be      = word_be;
                        d_wdata   = {8{amo_new}};
                    end else begin
                        d_be      = st_be;
                        d_wdata   = {8{st_lane}};
                    end
                    next_state = ST_IDLE;
                end else if (cache_hit) begin
                    // Store to a Shared line
                    bus_req    = 1'b1;
                    bus_cmd    = `BUS_UPGR;
                    bus_addr   = line_addr;
                    next_state = ST_UPGRADE;
                end else if (vic_dirty) begin
                    next_state = ST_WB_READ;
                end else begin
                    bus_req    = 1'b1;
                    bus_cmd    = wr_eff ? `BUS_READX : `BUS_READ;
                    bus_addr   = line_addr;
                    next_state = ST_ALLOCATE;
                end

            ST_WB_READ:
                next_state = ST_WRITEBACK;

            ST_WRITEBACK: begin
                bus_req   = 1'b1;
                bus_cmd   = `BUS_FLUSH;
                bus_addr  = {pend_tag, idx, 5'b0};
                if (bus_ack) next_state = ST_WB_PAUSE;
            end

            ST_WB_PAUSE:
                next_state = ST_ALLOCATE;

            ST_ALLOCATE: begin
                bus_req  = 1'b1;
                bus_cmd  = wr_eff ? `BUS_READX : `BUS_READ;
                bus_addr = line_addr;
                if (bus_ack) begin
                    d_we       = 1'b1;           // whole line from the bus
                    next_state = ST_FILL_WAIT;
                end
            end

            ST_UPGRADE: begin
                // If a snoop took the line while we waited, fetch it again
                bus_req  = 1'b1;
                bus_cmd  = (pend_state == I) ? `BUS_READX : `BUS_UPGR;
                bus_addr = line_addr;
                if (bus_ack) begin
                    d_we       = (pend_state == I);
                    next_state = ST_FILL_WAIT;
                end
            end

            ST_FILL_WAIT:
                next_state = ST_COMPARE;

            default: next_state = ST_IDLE;
        endcase
    end

    // Tag write on a line fill
    wire t_we = d_we && (state == ST_ALLOCATE || state == ST_UPGRADE);
    always @(posedge clk) begin
        if (t_we && !pend_way) tag0[idx] <= tag;
        if (t_we &&  pend_way) tag1[idx] <= tag;
    end

    // ------------------------------------------------------------------
    // State and LRU write ports: one for the CPU side, one for snoops.
    // (Two explicit ports with per-entry decode, instead of several
    // variable-index writes, keep this small in synthesis.)
    // ------------------------------------------------------------------
    reg        snoop_done_r;
    reg [31:0] last_snoop_addr;
    reg [2:0]  last_snoop_cmd;
    wire       snoop_new = snoop_valid &&
                           (!snoop_done_r || (snoop_addr != last_snoop_addr) || (snoop_cmd != last_snoop_cmd));

    reg       c_st_we, c_st_way, lru_we, lru_val;
    reg [1:0] c_st_val;
    always @(*) begin
        c_st_we = 1'b0; c_st_way = pend_way; c_st_val = M;
        lru_we  = 1'b0; lru_val  = ~pend_way;
        case (state)
            ST_COMPARE:
                if (!snoop_valid && !sc_fail && cache_hit && (!wr_eff || store_hit_ok)) begin
                    lru_we = 1'b1; lru_val = ~hit_way;
                    if (wr_eff) begin c_st_we = 1'b1; c_st_way = hit_way; c_st_val = M; end
                end
            ST_WRITEBACK:
                if (bus_ack) begin c_st_we = 1'b1; c_st_val = I; end
            ST_ALLOCATE:
                if (bus_ack) begin
                    c_st_we = 1'b1; lru_we = 1'b1;
`ifdef CFG_MSI
                    // Measurement build (scripts/ablation.sh): MSI, a line read
                    // with no other holder is Shared, so a later store needs
                    // a BusUpgr
                    c_st_val = wr_eff ? M : S;
`else
                    c_st_val = wr_eff ? M : ((bus_shared === 1'b1) ? S : E);
`endif
                end
            ST_UPGRADE:
                if (bus_ack) begin c_st_we = 1'b1; lru_we = 1'b1; c_st_val = M; end
            default: ;
        endcase
    end

    reg       s_st_we;
    reg [1:0] s_st_val;
    always @(*) begin
        s_st_we = 1'b0; s_st_val = I;
        if (snoop_new && snoop_hit)
            case (snoop_cmd)
                `BUS_READ:                       begin s_st_we = 1'b1; s_st_val = S; end
                `BUS_READX, `BUS_UPGR, `BUS_INVAL: begin s_st_we = 1'b1; s_st_val = I; end
                default: ;
            endcase
    end

    wire [IDX_BITS:0] c_st_entry = {c_st_way, idx};
    wire [IDX_BITS:0] s_st_entry = {snoop_way, s_idx};
    integer e;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_bits <= {4*SETS{1'b0}};       // all Invalid
            lru_bits   <= {SETS{1'b0}};
        end else begin
            for (e = 0; e < 2*SETS; e = e + 1) begin
                if (s_st_we && s_st_entry == e)      state_bits[2*e +: 2] <= s_st_val;
                else if (c_st_we && c_st_entry == e) state_bits[2*e +: 2] <= c_st_val;
            end
            for (e = 0; e < SETS; e = e + 1)
                if (lru_we && idx == e) lru_bits[e] <= lru_val;
        end
    end

    // ------------------------------------------------------------------
    // FSM state, request latch, snoop responses
    // ------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            req_addr_r       <= 32'd0;
            req_wdata_r      <= 32'd0;
            req_wr_r         <= 1'b0;
            req_amo_r        <= `AMO_NONE;
            resv_valid       <= 1'b0;
            resv_line        <= 27'd0;
            req_mtype_r      <= 3'd0;
            pend_way         <= 1'b0;
            snoop_resp       <= `SNOOP_NONE;
            snoop_data_valid <= 1'b0;
            snoop_done_r     <= 1'b0;
            last_snoop_addr  <= 32'd0;
            last_snoop_cmd   <= 3'd0;
        end else begin
            state <= next_state;

            if (state == ST_IDLE && cpu_req) begin
                req_addr_r  <= cpu_addr;
                req_wdata_r <= cpu_wdata;
                req_wr_r    <= cpu_wr;
                req_mtype_r <= cpu_mem_type;
                req_amo_r   <= cpu_amo;
            end

            // LR/SC reservation
            if (state == ST_COMPARE && !snoop_valid) begin
                if (is_lr && cache_hit) begin
                    resv_valid <= 1'b1;
                    resv_line  <= req_addr_r[31:5];
                end else if (is_sc && (sc_fail || store_hit_ok)) begin
                    resv_valid <= 1'b0;                     // SC done either way
                end
            end
            if (state == ST_ALLOCATE && bus_ack && req_addr_r[31:5] != resv_line)
                resv_valid <= 1'b0;                         // another line filled
            if (s_st_we && s_st_val == I && snoop_addr[31:5] == resv_line)
                resv_valid <= 1'b0;                         // line taken by another core

            if (state == ST_COMPARE && !snoop_valid && !sc_fail && !(cache_hit && (!wr_eff || store_hit_ok)))
                pend_way <= cache_hit ? hit_way : vic_way;     // upgrade or miss

            // Snoop response (valid in the cycle after snoop_valid)
            if (snoop_valid) begin
                if (snoop_new) begin
                    snoop_done_r     <= 1'b1;
                    last_snoop_addr  <= snoop_addr;
                    last_snoop_cmd   <= snoop_cmd;
                    snoop_resp       <= `SNOOP_NONE;
                    snoop_data_valid <= 1'b0;
                    if (snoop_hit)
                        case (snoop_cmd)
                            `BUS_READ: begin       // M and E holders keep a Shared copy
                                snoop_resp       <= (snoop_st == M) ? `SNOOP_HITM : `SNOOP_HIT;
                                snoop_data_valid <= 1'b1;
                            end
                            `BUS_READX: begin
                                snoop_resp       <= (snoop_st == M) ? `SNOOP_HITM : `SNOOP_HIT;
                                snoop_data_valid <= (snoop_st == M);
                            end
                            `BUS_UPGR, `BUS_INVAL:
                                snoop_resp <= `SNOOP_ACK;
                            default: ;
                        endcase
                end
            end else begin
                snoop_done_r     <= 1'b0;
                snoop_resp       <= `SNOOP_NONE;
                snoop_data_valid <= 1'b0;
            end
        end
    end

endmodule
