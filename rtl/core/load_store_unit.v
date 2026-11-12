`timescale 1ns / 1ps
// ============================================================================
// load_store_unit.v — Load/Store Queue (LSQ)
// ============================================================================
// Manages memory operations with a queue, store-to-load forwarding,
// and ordered store commit. Interfaces with the L1 data cache.
// ============================================================================

`include "common_defs.vh"

module load_store_unit (
    input  wire        clk,
    input  wire        rst_n,

    // Enqueue interface (from issue stage)
    input  wire        enqueue_en,
    input  wire        is_load,
    input  wire        is_store,
    input  wire [31:0] addr,
    input  wire [31:0] store_data,
    input  wire [2:0]  mem_type,
    input  wire [3:0]  amo_op,           // nonzero: atomic (enqueued as a load)
    input  wire [3:0]  rob_idx,
    input  wire [5:0]  phys_rd,

    // Data cache interface
    output reg  [31:0] dcache_addr,
    output reg  [31:0] dcache_wdata,
    input  wire [31:0] dcache_rdata,
    output reg         dcache_req,
    output reg         dcache_wr,
    input  wire        dcache_ack,
    output reg  [2:0]  dcache_mem_type,
    output reg  [3:0]  dcache_amo,

    // Result broadcast (loads return data via CDB). A result is shown until
    // the core takes it (result_accept): the core's result bus gives way to
    // the instruction executing that cycle.
    output wire        result_valid,
    output wire [31:0] result_data,
    output wire [5:0]  result_phys_rd,
    output wire [3:0]  result_rob_idx,
    input  wire        result_accept,

    // Status and control
    output wire        lsq_full,
    output wire        lsq_empty,        // no load or store in the queue (committed stores have all reached the cache)
    output wire        lsq_ready,        // a load/store selected for issue this cycle will find a slot
    input  wire        commit_store_en,
    input  wire [3:0]  commit_rob_idx,   // ROB index of the committing store
    input  wire [3:0]  rob_head,         // program-order age reference
    input  wire        flush
);

    // ========================================================================
    // LSQ Entry Fields
    // ========================================================================
    localparam DEPTH = `LSQ_DEPTH;

    reg        lsq_valid      [0:DEPTH-1];
    reg        lsq_is_load    [0:DEPTH-1];
    reg        lsq_is_store   [0:DEPTH-1];
    reg [31:0] lsq_addr       [0:DEPTH-1];
    reg [31:0] lsq_data       [0:DEPTH-1];
    reg [2:0]  lsq_mem_type   [0:DEPTH-1];
    reg [3:0]  lsq_rob_idx    [0:DEPTH-1];
    reg [5:0]  lsq_phys_rd    [0:DEPTH-1];
    reg        lsq_completed  [0:DEPTH-1];
    reg        lsq_committed  [0:DEPTH-1]; // Stores: ready to write cache
    reg [3:0]  lsq_amo        [0:DEPTH-1]; // Atomics: AMO code (always go to the cache)

    reg [3:0]  free_slot;
    reg        free_found;
    reg        free_two;                   // at least two free slots
    assign lsq_full = !free_found;
    // The issue queue registers its choice, so an instruction it selects now
    // arrives here next cycle, after the one arriving this cycle (if any) has
    // taken its slot. Without this the queue could be handed a store with no
    // slot left and the store was lost (the ROB still marked it complete).
    assign lsq_ready = free_two || (free_found && !enqueue_en);
    integer    fi;
    reg        any_valid;
    assign lsq_empty = !any_valid;

    always @(*) begin
        free_slot  = 4'd0;
        free_found = 1'b0;
        free_two   = 1'b0;
        any_valid  = 1'b0;
        for (fi = 0; fi < DEPTH; fi = fi + 1) begin
            if (lsq_valid[fi]) any_valid = 1'b1;
            if (!lsq_valid[fi]) begin
                if (free_found) free_two = 1'b1;
                else begin
                    free_slot  = fi[3:0];
                    free_found = 1'b1;
                end
            end
        end
    end

    // ========================================================================
    // FSM for cache access
    // ========================================================================
    // One access is at the cache at a time. When it is answered the next one
    // is sent in the same cycle, so the cache sees requests back to back.
    localparam [1:0]
        LSQ_IDLE  = 2'd0,
        LSQ_LOAD  = 2'd1,     // a load (or atomic) is at the cache
        LSQ_STORE = 2'd2;     // a committed store is at the cache

    reg [1:0]  lsq_state;
    wire       ld_done    = (lsq_state == LSQ_LOAD)  && dcache_ack;
    wire       st_done    = (lsq_state == LSQ_STORE) && dcache_ack;
    wire       can_launch = (lsq_state == LSQ_IDLE) || ld_done || st_done;
    reg [3:0]  active_idx;

    // Results waiting for the core: one holder for loads answered by the
    // cache and one for forwarded loads, so neither overwrites the other.
    // (The cache path cannot produce a second result before the first is
    // taken: the core takes a result at the latest in the cycle after it
    // appears, and the next access is answered two cycles after this one at
    // the earliest. A simulation check below guards that.)
    reg        ld_res_valid, fw_res_valid;
    reg [31:0] ld_res_data,  fw_res_data;
    reg [5:0]  ld_res_phys,  fw_res_phys;
    reg [3:0]  ld_res_rob,   fw_res_rob;
    assign result_valid   = ld_res_valid || fw_res_valid;
    assign result_data    = ld_res_valid ? ld_res_data : fw_res_data;
    assign result_phys_rd = ld_res_valid ? ld_res_phys : fw_res_phys;
    assign result_rob_idx = ld_res_valid ? ld_res_rob  : fw_res_rob;

    // ========================================================================
    // Byte-accurate, age-aware store-to-load forwarding
    // ========================================================================
    // Only stores OLDER than the load (committed, or earlier in ROB order)
    // are considered. A load forwards only when exactly one older store
    // overlaps it and that store covers every byte the load reads; any other
    // overlap makes the load wait in the LSQ until the store reaches the cache.

    function [3:0] byte_mask(input [2:0] mt, input [1:0] off);
        case (mt)
            `MEM_BYTE, `MEM_BYTE_U: byte_mask = 4'b0001 << off;
            `MEM_HALF, `MEM_HALF_U: byte_mask = 4'b0011 << {off[1], 1'b0};
            default:                byte_mask = 4'b1111;
        endcase
    endfunction

    function [31:0] extend(input [2:0] mt, input [31:0] d);
        case (mt)
            `MEM_BYTE:   extend = {{24{d[7]}},  d[7:0]};
            `MEM_HALF:   extend = {{16{d[15]}}, d[15:0]};
            `MEM_BYTE_U: extend = {24'd0, d[7:0]};
            `MEM_HALF_U: extend = {16'd0, d[15:0]};
            default:     extend = d;
        endcase
    endfunction

    // (Everything is passed in: always @(*) does not see signals that a
    // function reads from the enclosing module.)
    function [3:0] rel_age(input [3:0] idx, input [3:0] head);
        rel_age = idx - head;
    endfunction

    // Is a store (committed flag, ROB index) older than a load with ROB index lrob?
    function store_older(input committed, input [3:0] srob, input [3:0] lrob, input [3:0] head);
        store_older = committed || (rel_age(srob, head) < rel_age(lrob, head));
    endfunction

    reg        fwd_found;
    reg [31:0] fwd_data;
    reg [2:0]  fwd_hits;
    reg [31:0] fwd_lane;
    integer    fwd_i;
    wire [3:0] ld_mask = byte_mask(mem_type, addr[1:0]);

    always @(*) begin
        fwd_found = 1'b0;
        fwd_data  = 32'd0;
        fwd_hits  = 3'd0;
        fwd_lane  = 32'd0;
        for (fwd_i = 0; fwd_i < DEPTH; fwd_i = fwd_i + 1) begin
            // An older load of the same bytes still waiting in the LSQ also
            // counts as a hit, so this load does not forward and stays behind
            // it (it may read a newer value than the store holds).
            if (enqueue_en && is_load && lsq_valid[fwd_i] && !lsq_completed[fwd_i] &&
                (lsq_is_store[fwd_i] || lsq_is_load[fwd_i]) &&
                store_older(lsq_committed[fwd_i], lsq_rob_idx[fwd_i], rob_idx, rob_head) &&
                lsq_addr[fwd_i][31:2] == addr[31:2] &&
                |(byte_mask(lsq_mem_type[fwd_i], lsq_addr[fwd_i][1:0]) & ld_mask)) begin
                fwd_hits = fwd_hits + 3'd1;
                if (lsq_is_store[fwd_i] &&
                    (byte_mask(lsq_mem_type[fwd_i], lsq_addr[fwd_i][1:0]) & ld_mask) == ld_mask) begin
                    fwd_found = 1'b1;
                    fwd_lane  = lsq_data[fwd_i] << {lsq_addr[fwd_i][1:0], 3'b000};
                end
            end
        end
        if (fwd_hits != 3'd1) fwd_found = 1'b0;
        fwd_data = extend(mem_type, fwd_lane >> {addr[1:0], 3'b000});
    end

    // A queued load is blocked while any older overlapping store is still
    // waiting to be written to the cache, or while an older load of any of
    // the same bytes has not been performed yet (loads of the same bytes are
    // performed in program order: RVWMO, CoRR).
    // The entry whose access is answered this cycle has been performed and
    // blocks nothing any more. (Not if it was a squashed load: its slot may
    // already hold a new entry.)
    reg        active_squashed;  // in-flight load was flushed: drop its result
    wire       done_now = st_done || (ld_done && !active_squashed);
    reg        ld_blocked [0:DEPTH-1];
    integer    bi, bj;
    always @(*) begin
        for (bi = 0; bi < DEPTH; bi = bi + 1) begin
            ld_blocked[bi] = 1'b0;
            for (bj = 0; bj < DEPTH; bj = bj + 1) begin
                if (lsq_valid[bj] && (lsq_is_store[bj] || lsq_is_load[bj]) && !lsq_completed[bj] &&
                    !(done_now && bj[3:0] == active_idx) &&
                    store_older(lsq_committed[bj], lsq_rob_idx[bj], lsq_rob_idx[bi], rob_head) &&
                    lsq_addr[bj][31:2] == lsq_addr[bi][31:2] &&
                    |(byte_mask(lsq_mem_type[bj], lsq_addr[bj][1:0]) &
                      byte_mask(lsq_mem_type[bi], lsq_addr[bi][1:0])))
                    ld_blocked[bi] = 1'b1;
            end
        end
    end

    // ========================================================================
    // Find next load to execute or committed store to write
    // ========================================================================
    reg [3:0]  next_load_idx;
    reg        next_load_found;
    reg [3:0]  next_store_idx;
    reg        next_store_found;
    reg [3:0]  uncomm_store_idx;
    reg        uncomm_store_found;
    integer    nl_i;

    // FIFO of committed stores (LSQ slot numbers) in commit order. Stores must
    // reach memory in program order: same-address order for one core, and the
    // order other cores and I/O devices observe (data before flag, UART bytes).
    reg [3:0]  sq_fifo [0:DEPTH-1];
    reg [2:0]  sq_head, sq_tail;
    reg [3:0]  sq_count;

    always @(*) begin
        next_load_found    = 1'b0;
        next_load_idx      = 4'd0;
        next_store_found   = 1'b0;
        next_store_idx     = 4'd0;
        uncomm_store_found = 1'b0;
        uncomm_store_idx   = 4'd0;
        // Committed stores are written in commit (program) order: oldest first
        // (not counting the one being answered this cycle)
        if (sq_count != (st_done ? 4'd1 : 4'd0)) begin
            next_store_idx   = sq_fifo[st_done ? sq_head + 3'd1 : sq_head];
            next_store_found = 1'b1;
        end
        for (nl_i = 0; nl_i < DEPTH; nl_i = nl_i + 1) begin
            if (lsq_valid[nl_i] && lsq_is_load[nl_i] && !lsq_completed[nl_i] && !ld_blocked[nl_i] &&
                !(ld_done && nl_i[3:0] == active_idx) && !next_load_found) begin
                next_load_idx   = nl_i[3:0];
                next_load_found = 1'b1;
            end
            if (lsq_valid[nl_i] && lsq_is_store[nl_i] && !lsq_committed[nl_i] &&
                lsq_rob_idx[nl_i] == commit_rob_idx && !uncomm_store_found) begin
                uncomm_store_idx   = nl_i[3:0];
                uncomm_store_found = 1'b1;
            end
        end
    end

    // ========================================================================
    // Main Logic
    // ========================================================================
    integer k;
    // An atomic is never satisfied by forwarding: it must reach the cache.
    // A forwarded load needs the forwarding holder; if the previous forwarded
    // result is still waiting there, this load takes a queue slot instead and
    // reads the cache once the store has been written.
    wire fwd_use  = is_load && fwd_found && (amo_op == `AMO_NONE) && !fw_res_valid;
    // A load arriving from the issue queue goes to the cache at once when
    // nothing is waiting and no older load or store in the queue overlaps it
    // (it is written to its slot as usual and completed from there).
    wire direct_load = enqueue_en && !lsq_full && is_load && !fwd_use && (fwd_hits == 3'd0);

`ifdef SIM
    always @(posedge clk)
        if (rst_n && ld_done && !active_squashed && !flush && ld_res_valid && !result_accept)
            $display("ERROR load_store_unit: load result overwritten before the core took it");
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lsq_state    <= LSQ_IDLE;
            dcache_req   <= 1'b0;
            dcache_wr    <= 1'b0;
            dcache_amo   <= 4'd0;
            ld_res_valid <= 1'b0;
            fw_res_valid <= 1'b0;
            active_squashed <= 1'b0;
            sq_head      <= 3'd0;
            sq_tail      <= 3'd0;
            sq_count     <= 4'd0;
            for (k = 0; k < DEPTH; k = k + 1) begin
                lsq_valid[k]     <= 1'b0;
                lsq_completed[k] <= 1'b0;
                lsq_committed[k] <= 1'b0;
            end
        end else begin
            if (result_accept) begin
                if (ld_res_valid) ld_res_valid <= 1'b0;
                else              fw_res_valid <= 1'b0;
            end

          if (flush) begin
            // Results still waiting belong to squashed instructions
            ld_res_valid <= 1'b0;
            fw_res_valid <= 1'b0;
            // A load already sent to the cache must finish its handshake, but
            // its result belongs to a squashed instruction and must not reach
            // the CDB (its physical register may already be reallocated).
            if (lsq_state == LSQ_LOAD)
                active_squashed <= 1'b1;
            for (k = 0; k < DEPTH; k = k + 1) begin
                if (!lsq_committed[k]) begin
                    lsq_valid[k]     <= 1'b0;
                    lsq_completed[k] <= 1'b0;
                end
            end
          end else begin
            // -----------------------------------------------------------------
            // Enqueue new load/store
            // -----------------------------------------------------------------
            if (enqueue_en && !lsq_full) begin
                if (fwd_use) begin
                    // Forwarded load completes immediately without occupying slot
                    fw_res_valid <= 1'b1;
                    fw_res_data  <= fwd_data;
                    fw_res_phys  <= phys_rd;
                    fw_res_rob   <= rob_idx;
                end else if (free_found) begin
                    lsq_valid[free_slot]     <= 1'b1;
                    lsq_is_load[free_slot]   <= is_load;
                    lsq_is_store[free_slot]  <= is_store;
                    lsq_addr[free_slot]      <= addr;
                    lsq_data[free_slot]      <= store_data;
                    lsq_mem_type[free_slot]  <= mem_type;
                    lsq_amo[free_slot]       <= amo_op;
                    lsq_rob_idx[free_slot]   <= rob_idx;
                    lsq_phys_rd[free_slot]   <= phys_rd;
                    lsq_completed[free_slot] <= 1'b0;
                    lsq_committed[free_slot] <= 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // Mark store as committed (safe to write to cache)
            // -----------------------------------------------------------------
            // (A flush never coincides with a store commit: only the
            // committing branch or trapping instruction flushes.)
            if (commit_store_en && uncomm_store_found) begin
                lsq_committed[uncomm_store_idx] <= 1'b1;
                sq_fifo[sq_tail] <= uncomm_store_idx;
                sq_tail          <= sq_tail + 3'd1;
            end
          end

            // -----------------------------------------------------------------
            // Cache access FSM. It also runs during a flush, so that a
            // one-cycle acknowledge (I/O) is never missed and an access is
            // never repeated; only new loads wait until the flush is over.
            // -----------------------------------------------------------------
            if (ld_done) begin
                if (!active_squashed && !flush) begin
                    // (If squashed, the flush already freed the slot and
                    // it may hold a new entry, so leave it alone.)
                    lsq_completed[active_idx] <= 1'b1;
                    lsq_valid[active_idx]     <= 1'b0;
                end
                ld_res_valid    <= !active_squashed && !flush;
                active_squashed <= 1'b0;
                ld_res_phys     <= lsq_phys_rd[active_idx];
                ld_res_rob      <= lsq_rob_idx[active_idx];
                ld_res_data     <= extend(lsq_mem_type[active_idx], dcache_rdata);
            end
            if (st_done) begin
                lsq_completed[active_idx] <= 1'b1;
                lsq_valid[active_idx]     <= 1'b0;
                sq_head                   <= sq_head + 3'd1;
            end

            if (can_launch) begin
                if (next_store_found) begin
                    lsq_state       <= LSQ_STORE;
                    active_idx      <= next_store_idx;
                    dcache_addr     <= lsq_addr[next_store_idx];
                    dcache_wdata    <= lsq_data[next_store_idx];
                    dcache_req      <= 1'b1;
                    dcache_wr       <= 1'b1;
                    dcache_mem_type <= lsq_mem_type[next_store_idx];
                    dcache_amo      <= `AMO_NONE;
                end else if (next_load_found && !flush) begin
                    lsq_state       <= LSQ_LOAD;
                    active_idx      <= next_load_idx;
                    dcache_addr     <= lsq_addr[next_load_idx];
                    dcache_req      <= 1'b1;
                    dcache_wr       <= 1'b0;
                    dcache_mem_type <= lsq_mem_type[next_load_idx];
                    dcache_amo      <= lsq_amo[next_load_idx];
                    dcache_wdata    <= lsq_data[next_load_idx];     // AMO operand
                end else if (direct_load && !flush) begin
                    lsq_state       <= LSQ_LOAD;
                    active_idx      <= free_slot;
                    dcache_addr     <= addr;
                    dcache_req      <= 1'b1;
                    dcache_wr       <= 1'b0;
                    dcache_mem_type <= mem_type;
                    dcache_amo      <= amo_op;
                    dcache_wdata    <= store_data;                  // AMO operand
                end else begin
                    lsq_state       <= LSQ_IDLE;
                    dcache_req      <= 1'b0;
                end
            end

            case ({commit_store_en && uncomm_store_found && !flush,
                   st_done})
                2'b10: sq_count <= sq_count + 4'd1;
                2'b01: sq_count <= sq_count - 4'd1;
                default: sq_count <= sq_count;
            endcase
        end
    end

endmodule
