`timescale 1ns / 1ps
// ============================================================================
// fpga_top.v — FPGA Wrapper for Quad-Core RISC-V OoO SoC
// ============================================================================
// FPGA-specific wrapper with clock generation, reset synchronization,
// and debug LED outputs. Generic for Xilinx 7-series FPGAs.
// ============================================================================

module fpga_top (
    input  wire        sys_clk,     // Board oscillator (100 MHz typical)
    input  wire        sys_rst_n,   // Active-low push button reset

    // Debug LEDs
    output wire [3:0]  led_core_active,
    output wire        led_mem_busy,
    output wire [2:0]  led_status
);

    // ========================================================================
    // Clock and Reset
    // ========================================================================
    // For FPGA: use a clock divider or MMCM for lower frequency.
    // Quad-core OoO design may need 25-50 MHz on Artix-7.

    wire clk;
    wire rst_n;

    // Simple clock divider (divide by 4: 100 MHz → 25 MHz)
    reg [1:0] clk_div;
    reg       clk_25mhz;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            clk_div   <= 2'd0;
            clk_25mhz <= 1'b0;
        end else begin
            clk_div <= clk_div + 1;
            if (clk_div == 2'd1)
                clk_25mhz <= ~clk_25mhz;
        end
    end

    assign clk = clk_25mhz;

    // Reset synchronizer (2-FF synchronizer for metastability)
    reg rst_sync1, rst_sync2;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rst_sync1 <= 1'b0;
            rst_sync2 <= 1'b0;
        end else begin
            rst_sync1 <= 1'b1;
            rst_sync2 <= rst_sync1;
        end
    end

    assign rst_n = rst_sync2;

    // ========================================================================
    // Core Status Tracking
    // ========================================================================
    wire [3:0] core_active;
    wire       mem_busy;

    // ========================================================================
    // Quad-Core SoC Instantiation
    // ========================================================================
    quad_core_top u_soc (
        .clk         (clk),
        .rst_n       (rst_n),
        .core_active (core_active),
        .mem_busy    (mem_busy)
    );

    // ========================================================================
    // LED Outputs
    // ========================================================================
    assign led_core_active = core_active;
    assign led_mem_busy    = mem_busy;
    assign led_status      = {rst_n, clk, 1'b1};  // Reset status, clock, alive

endmodule
