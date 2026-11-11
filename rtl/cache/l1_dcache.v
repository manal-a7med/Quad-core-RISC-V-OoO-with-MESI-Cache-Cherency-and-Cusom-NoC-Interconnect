`timescale 1ns / 1ps
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
    output reg  [255:0] snoop_data,
    output reg          snoop_data_valid
);

    // 4KB, 2-way -> 64 sets, 32 bytes/line
    localparam CACHE_SETS = 64;
    localparam TAG_BITS   = 21;
    localparam INDEX_BITS = 6;
    localparam WAYS       = 2;

    // Cache Arrays
    reg [255:0]        data_array  [0:WAYS-1][0:CACHE_SETS-1];
    reg [TAG_BITS-1:0] tag_array   [0:WAYS-1][0:CACHE_SETS-1];
    reg [1:0]          state_array [0:WAYS-1][0:CACHE_SETS-1]; // MESI state
    reg                lru_array   [0:CACHE_SETS-1];

    // FSM States
    localparam STATE_IDLE          = 3'd0;
    localparam STATE_COMPARE_TAG   = 3'd1;
    localparam STATE_WRITEBACK     = 3'd2;
    localparam STATE_ALLOCATE      = 3'd3;
    localparam STATE_SNOOP_CHECK   = 3'd4;
    localparam STATE_SNOOP_RESPOND = 3'd5;
    localparam STATE_WB_PAUSE      = 3'd6;
    localparam STATE_UPGRADE       = 3'd7;

    reg [2:0]  state, next_state;

    // Latched CPU request for multi-cycle miss handling
    reg [31:0] req_addr_r;
    reg [31:0] req_wdata_r;
    reg        req_wr_r;
    reg [2:0]  req_mtype_r;
    reg        pend_way;

    wire [31:0] eff_addr  = (state == STATE_IDLE || cpu_req) ? cpu_addr     : req_addr_r;
    wire [31:0] eff_wdata = (state == STATE_IDLE || cpu_req) ? cpu_wdata    : req_wdata_r;
    wire        eff_wr    = (state == STATE_IDLE || cpu_req) ? cpu_wr       : req_wr_r;
    wire [2:0]  eff_mtype = (state == STATE_IDLE || cpu_req) ? cpu_mem_type : req_mtype_r;

    // Address decoding (CPU)
    wire [INDEX_BITS-1:0] index     = eff_addr[10:5];
    wire [TAG_BITS-1:0]   tag       = eff_addr[31:11];
    wire [2:0]            word_sel  = eff_addr[4:2];
    wire [1:0]            byte_off  = eff_addr[1:0];

    // Hit detection (CPU)
    wire way0_valid = (state_array[0][index] != `MESI_INVALID);
    wire way1_valid = (state_array[1][index] != `MESI_INVALID);
    wire way0_hit   = way0_valid && (tag_array[0][index] == tag);
    wire way1_hit   = way1_valid && (tag_array[1][index] == tag);
    wire cache_hit  = way0_hit || way1_hit;
    wire hit_way    = way1_hit ? 1'b1 : 1'b0;
    wire [1:0] hit_state = state_array[hit_way][index];

    // Victim selection on miss
    wire vic_way = (!way0_valid) ? 1'b0 :
                   (!way1_valid) ? 1'b1 :
                                   lru_array[index];
    wire vic_dirty = (state_array[vic_way][index] == `MESI_MODIFIED);

    // Helper: merge a CPU store (word/half/byte) into a 256-bit cache line
    function [255:0] merge_write_line;
        input [255:0] orig_line;
        input [2:0]   w_sel;
        input [1:0]   b_off;
        input [2:0]   m_type;
        input [31:0]  w_data;
        reg   [255:0] tmp_line;
        reg   [31:0]  orig_word;
        reg   [31:0]  new_word;
        begin
            tmp_line  = orig_line;
            orig_word = orig_line[w_sel*32 +: 32];
            case (m_type)
                `MEM_BYTE: begin
                    new_word = orig_word;
                    new_word[b_off*8 +: 8] = w_data[7:0];
                end
                `MEM_HALF: begin
                    new_word = orig_word;
                    new_word[b_off[1]*16 +: 16] = w_data[15:0];
                end
                default: begin
                    new_word = w_data;
                end
            endcase
            tmp_line[w_sel*32 +: 32] = new_word;
            merge_write_line = tmp_line;
        end
    endfunction

    // Snoop decoding
    wire [INDEX_BITS-1:0] snoop_index = snoop_addr[10:5];
    wire [TAG_BITS-1:0]   snoop_tag   = snoop_addr[31:11];
    wire snoop_w0_hit = (state_array[0][snoop_index] != `MESI_INVALID) && (tag_array[0][snoop_index] == snoop_tag);
    wire snoop_w1_hit = (state_array[1][snoop_index] != `MESI_INVALID) && (tag_array[1][snoop_index] == snoop_tag);
    wire snoop_hit    = snoop_w0_hit || snoop_w1_hit;
    wire snoop_way    = snoop_w1_hit ? 1'b1 : 1'b0;
    wire [1:0] snoop_st = state_array[snoop_way][snoop_index];

    reg        snoop_done_r;
    reg [31:0] last_snoop_addr;
    reg [2:0]  last_snoop_cmd;

    wire [255:0] hit_line = data_array[hit_way][index];
    wire [31:0]  hit_word = hit_line[word_sel*32 +: 32] >> (byte_off * 8);

    // Combinational FSM and outputs
    always @(*) begin
        next_state = state;
        cpu_ack    = 1'b0;
        cpu_rdata  = 32'd0;
        bus_req    = 1'b0;
        bus_cmd    = `BUS_NONE;
        bus_addr   = 32'd0;
        bus_wdata  = 256'd0;

        case (state)
            STATE_IDLE: begin
                if (cpu_req) begin
                    next_state = STATE_COMPARE_TAG;
                end
            end

            STATE_COMPARE_TAG: begin
                if (cache_hit) begin
                    if (!eff_wr) begin
                        // Read Hit (M, E, or S)
                        cpu_ack   = 1'b1;
                        cpu_rdata = hit_word;
                        if (!cpu_req)
                            next_state = STATE_IDLE;
                        else
                            next_state = STATE_COMPARE_TAG;
                    end else begin
                        // Write Hit
                        if (hit_state == `MESI_MODIFIED || hit_state == `MESI_EXCLUSIVE) begin
                            cpu_ack   = 1'b1;
                            cpu_rdata = 32'd0;
                            if (!cpu_req)
                                next_state = STATE_IDLE;
                            else
                                next_state = STATE_COMPARE_TAG;
                        end else begin
                            // Shared -> Modified requires BusUpgr
                            bus_req    = 1'b1;
                            bus_cmd    = `BUS_UPGR;
                            bus_addr   = {eff_addr[31:5], 5'b0};
                            next_state = STATE_UPGRADE;
                        end
                    end
                end else begin
                    // Cache Miss
                    if (vic_dirty) begin
                        bus_req    = 1'b1;
                        bus_cmd    = `BUS_FLUSH;
                        bus_addr   = {tag_array[vic_way][index], index, 5'b0};
                        bus_wdata  = data_array[vic_way][index];
                        next_state = STATE_WRITEBACK;
                    end else begin
                        bus_req    = 1'b1;
                        bus_cmd    = eff_wr ? `BUS_READX : `BUS_READ;
                        bus_addr   = {eff_addr[31:5], 5'b0};
                        next_state = STATE_ALLOCATE;
                    end
                end
            end

            STATE_WRITEBACK: begin
                bus_req   = 1'b1;
                bus_cmd   = `BUS_FLUSH;
                bus_addr  = {tag_array[pend_way][index], index, 5'b0};
                bus_wdata = data_array[pend_way][index];
                if (bus_ack) begin
                    next_state = STATE_WB_PAUSE;
                end
            end

            STATE_WB_PAUSE: begin
                bus_req    = 1'b0;
                next_state = STATE_ALLOCATE;
            end

            STATE_ALLOCATE: begin
                bus_req  = 1'b1;
                bus_cmd  = eff_wr ? `BUS_READX : `BUS_READ;
                bus_addr = {eff_addr[31:5], 5'b0};
                if (bus_ack) begin
                    next_state = STATE_COMPARE_TAG;
                end
            end

            STATE_UPGRADE: begin
                bus_req  = 1'b1;
                bus_cmd  = (state_array[pend_way][index] == `MESI_INVALID) ? `BUS_READX : `BUS_UPGR;
                bus_addr = {eff_addr[31:5], 5'b0};
                if (bus_ack) begin
                    next_state = STATE_COMPARE_TAG;
                end
            end

            default: next_state = STATE_IDLE;
        endcase
    end

    integer s, w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= STATE_IDLE;
            req_addr_r       <= 32'd0;
            req_wdata_r      <= 32'd0;
            req_wr_r         <= 1'b0;
            req_mtype_r      <= 3'd0;
            pend_way         <= 1'b0;
            snoop_resp       <= `SNOOP_NONE;
            snoop_data       <= 256'd0;
            snoop_data_valid <= 1'b0;
            snoop_done_r     <= 1'b0;
            last_snoop_addr  <= 32'd0;
            last_snoop_cmd   <= 3'd0;
            for (s = 0; s < CACHE_SETS; s = s + 1) begin
                lru_array[s] <= 1'b0;
                for (w = 0; w < WAYS; w = w + 1) begin
                    state_array[w][s] <= `MESI_INVALID;
                    tag_array[w][s]   <= {TAG_BITS{1'b0}};
                    data_array[w][s]  <= 256'd0;
                end
            end
        end else begin
            state <= next_state;

            // Latch request on entry or when cpu_req is active
            if (state == STATE_IDLE && cpu_req) begin
                req_addr_r  <= cpu_addr;
                req_wdata_r <= cpu_wdata;
                req_wr_r    <= cpu_wr;
                req_mtype_r <= cpu_mem_type;
            end

            // CPU cache array updates
            if (state == STATE_COMPARE_TAG) begin
                if (cache_hit) begin
                    if (!eff_wr) begin
                        lru_array[index] <= ~hit_way;
                    end else if (hit_state == `MESI_MODIFIED || hit_state == `MESI_EXCLUSIVE) begin
                        data_array[hit_way][index]  <= merge_write_line(data_array[hit_way][index], word_sel, byte_off, eff_mtype, eff_wdata);
                        state_array[hit_way][index] <= `MESI_MODIFIED;
                        lru_array[index]            <= ~hit_way;
                    end else begin
                        pend_way <= hit_way;
                        snoop_resp       <= `SNOOP_NONE;
                        snoop_data_valid <= 1'b0;
                    end
                end else begin
                    pend_way <= vic_way;
                    snoop_resp       <= `SNOOP_NONE;
                    snoop_data_valid <= 1'b0;
                end
            end else if (state == STATE_WRITEBACK && bus_ack) begin
                state_array[pend_way][index] <= `MESI_INVALID;
            end else if (state == STATE_ALLOCATE && bus_ack) begin
                tag_array[pend_way][index] <= tag;
                lru_array[index]           <= ~pend_way;
                if (eff_wr) begin
                    data_array[pend_way][index]  <= merge_write_line(bus_rdata, word_sel, byte_off, eff_mtype, eff_wdata);
                    state_array[pend_way][index] <= `MESI_MODIFIED;
                end else begin
                    data_array[pend_way][index]  <= bus_rdata;
                    state_array[pend_way][index] <= (bus_shared === 1'b1) ? `MESI_SHARED : `MESI_EXCLUSIVE;
                end
            end else if (state == STATE_UPGRADE && bus_ack) begin
                lru_array[index] <= ~pend_way;
                if (state_array[pend_way][index] == `MESI_INVALID) begin
                    tag_array[pend_way][index]  <= tag;
                    data_array[pend_way][index] <= merge_write_line(bus_rdata, word_sel, byte_off, eff_mtype, eff_wdata);
                end else begin
                    data_array[pend_way][index] <= merge_write_line(data_array[pend_way][index], word_sel, byte_off, eff_mtype, eff_wdata);
                end
                state_array[pend_way][index] <= `MESI_MODIFIED;
            end

            // Snoop handling (can happen in parallel with CPU waiting for bus grant)
            if (snoop_valid) begin
                if (!snoop_done_r || (snoop_addr != last_snoop_addr) || (snoop_cmd != last_snoop_cmd)) begin
                    snoop_done_r    <= 1'b1;
                    last_snoop_addr <= snoop_addr;
                    last_snoop_cmd  <= snoop_cmd;

                    if (!snoop_hit) begin
                        snoop_resp       <= `SNOOP_NONE;
                        snoop_data       <= 256'd0;
                        snoop_data_valid <= 1'b0;
                    end else begin
                        case (snoop_cmd)
                            `BUS_READ: begin
                                if (snoop_st == `MESI_MODIFIED) begin
                                    snoop_resp       <= `SNOOP_HITM;
                                    snoop_data       <= data_array[snoop_way][snoop_index];
                                    snoop_data_valid <= 1'b1;
                                    state_array[snoop_way][snoop_index] <= `MESI_SHARED;
                                end else begin
                                    snoop_resp       <= `SNOOP_HIT;
                                    snoop_data       <= data_array[snoop_way][snoop_index];
                                    snoop_data_valid <= 1'b1;
                                    state_array[snoop_way][snoop_index] <= `MESI_SHARED;
                                end
                            end

                            `BUS_READX: begin
                                if (snoop_st == `MESI_MODIFIED) begin
                                    snoop_resp       <= `SNOOP_HITM;
                                    snoop_data       <= data_array[snoop_way][snoop_index];
                                    snoop_data_valid <= 1'b1;
                                    state_array[snoop_way][snoop_index] <= `MESI_INVALID;
                                end else begin
                                    snoop_resp       <= `SNOOP_HIT;
                                    snoop_data       <= data_array[snoop_way][snoop_index];
                                    snoop_data_valid <= 1'b0;
                                    state_array[snoop_way][snoop_index] <= `MESI_INVALID;
                                end
                            end

                            `BUS_UPGR, `BUS_INVAL: begin
                                snoop_resp       <= `SNOOP_ACK;
                                snoop_data       <= 256'd0;
                                snoop_data_valid <= 1'b0;
                                state_array[snoop_way][snoop_index] <= `MESI_INVALID;
                            end

                            default: begin
                                snoop_resp       <= `SNOOP_NONE;
                                snoop_data       <= 256'd0;
                                snoop_data_valid <= 1'b0;
                            end
                        endcase
                    end
                end
            end else begin
                snoop_done_r <= 1'b0;
            end
        end
    end

endmodule
