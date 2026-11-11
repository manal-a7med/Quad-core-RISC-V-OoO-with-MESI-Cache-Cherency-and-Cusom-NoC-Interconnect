`timescale 1ns / 1ps
// 8N1 UART transmitter. CLKS_PER_BIT = clock frequency / baud rate.
module uart_tx #(parameter integer CLKS_PER_BIT = 434) (   // 50 MHz / 115200
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output wire       busy
);
    reg [15:0] cnt;
    reg [3:0]  bitn;      // 0 = idle, 1 = start, 2..9 = data, 10 = stop
    reg [7:0]  sh;
    assign busy = (bitn != 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1; cnt <= 16'd0; bitn <= 4'd0; sh <= 8'd0;
        end else if (bitn == 4'd0) begin
            tx <= 1'b1;
            if (start) begin
                sh <= data; bitn <= 4'd1; cnt <= 16'd0; tx <= 1'b0;   // start bit
            end
        end else if (cnt != CLKS_PER_BIT - 1) begin
            cnt <= cnt + 16'd1;
        end else begin
            cnt <= 16'd0;
            if (bitn == 4'd10) begin
                bitn <= 4'd0;
            end else begin
                bitn <= bitn + 4'd1;
                if (bitn <= 4'd8) begin tx <= sh[0]; sh <= {1'b0, sh[7:1]}; end
                else tx <= 1'b1;                                       // stop bit
            end
        end
    end
endmodule
