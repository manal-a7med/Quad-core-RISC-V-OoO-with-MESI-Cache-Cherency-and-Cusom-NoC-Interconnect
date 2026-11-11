`timescale 1ns / 1ps
// ============================================================================
// seg7_display.v - 8-digit multiplexed 7-segment display (hex)
// ============================================================================
// Shows a 32-bit value as 8 hex digits on a common-anode display with
// active-low segments and anodes (Nexys A7 style). Digit 0 is the rightmost.
// REFRESH_BITS sets the digit rate: clk / 2^REFRESH_BITS per digit
// (50 MHz / 2^16 = ~760 Hz per digit, ~95 Hz for the whole display).
// ============================================================================
module seg7_display #(parameter integer REFRESH_BITS = 16) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] value,
    input  wire [7:0]  dots,          // decimal point per digit (1 = on)
    output reg  [6:0]  seg,           // {CG, CF, CE, CD, CC, CB, CA}, active low
    output reg         dp,            // active low
    output reg  [7:0]  an             // active low
);
    reg [REFRESH_BITS+2:0] cnt;
    wire [2:0] digit = cnt[REFRESH_BITS+2:REFRESH_BITS];
    wire [3:0] nib   = value[digit*4 +: 4];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) cnt <= 0;
        else        cnt <= cnt + 1'b1;

    reg [6:0] g;   // active-high segments {g, f, e, d, c, b, a}
    always @(*) begin
        case (nib)
            4'h0: g = 7'b0111111; 4'h1: g = 7'b0000110; 4'h2: g = 7'b1011011; 4'h3: g = 7'b1001111;
            4'h4: g = 7'b1100110; 4'h5: g = 7'b1101101; 4'h6: g = 7'b1111101; 4'h7: g = 7'b0000111;
            4'h8: g = 7'b1111111; 4'h9: g = 7'b1101111; 4'hA: g = 7'b1110111; 4'hB: g = 7'b1111100;
            4'hC: g = 7'b0111001; 4'hD: g = 7'b1011110; 4'hE: g = 7'b1111001; default: g = 7'b1110001;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg <= 7'h7F; dp <= 1'b1; an <= 8'hFF;
        end else begin
            seg <= ~g;
            dp  <= ~dots[digit];
            an  <= ~(8'd1 << digit);
        end
    end
endmodule
