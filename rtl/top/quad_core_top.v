`timescale 1ns / 1ps
// ============================================================================
// quad_core_top.v — 4-Core RISC-V OoO SoC with MESI Cache Coherence
// ============================================================================
// Top-level module instantiating 4 OoO cores, their L1 caches,
// the MESI coherence bus, bus arbiter, snoop controller, shared L2 cache,
// memory controller, and main memory.
// ============================================================================

`include "mesi_defines.vh"
`include "common_defs.vh"

module quad_core_top (
    input  wire        clk,
    input  wire        rst_n,

    // Debug / Status outputs
    output wire [3:0]  core_active,     // Which cores are running
    output wire        mem_busy         // Memory controller busy
);

    // ========================================================================
    // Per-Core Wires (I-Cache and D-Cache interfaces)
    // ========================================================================
    // I-Cache: core ↔ L1I
    wire [31:0]  ic_addr   [0:3];
    wire [31:0]  ic_rdata  [0:3];
    wire         ic_req    [0:3];
    wire         ic_ack    [0:3];

    // D-Cache: core ↔ L1D
    wire [31:0]  dc_addr   [0:3];
    wire [31:0]  dc_wdata  [0:3];
    wire [31:0]  dc_rdata  [0:3];
    wire         dc_req    [0:3];
    wire         dc_wr     [0:3];
    wire         dc_ack    [0:3];
    wire [2:0]   dc_mtype  [0:3];

    // Bus interface: L1D ↔ coherence bus
    wire         bus_req   [0:3];
    wire [2:0]   bus_cmd   [0:3];
    wire [31:0]  bus_addr  [0:3];
    wire [255:0] bus_wdata [0:3];
    wire [255:0] bus_rdata_bc;   // Broadcast data from bus
    wire         bus_shared_bc;  // Broadcast shared status from bus
    wire         bus_grant [0:3];
    wire         bus_ack_arr[0:3];

    // Snoop interface: coherence bus ↔ L1D
    wire         snoop_valid [0:3];
    wire [31:0]  snoop_addr_bc;
    wire [2:0]   snoop_cmd_bc;
    wire [1:0]   snoop_resp  [0:3];
    wire [255:0] snoop_data  [0:3];
    wire         snoop_dvalid[0:3];

    // I-Cache ↔ Memory Arbiter
    wire [31:0]  icmem_addr  [0:3];
    wire [255:0] icmem_rdata [0:3];
    wire         icmem_req   [0:3];
    wire         icmem_ack   [0:3];

    // ========================================================================
    // Arbiter & Snoop Controller Signals
    // ========================================================================
    wire [3:0]   arb_req;
    wire [3:0]   arb_grant;
    wire         arb_busy;
    wire         arb_release;
    wire [1:0]   arb_owner;

    wire         sc_req_valid;
    wire [2:0]   sc_req_cmd;
    wire [31:0]  sc_req_addr;
    wire [255:0] sc_req_wdata;
    wire [1:0]   sc_req_core_id;
    wire         sc_resp_valid;
    wire [255:0] sc_resp_data;
    wire         sc_resp_shared;

    wire [3:0]   sc_snoop_valid;
    wire [31:0]  sc_snoop_addr;
    wire [2:0]   sc_snoop_cmd;
    wire [7:0]   sc_snoop_resp;
    wire [255:0] sc_snoop_data;
    wire [3:0]   sc_snoop_dvalid;

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

            // --- OoO Core ---
            riscv_ooo_core u_core (
                .clk            (clk),
                .rst_n          (rst_n),
                .core_id        (gi[1:0]),
                .icache_addr    (ic_addr[gi]),
                .icache_rdata   (ic_rdata[gi]),
                .icache_req     (ic_req[gi]),
                .icache_ack     (ic_ack[gi]),
                .dcache_addr    (dc_addr[gi]),
                .dcache_wdata   (dc_wdata[gi]),
                .dcache_rdata   (dc_rdata[gi]),
                .dcache_req     (dc_req[gi]),
                .dcache_wr      (dc_wr[gi]),
                .dcache_ack     (dc_ack[gi]),
                .dcache_mem_type(dc_mtype[gi])
            );

            // --- L1 Instruction Cache ---
            l1_icache u_l1i (
                .clk        (clk),
                .rst_n      (rst_n),
                .cpu_addr   (ic_addr[gi]),
                .cpu_rdata  (ic_rdata[gi]),
                .cpu_req    (ic_req[gi]),
                .cpu_ack    (ic_ack[gi]),
                .mem_addr   (icmem_addr[gi]),
                .mem_rdata  (icmem_rdata[gi]),
                .mem_req    (icmem_req[gi]),
                .mem_ack    (icmem_ack[gi]),
                .invalidate (1'b0),
                .inval_addr (32'd0)
            );

            // --- L1 Data Cache ---
            l1_dcache u_l1d (
                .clk             (clk),
                .rst_n           (rst_n),
                .cpu_addr        (dc_addr[gi]),
                .cpu_wdata       (dc_wdata[gi]),
                .cpu_rdata       (dc_rdata[gi]),
                .cpu_req         (dc_req[gi]),
                .cpu_wr          (dc_wr[gi]),
                .cpu_ack         (dc_ack[gi]),
                .cpu_mem_type    (dc_mtype[gi]),
                .bus_addr        (bus_addr[gi]),
                .bus_wdata       (bus_wdata[gi]),
                .bus_rdata       (bus_rdata_bc),
                .bus_req         (bus_req[gi]),
                .bus_cmd         (bus_cmd[gi]),
                .bus_ack         (bus_ack_arr[gi]),
                .bus_grant       (bus_grant[gi]),
                .bus_shared      (bus_shared_bc),
                .snoop_addr      (snoop_addr_bc),
                .snoop_cmd       (snoop_cmd_bc),
                .snoop_valid     (snoop_valid[gi]),
                .snoop_resp      (snoop_resp[gi]),
                .snoop_data      (snoop_data[gi]),
                .snoop_data_valid(snoop_dvalid[gi])
            );

            assign core_active[gi] = 1'b1;
        end
    endgenerate

    // ========================================================================
    // Coherence Bus Interconnect
    // ========================================================================
    coherence_bus u_coh_bus (
        .clk                (clk),
        .rst_n              (rst_n),
        .core_bus_req       ({bus_req[3],   bus_req[2],   bus_req[1],   bus_req[0]}),
        .core_bus_cmd       ({bus_cmd[3],   bus_cmd[2],   bus_cmd[1],   bus_cmd[0]}),
        .core_bus_addr      ({bus_addr[3],  bus_addr[2],  bus_addr[1],  bus_addr[0]}),
        .core_bus_wdata     ({bus_wdata[3], bus_wdata[2], bus_wdata[1], bus_wdata[0]}),
        .core_bus_grant     ({bus_grant[3], bus_grant[2], bus_grant[1], bus_grant[0]}),
        .core_bus_ack       ({bus_ack_arr[3], bus_ack_arr[2], bus_ack_arr[1], bus_ack_arr[0]}),
        .core_bus_rdata     (bus_rdata_bc),
        .core_bus_shared    (bus_shared_bc),
        .sc_snoop_valid     (sc_snoop_valid),
        .sc_snoop_addr      (sc_snoop_addr),
        .sc_snoop_cmd       (sc_snoop_cmd),
        .snoop_valid        ({snoop_valid[3], snoop_valid[2], snoop_valid[1], snoop_valid[0]}),
        .snoop_addr         (snoop_addr_bc),
        .snoop_cmd          (snoop_cmd_bc),
        .snoop_resp         ({snoop_resp[3], snoop_resp[2], snoop_resp[1], snoop_resp[0]}),
        .snoop_data_flat    ({snoop_data[3], snoop_data[2], snoop_data[1], snoop_data[0]}),
        .snoop_data_valid   ({snoop_dvalid[3], snoop_dvalid[2], snoop_dvalid[1], snoop_dvalid[0]}),
        .sc_snoop_resp      (sc_snoop_resp),
        .sc_snoop_data      (sc_snoop_data),
        .sc_snoop_data_valid(sc_snoop_dvalid),
        .arb_req            (arb_req),
        .arb_grant          (arb_grant),
        .arb_busy           (arb_busy),
        .arb_release        (arb_release),
        .sc_req_valid       (sc_req_valid),
        .sc_req_cmd         (sc_req_cmd),
        .sc_req_addr        (sc_req_addr),
        .sc_req_wdata       (sc_req_wdata),
        .sc_req_core_id     (sc_req_core_id),
        .sc_resp_valid      (sc_resp_valid),
        .sc_resp_data       (sc_resp_data),
        .sc_resp_shared     (sc_resp_shared)
    );

    // ========================================================================
    // Bus Arbiter
    // ========================================================================
    bus_arbiter u_arbiter (
        .clk          (clk),
        .rst_n        (rst_n),
        .req          (arb_req),
        .grant        (arb_grant),
        .bus_busy     (arb_busy),
        .bus_release  (arb_release),
        .current_owner(arb_owner)
    );

    // ========================================================================
    // Snoop Controller
    // ========================================================================
    snoop_controller u_snoop (
        .clk             (clk),
        .rst_n           (rst_n),
        .grant           (arb_grant),
        .bus_busy        (arb_busy),
        .req_valid       (sc_req_valid),
        .req_cmd         (sc_req_cmd),
        .req_addr        (sc_req_addr),
        .req_wdata       (sc_req_wdata),
        .req_core_id     (sc_req_core_id),
        .snoop_valid     (sc_snoop_valid),
        .snoop_addr      (sc_snoop_addr),
        .snoop_cmd       (sc_snoop_cmd),
        .snoop_resp      (sc_snoop_resp),
        .snoop_data      (sc_snoop_data),
        .snoop_data_valid(sc_snoop_dvalid),
        .l2_req_valid    (l2_req_valid),
        .l2_req_addr     (l2_req_addr),
        .l2_req_cmd      (l2_req_cmd),
        .l2_req_wdata    (l2_req_wdata),
        .l2_resp_data    (l2_resp_data),
        .l2_resp_valid   (l2_resp_valid),
        .resp_valid      (sc_resp_valid),
        .resp_data       (sc_resp_data),
        .resp_shared     (sc_resp_shared),
        .bus_release     (arb_release)
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
    // Memory Arbiter (Muxes L2 data misses/writebacks and 4x L1I misses)
    // ========================================================================
    localparam MEM_ARB_IDLE = 1'b0;
    localparam MEM_ARB_BUSY = 1'b1;

    reg       mem_arb_state;
    reg [2:0] mem_arb_sel; // 0 = L2, 1..4 = Core 0..3 L1I
    reg [1:0] ic_rr_ptr;

    wire [1:0] ic_cand0 = ic_rr_ptr;
    wire [1:0] ic_cand1 = ic_rr_ptr + 2'd1;
    wire [1:0] ic_cand2 = ic_rr_ptr + 2'd2;
    wire [1:0] ic_cand3 = ic_rr_ptr + 2'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_arb_state <= MEM_ARB_IDLE;
            mem_arb_sel   <= 3'd0;
            ic_rr_ptr     <= 2'd0;
        end else begin
            case (mem_arb_state)
                MEM_ARB_IDLE: begin
                    if (l2_mem_req) begin
                        mem_arb_sel   <= 3'd0;
                        mem_arb_state <= MEM_ARB_BUSY;
                    end else if (icmem_req[ic_cand0]) begin
                        mem_arb_sel   <= {1'b0, ic_cand0} + 3'd1;
                        ic_rr_ptr     <= ic_cand0 + 2'd1;
                        mem_arb_state <= MEM_ARB_BUSY;
                    end else if (icmem_req[ic_cand1]) begin
                        mem_arb_sel   <= {1'b0, ic_cand1} + 3'd1;
                        ic_rr_ptr     <= ic_cand1 + 2'd1;
                        mem_arb_state <= MEM_ARB_BUSY;
                    end else if (icmem_req[ic_cand2]) begin
                        mem_arb_sel   <= {1'b0, ic_cand2} + 3'd1;
                        ic_rr_ptr     <= ic_cand2 + 2'd1;
                        mem_arb_state <= MEM_ARB_BUSY;
                    end else if (icmem_req[ic_cand3]) begin
                        mem_arb_sel   <= {1'b0, ic_cand3} + 3'd1;
                        ic_rr_ptr     <= ic_cand3 + 2'd1;
                        mem_arb_state <= MEM_ARB_BUSY;
                    end
                end

                MEM_ARB_BUSY: begin
                    if (mc_ack) begin
                        mem_arb_state <= MEM_ARB_IDLE;
                    end
                end
            endcase
        end
    end

    always @(*) begin
        mc_req   = 1'b0;
        mc_wr    = 1'b0;
        mc_addr  = 32'd0;
        mc_wdata = 256'd0;

        if (mem_arb_state == MEM_ARB_BUSY && !mc_ack) begin
            case (mem_arb_sel)
                3'd0: begin
                    mc_req   = l2_mem_req;
                    mc_wr    = l2_mem_wr;
                    mc_addr  = l2_mem_addr;
                    mc_wdata = l2_mem_wdata;
                end
                3'd1: begin
                    mc_req   = icmem_req[0];
                    mc_wr    = 1'b0;
                    mc_addr  = icmem_addr[0];
                end
                3'd2: begin
                    mc_req   = icmem_req[1];
                    mc_wr    = 1'b0;
                    mc_addr  = icmem_addr[1];
                end
                3'd3: begin
                    mc_req   = icmem_req[2];
                    mc_wr    = 1'b0;
                    mc_addr  = icmem_addr[2];
                end
                3'd4: begin
                    mc_req   = icmem_req[3];
                    mc_wr    = 1'b0;
                    mc_addr  = icmem_addr[3];
                end
                default: ;
            endcase
        end
    end

    assign l2_mem_rdata   = mc_rdata;
    assign l2_mem_ack     = (mem_arb_state == MEM_ARB_BUSY) && (mem_arb_sel == 3'd0) && mc_ack;

    assign icmem_rdata[0] = mc_rdata;
    assign icmem_rdata[1] = mc_rdata;
    assign icmem_rdata[2] = mc_rdata;
    assign icmem_rdata[3] = mc_rdata;

    assign icmem_ack[0]   = (mem_arb_state == MEM_ARB_BUSY) && (mem_arb_sel == 3'd1) && mc_ack;
    assign icmem_ack[1]   = (mem_arb_state == MEM_ARB_BUSY) && (mem_arb_sel == 3'd2) && mc_ack;
    assign icmem_ack[2]   = (mem_arb_state == MEM_ARB_BUSY) && (mem_arb_sel == 3'd3) && mc_ack;
    assign icmem_ack[3]   = (mem_arb_state == MEM_ARB_BUSY) && (mem_arb_sel == 3'd4) && mc_ack;

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
