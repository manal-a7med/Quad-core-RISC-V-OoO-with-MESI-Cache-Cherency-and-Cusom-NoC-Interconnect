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

    // Result broadcast (loads return data via CDB)
    output reg         result_valid,
    output reg  [31:0] result_data,
    output reg  [5:0]  result_phys_rd,
    output reg  [3:0]  result_rob_idx,

    // Status and control
    output wire        lsq_full,
    input  wire        commit_store_en,
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

    reg [4:0]  count;
    reg [3:0]  free_slot;
    reg        free_found;
    assign lsq_full = !free_found;
    integer    fi;

    always @(*) begin
        free_slot  = 4'd0;
        free_found = 1'b0;
        for (fi = 0; fi < DEPTH; fi = fi + 1) begin
            if (!lsq_valid[fi] && !free_found) begin
                free_slot  = fi[3:0];
                free_found = 1'b1;
            end
        end
    end

    // ========================================================================
    // FSM for cache access
    // ========================================================================
    localparam [2:0]
        LSQ_IDLE      = 3'b000,
        LSQ_LOAD_REQ  = 3'b001,
        LSQ_LOAD_WAIT = 3'b010,
        LSQ_STORE_REQ = 3'b011,
        LSQ_STORE_WAIT= 3'b100;

    reg [2:0]  lsq_state;
    reg [3:0]  active_idx;

    // ========================================================================
    // Store-to-load forwarding check
    // ========================================================================
    reg        fwd_found;
    reg [31:0] fwd_data;
    integer    fwd_i;

    always @(*) begin
        fwd_found = 1'b0;
        fwd_data  = 32'd0;
        for (fwd_i = 0; fwd_i < DEPTH; fwd_i = fwd_i + 1) begin
            if (lsq_valid[fwd_i] && lsq_is_store[fwd_i] &&
                lsq_addr[fwd_i][31:2] == addr[31:2] && enqueue_en && is_load) begin
                fwd_found = 1'b1;
                fwd_data  = lsq_data[fwd_i];
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

    always @(*) begin
        next_load_found    = 1'b0;
        next_load_idx      = 4'd0;
        next_store_found   = 1'b0;
        next_store_idx     = 4'd0;
        uncomm_store_found = 1'b0;
        uncomm_store_idx   = 4'd0;
        for (nl_i = 0; nl_i < DEPTH; nl_i = nl_i + 1) begin
            if (lsq_valid[nl_i] && lsq_is_load[nl_i] && !lsq_completed[nl_i] && !next_load_found) begin
                next_load_idx   = nl_i[3:0];
                next_load_found = 1'b1;
            end
            if (lsq_valid[nl_i] && lsq_is_store[nl_i] && lsq_committed[nl_i] && !lsq_completed[nl_i] && !next_store_found) begin
                next_store_idx   = nl_i[3:0];
                next_store_found = 1'b1;
            end
            if (lsq_valid[nl_i] && lsq_is_store[nl_i] && !lsq_committed[nl_i] && !uncomm_store_found) begin
                uncomm_store_idx   = nl_i[3:0];
                uncomm_store_found = 1'b1;
            end
        end
    end

    // ========================================================================
    // Main Logic
    // ========================================================================
    integer k;
    wire do_alloc = enqueue_en && !lsq_full && free_found && !(is_load && fwd_found);
    wire do_free  = ((lsq_state == LSQ_LOAD_WAIT) || (lsq_state == LSQ_STORE_WAIT)) && dcache_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count        <= 5'd0;
            lsq_state    <= LSQ_IDLE;
            dcache_req   <= 1'b0;
            dcache_wr    <= 1'b0;
            result_valid <= 1'b0;
            for (k = 0; k < DEPTH; k = k + 1) begin
                lsq_valid[k]     <= 1'b0;
                lsq_completed[k] <= 1'b0;
                lsq_committed[k] <= 1'b0;
            end
        end else if (flush) begin
            result_valid <= 1'b0;
            for (k = 0; k < DEPTH; k = k + 1) begin
                if (!lsq_committed[k]) begin
                    lsq_valid[k]     <= 1'b0;
                    lsq_completed[k] <= 1'b0;
                end
            end
        end else begin
            result_valid <= 1'b0;

            // -----------------------------------------------------------------
            // Enqueue new load/store
            // -----------------------------------------------------------------
            if (enqueue_en && !lsq_full) begin
                if (is_load && fwd_found) begin
                    // Forwarded load completes immediately without occupying slot
                    result_valid   <= 1'b1;
                    result_data    <= fwd_data;
                    result_phys_rd <= phys_rd;
                    result_rob_idx <= rob_idx;
                end else if (free_found) begin
                    lsq_valid[free_slot]     <= 1'b1;
                    lsq_is_load[free_slot]   <= is_load;
                    lsq_is_store[free_slot]  <= is_store;
                    lsq_addr[free_slot]      <= addr;
                    lsq_data[free_slot]      <= store_data;
                    lsq_mem_type[free_slot]  <= mem_type;
                    lsq_rob_idx[free_slot]   <= rob_idx;
                    lsq_phys_rd[free_slot]   <= phys_rd;
                    lsq_completed[free_slot] <= 1'b0;
                    lsq_committed[free_slot] <= 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // Mark store as committed (safe to write to cache)
            // -----------------------------------------------------------------
            if (commit_store_en && uncomm_store_found) begin
                lsq_committed[uncomm_store_idx] <= 1'b1;
            end

            // -----------------------------------------------------------------
            // Cache access FSM
            // -----------------------------------------------------------------
            case (lsq_state)
                LSQ_IDLE: begin
                    dcache_req <= 1'b0;
                    if (next_store_found) begin
                        lsq_state       <= LSQ_STORE_REQ;
                        active_idx      <= next_store_idx;
                        dcache_addr     <= lsq_addr[next_store_idx];
                        dcache_wdata    <= lsq_data[next_store_idx];
                        dcache_req      <= 1'b1;
                        dcache_wr       <= 1'b1;
                        dcache_mem_type <= lsq_mem_type[next_store_idx];
                    end else if (next_load_found) begin
                        lsq_state       <= LSQ_LOAD_REQ;
                        active_idx      <= next_load_idx;
                        dcache_addr     <= lsq_addr[next_load_idx];
                        dcache_req      <= 1'b1;
                        dcache_wr       <= 1'b0;
                        dcache_mem_type <= lsq_mem_type[next_load_idx];
                    end
                end

                LSQ_LOAD_REQ: begin
                    lsq_state <= LSQ_LOAD_WAIT;
                end

                LSQ_LOAD_WAIT: begin
                    if (dcache_ack) begin
                        dcache_req            <= 1'b0;
                        lsq_state             <= LSQ_IDLE;
                        lsq_completed[active_idx] <= 1'b1;
                        lsq_valid[active_idx]     <= 1'b0;

                        result_valid   <= 1'b1;
                        result_phys_rd <= lsq_phys_rd[active_idx];
                        result_rob_idx <= lsq_rob_idx[active_idx];

                        case (lsq_mem_type[active_idx])
                            `MEM_BYTE:   result_data <= {{24{dcache_rdata[7]}}, dcache_rdata[7:0]};
                            `MEM_HALF:   result_data <= {{16{dcache_rdata[15]}}, dcache_rdata[15:0]};
                            `MEM_WORD:   result_data <= dcache_rdata;
                            `MEM_BYTE_U: result_data <= {24'd0, dcache_rdata[7:0]};
                            `MEM_HALF_U: result_data <= {16'd0, dcache_rdata[15:0]};
                            default:     result_data <= dcache_rdata;
                        endcase
                    end
                end

                LSQ_STORE_REQ: begin
                    lsq_state <= LSQ_STORE_WAIT;
                end

                LSQ_STORE_WAIT: begin
                    if (dcache_ack) begin
                        dcache_req                <= 1'b0;
                        lsq_state                 <= LSQ_IDLE;
                        lsq_completed[active_idx] <= 1'b1;
                        lsq_valid[active_idx]     <= 1'b0;
                    end
                end

                default: lsq_state <= LSQ_IDLE;
            endcase

            case ({do_alloc, do_free})
                2'b10: count <= count + 5'd1;
                2'b01: count <= count - 5'd1;
                default: count <= count;
            endcase
        end
    end

endmodule
