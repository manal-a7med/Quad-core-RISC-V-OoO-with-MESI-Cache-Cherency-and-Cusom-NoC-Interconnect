`timescale 1ns / 1ps
// ============================================================================
// quad_core_top.v — 4-Core RISC-V OoO SoC with MESI Cache Coherence
// ============================================================================
// Top-level module instantiating 4 OoO cores, their L1 caches, the
// interconnect (MESI snooping bus by default, NoC + directory with
// +define+NOC), shared L2 cache, memory controller, and main memory.
// ============================================================================

`include "mesi_defines.vh"
`include "common_defs.vh"

module quad_core_top #(
    parameter integer UART_CLKS_PER_BIT = 434   // 50 MHz / 115200 baud
) (
    input  wire        clk,
    input  wire        rst_n,

    // Debug / Status outputs
    output wire [3:0]  core_active,     // Which cores are running
    output wire        mem_busy,        // Memory controller busy

    // Memory-mapped I/O (addresses with bit 31 set, see rtl/io/soc_io.v)
    output wire        uart_txd,
    output wire [15:0] leds,
    output wire [31:0] hex_value,
    output wire [31:0] exit_value,
    output wire        exit_valid
);

    // ========================================================================
    // Per-Core Wires (I-Cache and D-Cache interfaces)
    // ========================================================================
    // I-Cache: core ↔ L1I
    wire [31:0]  ic_addr   [0:3];
    wire [31:0]  ic_naddr  [0:3];
    wire [31:0]  ic_rdata  [0:3];
    wire         ic_req    [0:3];
    wire         ic_ack    [0:3];

    // D-Cache: core ↔ L1D
    wire [31:0]  dc_addr   [0:3];
    wire [31:0]  dc_wdata  [0:3];
    wire         dc_req    [0:3];
    wire         dc_wr     [0:3];
    wire [2:0]   dc_mtype  [0:3];
    wire [3:0]   dc_amo    [0:3];

    // Uncached I/O: each core's data port goes to soc_io when addr[31] = 1
    wire [3:0]   io_req, io_wr, io_ack;
    wire [127:0] io_addr, io_wdata;
    wire [31:0]  io_rdata;

    // L1 coherence ports (rtl/coherence/coh_port.vh): L1D/I-cache <-> interconnect
    wire         bus_req   [0:3];      // L1D request side
    wire [2:0]   bus_cmd   [0:3];
    wire [31:0]  bus_addr  [0:3];
    wire [255:0] bus_wdata [0:3];
    wire         bus_way   [0:3];
    wire [3:0]   port_ack, port_shared, port_busy;
    wire [1023:0] port_rdata;

    // Probe side: interconnect <-> L1D snoop port
    wire [3:0]   pr_valid;
    wire [127:0] pr_addr;
    wire [11:0]  pr_cmd;
    wire [1:0]   snoop_resp  [0:3];
    wire [255:0] snoop_data  [0:3];
    wire         snoop_dvalid[0:3];

    // I-cache line fetches. They use the L1 port of the same core's L1D
    // (see the port mux in the generate block).
    wire [31:0]  icmem_addr  [0:3];
    wire         icmem_req   [0:3];
    wire         icmem_ack   [0:3];
    wire         ic_flush    [0:3];
    reg  [3:0]   ic_own;                 // the I-cache holds core n's port
    wire [3:0]   port_req;               // per-core port after the mux
    wire [2:0]   port_cmd   [0:3];
    wire [31:0]  port_addr  [0:3];

    // L2 interface
    wire         l2_req_valid;
    wire [31:0]  l2_req_addr;
    wire [2:0]   l2_req_cmd;
    wire [255:0] l2_req_wdata;
    wire [255:0] l2_resp_data;
    wire         l2_resp_valid;

    // L2 ↔ Memory Arbiter
    wire         l2_mem_req, l2_mem_wr;
    wire [31:0]  l2_mem_addr;
    wire [255:0] l2_mem_wdata, l2_mem_rdata;
    wire         l2_mem_ack;

    // Memory Arbiter ↔ Memory Controller
    reg          mc_req, mc_wr;
    reg  [31:0]  mc_addr;
    reg  [255:0] mc_wdata;
    wire [255:0] mc_rdata;
    wire         mc_ack;

    // Memory Controller ↔ Main Memory
    wire [31:0]  mem_addr;
    wire [255:0] mem_wdata, mem_rdata;
    wire         mem_req, mem_wr_sig, mem_ack;

    // ========================================================================
    // Generate 4 Cores + L1 Caches
    // ========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : core_gen

            wire        io_sel = dc_addr[gi][31];
            wire        l1d_ack;
            wire [31:0] l1d_rdata;
            wire        d_ack   = io_sel ? io_ack[gi] : l1d_ack;
            wire [31:0] d_rdata = io_sel ? io_rdata   : l1d_rdata;
            assign io_req[gi]              = dc_req[gi] && io_sel;
            assign io_wr[gi]               = dc_wr[gi];
            assign io_addr[gi*32 +: 32]    = dc_addr[gi];
            assign io_wdata[gi*32 +: 32]   = dc_wdata[gi];

            // --- OoO Core ---
            riscv_ooo_core u_core (
                .clk            (clk),
                .rst_n          (rst_n),
                .core_id        (gi[1:0]),
                .icache_addr    (ic_addr[gi]),
                .icache_next_addr(ic_naddr[gi]),
                .icache_rdata   (ic_rdata[gi]),
                .icache_req     (ic_req[gi]),
                .icache_ack     (ic_ack[gi]),
                .icache_flush   (ic_flush[gi]),
                .dcache_addr    (dc_addr[gi]),
                .dcache_wdata   (dc_wdata[gi]),
                .dcache_rdata   (d_rdata),
                .dcache_req     (dc_req[gi]),
                .dcache_wr      (dc_wr[gi]),
                .dcache_ack     (d_ack),
                .dcache_mem_type(dc_mtype[gi]),
                .dcache_amo     (dc_amo[gi])
            );

            // --- L1 Instruction Cache ---
            l1_icache u_l1i (
                .clk        (clk),
                .rst_n      (rst_n),
                .cpu_addr   (ic_addr[gi]),
                .cpu_next_addr(ic_naddr[gi]),
                .cpu_rdata  (ic_rdata[gi]),
                .cpu_req    (ic_req[gi]),
                .cpu_ack    (ic_ack[gi]),
                .mem_addr   (icmem_addr[gi]),
                .mem_rdata  (port_rdata[gi*256 +: 256]),
                .mem_req    (icmem_req[gi]),
                .mem_ack    (icmem_ack[gi]),
                .flush_all  (ic_flush[gi])
            );

            // --- Port mux: L1D or I-cache ---
            // An I-cache miss is a BusRd on this core's L1 port (review bug
            // 16: it used to read main memory directly and could miss newer
            // data held in an L1D or the L2). The I-cache takes the port when
            // the L1D is not using it and keeps it until its acknowledge; the
            // L1D's own request waits meanwhile. The interconnect probes all
            // four L1Ds for such a request (l1_ifetch), this core's included.
            wire l1d_bus_ack = port_ack[gi] && !ic_own[gi];
            assign icmem_ack[gi] = port_ack[gi] && ic_own[gi];
            assign port_req[gi]  = ic_own[gi] ? icmem_req[gi]  : bus_req[gi];
            assign port_cmd[gi]  = ic_own[gi] ? `BUS_READ      : bus_cmd[gi];
            assign port_addr[gi] = ic_own[gi] ? icmem_addr[gi] : bus_addr[gi];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    ic_own[gi] <= 1'b0;
                else if (ic_own[gi])
                    ic_own[gi] <= !icmem_ack[gi];
                else
                    ic_own[gi] <= icmem_req[gi] && !bus_req[gi] && !port_busy[gi];
            end

            // --- L1 Data Cache ---
            l1_dcache u_l1d (
                .clk             (clk),
                .rst_n           (rst_n),
                .cpu_addr        (dc_addr[gi]),
                .cpu_wdata       (dc_wdata[gi]),
                .cpu_rdata       (l1d_rdata),
                .cpu_req         (dc_req[gi] && !io_sel),
                .cpu_wr          (dc_wr[gi]),
                .cpu_ack         (l1d_ack),
                .cpu_mem_type    (dc_mtype[gi]),
                .cpu_amo         (dc_amo[gi]),
                .bus_addr        (bus_addr[gi]),
                .bus_wdata       (bus_wdata[gi]),
                .bus_rdata       (port_rdata[gi*256 +: 256]),
                .bus_req         (bus_req[gi]),
                .bus_cmd         (bus_cmd[gi]),
                .bus_ack         (l1d_bus_ack),
                .bus_grant       (port_busy[gi]),
                .bus_shared      (port_shared[gi]),
                .bus_way         (bus_way[gi]),
                .snoop_addr      (pr_addr[gi*32 +: 32]),
                .snoop_cmd       (pr_cmd[gi*3 +: 3]),
                .snoop_valid     (pr_valid[gi]),
                .snoop_resp      (snoop_resp[gi]),
                .snoop_data      (snoop_data[gi]),
                .snoop_data_valid(snoop_dvalid[gi])
            );

            assign core_active[gi] = 1'b1;
        end
    endgenerate

    // ========================================================================
    // Memory-mapped I/O: UART, LEDs, 7-segment value, exit register
    // ========================================================================
    soc_io #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) u_io (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (io_req),
        .wr        (io_wr),
        .addr      (io_addr),
        .wdata     (io_wdata),
        .ack       (io_ack),
        .rdata     (io_rdata),
        .uart_txd  (uart_txd),
        .leds      (leds),
        .hex_value (hex_value),
        .exit_value(exit_value),
        .exit_valid(exit_valid)
    );

    // ========================================================================
    // Interconnect: snooping bus (default) or 2x2 mesh NoC + directory
    // (+define+NOC, make ... NOC=1). Same L1 ports, same L2 port.
    // ========================================================================
