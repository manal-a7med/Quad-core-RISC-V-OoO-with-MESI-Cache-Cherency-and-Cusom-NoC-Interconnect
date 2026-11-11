`timescale 1ns / 1ps
// ============================================================================
// soc_io.v - Uncached memory-mapped I/O shared by the four cores
// ============================================================================
// Addresses with bit 31 set bypass the data caches and come here:
//   0x8000_0000  UART_TX  (W)  send one byte; the store completes when the
//                               transmitter has taken it
//   0x8000_0004  STATUS   (R)  bit 0 = UART busy
//   0x8000_0008  EXIT     (W)  result word, shown on the 7-segment display;
//                               also ends a simulation (1 = pass)
//   0x8000_000C  LEDS     (RW) 16 board LEDs
//   0x8000_0010  HEX      (RW) value shown on the 8-digit 7-segment display
//   0x8000_0014  BOOT     (RW) scratch word cleared by reset; hart 0 sets it
//                               when start-up is done (other harts wait on it)
// One request is served at a time, round-robin across cores.
// In simulation each transmitted byte is also printed with $write.
// ============================================================================
module soc_io #(parameter integer CLKS_PER_BIT = 434) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [3:0]    req,
    input  wire [3:0]    wr,
    input  wire [127:0]  addr,     // core n at [32n +: 32]
    input  wire [127:0]  wdata,
    output reg  [3:0]    ack,
    output reg  [31:0]   rdata,
    output wire          uart_txd,
    output reg  [15:0]   leds,
    output reg  [31:0]   hex_value,
    output reg  [31:0]   exit_value,
    output reg           exit_valid
);
    wire uart_busy;
    reg  uart_start;
    reg  [7:0] uart_data;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n), .start(uart_start), .data(uart_data),
        .tx(uart_txd), .busy(uart_busy));

    reg  [31:0] boot;
    reg  [1:0] rr;            // next core to consider first
    reg        busy;          // serving `cur`
    reg  [1:0] cur;
    wire [31:0] a = addr[cur*32 +: 32];
    wire [31:0] d = wdata[cur*32 +: 32];

    // Round-robin pick among requesters that are not being acked this cycle
    wire [3:0] pending = req & ~ack;
    reg  [1:0] pick; reg found; integer i;
    always @(*) begin
        pick = rr; found = 1'b0;
        for (i = 0; i < 4; i = i + 1)
            if (!found && pending[(rr + i) & 3]) begin pick = (rr + i) & 3; found = 1'b1; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack <= 4'd0; rdata <= 32'd0; rr <= 2'd0; busy <= 1'b0; cur <= 2'd0;
            uart_start <= 1'b0; uart_data <= 8'd0;
            leds <= 16'd0; hex_value <= 32'd0; boot <= 32'd0; exit_value <= 32'd0; exit_valid <= 1'b0;
        end else begin
            ack <= 4'd0;
            uart_start <= 1'b0;
            if (!busy) begin
                if (found) begin busy <= 1'b1; cur <= pick; rr <= pick + 2'd1; end
            end else if (!req[cur]) begin
                busy <= 1'b0;                               // requester gave up
            end else begin
                case (a[4:2])
                    3'd0: if (!wr[cur]) begin rdata <= 32'd0; ack[cur] <= 1'b1; busy <= 1'b0; end
                          else if (!uart_busy && !uart_start) begin
                              uart_data <= d[7:0]; uart_start <= 1'b1;
                              ack[cur] <= 1'b1; busy <= 1'b0;
`ifdef SIM
                              $write("%c", d[7:0]);
`endif
                          end
                    3'd1: begin rdata <= {31'd0, uart_busy || uart_start}; ack[cur] <= 1'b1; busy <= 1'b0; end
                    3'd2: begin
                              if (wr[cur]) begin exit_value <= d; exit_valid <= 1'b1; end
                              rdata <= exit_value; ack[cur] <= 1'b1; busy <= 1'b0;
                          end
                    3'd3: begin
                              if (wr[cur]) leds <= d[15:0];
                              rdata <= {16'd0, leds}; ack[cur] <= 1'b1; busy <= 1'b0;
                          end
                    3'd4: begin
                              if (wr[cur]) hex_value <= d;
                              rdata <= hex_value; ack[cur] <= 1'b1; busy <= 1'b0;
                          end
                    3'd5: begin
                              if (wr[cur]) boot <= d;
                              rdata <= boot; ack[cur] <= 1'b1; busy <= 1'b0;
                          end
                    default: begin rdata <= 32'd0; ack[cur] <= 1'b1; busy <= 1'b0; end
                endcase
            end
        end
    end
endmodule
