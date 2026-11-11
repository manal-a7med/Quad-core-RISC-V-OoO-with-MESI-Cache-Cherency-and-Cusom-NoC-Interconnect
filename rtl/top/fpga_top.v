`timescale 1ns / 1ps
// ============================================================================
// fpga_top.v - Nexys A7-100T wrapper for the quad-core SoC
// ============================================================================
//   CLK100MHZ  -> MMCM -> core clock (1000 MHz VCO / CLKOUT_DIV; 20 = 50 MHz)
//   CPU_RESETN -> reset, held until the MMCM locks, released synchronously
//   UART_RXD_OUT  serial output to the PC (USB-UART, 115200 8N1)
//   LED[15:0]     the SoC's LEDS register
//   7-segment     the SoC's HEX register; the rightmost decimal point lights
//                 when the program has written EXIT
// The program is preloaded into main memory from MEM_INIT_FILE (line hex,
// see `make sw` and synth/build.tcl).
// Under SIM the MMCM is bypassed (the core runs on CLK100MHZ directly).
// ============================================================================
module fpga_top #(
    parameter integer CLKOUT_DIV = 20,                       // core clock = 1000 MHz / CLKOUT_DIV
    parameter integer BAUD       = 115200,
    parameter integer SEG_REFRESH_BITS = 16                  // 7-segment digit rate
) (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    output wire        UART_RXD_OUT,
    output wire [15:0] LED,
    output wire [6:0]  SEG,           // {CG, CF, CE, CD, CC, CB, CA}
    output wire        DP,
    output wire [7:0]  AN
);
    localparam integer CLK_HZ = 1000000000 / CLKOUT_DIV;

    // ------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------
    wire clk, locked;
`ifdef SIM
    assign clk    = CLK100MHZ;
    assign locked = 1'b1;
`else
    wire clk_mmcm, fb_mmcm, fb_buf;
    MMCME2_BASE #(
        .CLKIN1_PERIOD   (10.0),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (10.0),          // VCO = 1000 MHz
        .CLKOUT0_DIVIDE_F(CLKOUT_DIV)
    ) u_mmcm (
        .CLKIN1   (CLK100MHZ),
        .CLKFBIN  (fb_buf),
        .CLKFBOUT (fb_mmcm),
        .CLKOUT0  (clk_mmcm),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
    );
    BUFG u_fb_buf  (.I(fb_mmcm),  .O(fb_buf));
    BUFG u_clk_buf (.I(clk_mmcm), .O(clk));
`endif

    // ------------------------------------------------------------------
    // Reset: asserted asynchronously, released synchronously
    // ------------------------------------------------------------------
    wire arst_n = CPU_RESETN && locked;
    reg [2:0] rst_sync;
    always @(posedge clk or negedge arst_n)
        if (!arst_n) rst_sync <= 3'b000;
        else         rst_sync <= {rst_sync[1:0], 1'b1};
    wire rst_n = rst_sync[2];

    // ------------------------------------------------------------------
    // SoC
    // ------------------------------------------------------------------
    wire [3:0]  core_active;
    wire        mem_busy;
    wire [31:0] hex_value, exit_value;
    wire        exit_valid;

    quad_core_top #(.UART_CLKS_PER_BIT(CLK_HZ / BAUD)) u_soc (
        .clk        (clk),
        .rst_n      (rst_n),
        .core_active(core_active),
        .mem_busy   (mem_busy),
        .uart_txd   (UART_RXD_OUT),
        .leds       (LED),
        .hex_value  (hex_value),
        .exit_value (exit_value),
        .exit_valid (exit_valid)
    );

    seg7_display #(.REFRESH_BITS(SEG_REFRESH_BITS)) u_seg (
        .clk  (clk),
        .rst_n(rst_n),
        .value(hex_value),
        .dots ({7'd0, exit_valid}),
        .seg  (SEG),
        .dp   (DP),
        .an   (AN)
    );
endmodule