`ifdef NOC
`ifndef NOC_BANKS
`define NOC_BANKS 1
`endif
    noc_interconnect #(.NBANKS(`NOC_BANKS)) u_ic (
`else
    bus_interconnect u_ic (
`endif
        .clk          (clk),
        .rst_n        (rst_n),
        .l1_req       (port_req),
        .l1_cmd       ({port_cmd[3],  port_cmd[2],  port_cmd[1],  port_cmd[0]}),
        .l1_addr      ({port_addr[3], port_addr[2], port_addr[1], port_addr[0]}),
        .l1_wdata     ({bus_wdata[3], bus_wdata[2], bus_wdata[1], bus_wdata[0]}),
        .l1_ifetch    (ic_own),
        .l1_way       ({bus_way[3], bus_way[2], bus_way[1], bus_way[0]}),
        .l1_ack       (port_ack),
        .l1_rdata     (port_rdata),
        .l1_shared    (port_shared),
        .l1_busy      (port_busy),
        .pr_valid     (pr_valid),
        .pr_addr      (pr_addr),
        .pr_cmd       (pr_cmd),
        .pr_resp      ({snoop_resp[3], snoop_resp[2], snoop_resp[1], snoop_resp[0]}),
        .pr_data      ({snoop_data[3], snoop_data[2], snoop_data[1], snoop_data[0]}),
        .pr_dvalid    ({snoop_dvalid[3], snoop_dvalid[2], snoop_dvalid[1], snoop_dvalid[0]}),
        .l2_req_valid (l2_req_valid),
        .l2_req_addr  (l2_req_addr),
        .l2_req_cmd   (l2_req_cmd),
        .l2_req_wdata (l2_req_wdata),
        .l2_resp_data (l2_resp_data),
        .l2_resp_valid(l2_resp_valid)
    );

    // ========================================================================
    // Shared L2 Cache
    // ========================================================================
    l2_cache u_l2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (l2_req_valid),
        .req_addr  (l2_req_addr),
        .req_wdata (l2_req_wdata),
        .req_cmd   (l2_req_cmd),
        .req_ack   (),
        .resp_data (l2_resp_data),
        .resp_valid(l2_resp_valid),
        .mem_addr  (l2_mem_addr),
        .mem_wdata (l2_mem_wdata),
        .mem_rdata (l2_mem_rdata),
        .mem_req   (l2_mem_req),
        .mem_wr    (l2_mem_wr),
        .mem_ack   (l2_mem_ack)
    );

    // ========================================================================
    // L2 to memory controller
    // ========================================================================
    // The L2 is the only user of main memory (I-cache fetches go over the
    // bus). The request is passed on one cycle after the L2 raises it and
    // removed in the acknowledge cycle, which is the handshake the memory
    // controller was built for.
    reg mem_arb_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            mem_arb_busy <= 1'b0;
        else if (!mem_arb_busy) mem_arb_busy <= l2_mem_req;
        else if (mc_ack)       mem_arb_busy <= 1'b0;
    end

    always @(*) begin
        mc_req   = mem_arb_busy && !mc_ack && l2_mem_req;
        mc_wr    = mc_req && l2_mem_wr;
        mc_addr  = l2_mem_addr;
        mc_wdata = l2_mem_wdata;
    end

    assign l2_mem_rdata = mc_rdata;
    assign l2_mem_ack   = mem_arb_busy && mc_ack;

    // ========================================================================
    // Memory Controller
    // ========================================================================
    memory_controller u_memctrl (
        .clk      (clk),
        .rst_n    (rst_n),
        .l2_req   (mc_req),
        .l2_wr    (mc_wr),
        .l2_addr  (mc_addr),
        .l2_wdata (mc_wdata),
        .l2_rdata (mc_rdata),
        .l2_ack   (mc_ack),
        .mem_addr (mem_addr),
        .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata),
        .mem_req  (mem_req),
        .mem_wr   (mem_wr_sig),
        .mem_ack  (mem_ack)
    );

    assign mem_busy = mem_req;

    // ========================================================================
    // Main Memory
    // ========================================================================
    main_memory u_mem (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (mem_addr),
        .wdata (mem_wdata),
        .rdata (mem_rdata),
        .req   (mem_req),
        .wr    (mem_wr_sig),
        .ack   (mem_ack)
    );

endmodule
