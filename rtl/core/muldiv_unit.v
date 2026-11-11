`timescale 1ns / 1ps
// ============================================================================
// muldiv_unit.v - RV32M multiply / divide unit
// ============================================================================
// One operation at a time. The issue queue sends an M instruction only while
// the unit is idle (busy low); the result is shown until the core takes it
// (result_accept), like a load result.
//
//   MUL, MULH, MULHSU, MULHU   33 x 33 signed multiply (DSP blocks on the
//                              FPGA), registered: result two cycles after start
//   DIV, DIVU, REM, REMU       restoring division on magnitudes, one bit per
//                              cycle: result 34 cycles after start
//
// Division by zero gives quotient -1 (all ones) and remainder = dividend;
// signed overflow (-2^31 / -1) gives quotient -2^31 and remainder 0. Neither
// traps (RISC-V spec).
//
// A flush abandons the operation: flushes happen at commit, so whatever is in
// here is younger than the instruction that flushed.
// ============================================================================

module muldiv_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,

    input  wire        start,            // one cycle, only while !busy
    input  wire [2:0]  op,               // funct3
    input  wire [31:0] a,                // rs1
    input  wire [31:0] b,                // rs2
    input  wire [5:0]  phys_rd,
    input  wire [3:0]  rob_idx,
    output wire        busy,

    output reg         result_valid,
    output reg  [31:0] result_data,
    output reg  [5:0]  result_phys_rd,
    output reg  [3:0]  result_rob_idx,
    input  wire        result_accept
);

    localparam [1:0] IDLE = 2'd0, MUL = 2'd1, DIV = 2'd2, DONE = 2'd3;
    reg [1:0]  state;
    reg [2:0]  op_r;

    assign busy = (state != IDLE);

    // ---- multiply ----
    wire a_signed = (op == 3'd1) || (op == 3'd2);     // MULH, MULHSU
    wire b_signed = (op == 3'd1);                     // MULH
    reg  signed [65:0] product;

    // ---- divide ----
    wire        div_signed = (op == 3'd4) || (op == 3'd6);
    wire        a_neg      = div_signed && a[31];
    wire        b_neg      = div_signed && b[31];
    reg  [31:0] rem, quo, dvs;
    reg  [5:0]  count;
    reg         neg_q, neg_r;

    wire [32:0] shifted = {rem, quo[31]};
    wire [33:0] trial   = {1'b0, shifted} - {2'b00, dvs};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            result_valid <= 1'b0;
        end else if (flush) begin
            state        <= IDLE;
            result_valid <= 1'b0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    op_r           <= op;
                    result_phys_rd <= phys_rd;
                    result_rob_idx <= rob_idx;
                    if (!op[2]) begin
                        product <= $signed({a_signed && a[31], a}) * $signed({b_signed && b[31], b});
                        state   <= MUL;
                    end else begin
                        rem   <= 32'd0;
                        quo   <= a_neg ? -a : a;
                        dvs   <= b_neg ? -b : b;
                        neg_q <= (a_neg != b_neg) && (b != 32'd0);
                        neg_r <= a_neg;
                        count <= 6'd32;
                        state <= DIV;
                    end
                end

                MUL: begin
                    result_data  <= (op_r == 3'd0) ? product[31:0] : product[63:32];
                    result_valid <= 1'b1;
                    state        <= DONE;
                end

                DIV: begin
                    if (count != 6'd0) begin
                        if (!trial[33]) begin
                            rem <= trial[31:0];
                            quo <= {quo[30:0], 1'b1};
                        end else begin
                            rem <= shifted[31:0];
                            quo <= {quo[30:0], 1'b0};
                        end
                        count <= count - 6'd1;
                    end else begin
                        result_data  <= op_r[1] ? (neg_r ? -rem : rem)      // REM, REMU
                                                : (neg_q ? -quo : quo);     // DIV, DIVU
                        result_valid <= 1'b1;
                        state        <= DONE;
                    end
                end

                DONE: if (result_accept) begin
                    result_valid <= 1'b0;
                    state        <= IDLE;
                end
            endcase
        end
    end

endmodule
