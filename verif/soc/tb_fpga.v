`timescale 1ns/1ps
// ============================================================================
// tb_fpga.v - board-level simulation of fpga_top (Nexys A7 pins)
// ============================================================================
// Runs the FPGA top with the program baked into main memory (MEM_INIT_FILE,
// as in the bitstream), decodes the UART serial line like the PC's terminal
// would, and reads the 7-segment display back from the SEG/AN pins.
// The UART runs at 10 clocks per bit to keep the simulation short.
// Ends when the display's exit dot lights: prints RESULT PASS if the
// program's EXIT value was 1.
// ============================================================================
module tb_fpga;
  reg clk = 0, resetn = 0;
  always #5 clk = ~clk;
  wire txd; wire [15:0] led; wire [6:0] seg; wire dp; wire [7:0] an;

  localparam BIT = 10;   // clocks per UART bit
  fpga_top #(.CLKOUT_DIV(20), .BAUD(50000000 / BIT), .SEG_REFRESH_BITS(3)) dut (
    .CLK100MHZ(clk), .CPU_RESETN(resetn), .UART_RXD_OUT(txd),
    .LED(led), .SEG(seg), .DP(dp), .AN(an));

  // UART receiver (8N1)
  integer b; reg [7:0] ch;
  initial begin
    @(posedge resetn);
    forever begin
      @(negedge txd);
      repeat (BIT + BIT/2) @(posedge clk);
      for (b = 0; b < 8; b = b + 1) begin ch[b] = txd; repeat (BIT) @(posedge clk); end
      if (txd !== 1'b1) $display("\n[uart] framing error");
      $write("%c", ch);
    end
  end

  // Read the display back from the pins: segments -> hex digit
  function [4:0] seg2hex(input [6:0] s);   // {valid, nibble}
    case (~s)
      7'b0111111: seg2hex = 5'h10; 7'b0000110: seg2hex = 5'h11; 7'b1011011: seg2hex = 5'h12;
      7'b1001111: seg2hex = 5'h13; 7'b1100110: seg2hex = 5'h14; 7'b1101101: seg2hex = 5'h15;
      7'b1111101: seg2hex = 5'h16; 7'b0000111: seg2hex = 5'h17; 7'b1111111: seg2hex = 5'h18;
      7'b1101111: seg2hex = 5'h19; 7'b1110111: seg2hex = 5'h1A; 7'b1111100: seg2hex = 5'h1B;
      7'b0111001: seg2hex = 5'h1C; 7'b1011110: seg2hex = 5'h1D; 7'b1111001: seg2hex = 5'h1E;
      7'b1110001: seg2hex = 5'h1F; default: seg2hex = 5'h00;
    endcase
  endfunction
  reg [31:0] shown; reg [7:0] seen; integer d;
  always @(posedge clk) begin
    for (d = 0; d < 8; d = d + 1)
      if (an == ~(8'd1 << d) && seg2hex(seg) >= 5'h10) begin
        shown[d*4 +: 4] <= seg2hex(seg); seen[d] <= 1'b1;
      end
  end

  integer cycles = 0, timeout;
  initial begin
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 2000000;
    seen = 0; shown = 0;
    #100 resetn = 1;
    while (!(an[0] == 1'b0 && dp == 1'b0) && cycles < timeout) begin @(posedge clk); cycles = cycles + 1; end
    seen = 0; repeat (200) @(posedge clk);     // let the display scan all digits
    $display("\n7-segment display: %h (all digits seen: %b)  LEDs: %b", shown, &seen, led);
    if (cycles >= timeout)                      $display("RESULT TIMEOUT cycles=%0d", cycles);
    else if (dut.exit_value == 32'd1 && &seen && shown == dut.hex_value)
                                                $display("RESULT PASS cycles=%0d", cycles);
    else                                        $display("RESULT FAIL exit=%0d", dut.exit_value);
    $finish;
  end
endmodule
